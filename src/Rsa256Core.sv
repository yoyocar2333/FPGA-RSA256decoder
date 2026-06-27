// Author: 黃彥富 (YEN-FU HUANG) - B12901171
module Rsa256Core (
    input          i_clk,
    input          i_rst,
    input          i_start,
    input  [255:0] i_a, // cipher text y
    input  [255:0] i_d, // private key
    input  [255:0] i_n, // N
    output [255:0] o_a_pow_d, // plain text x
    output         o_finished
);

    // FSM States
    localparam S_IDLE = 2'd0;
    localparam S_PREP = 2'd1;
    localparam S_MONT = 2'd2;
    localparam S_DONE = 2'd3;

    logic [1:0]   state_r, state_w;
    logic [255:0] m_r, m_w;
    logic [255:0] t_r, t_w;
    logic [255:0] d_r, d_w;
    logic [255:0] n_r, n_w;
    logic [8:0]   counter_r, counter_w; // 0 to 256

    // Montgomery 模組的控制訊號
    logic mont_start;
    logic [255:0] mont_m_out, mont_t_out;
    logic mont_m_finished, mont_t_finished;

    assign o_a_pow_d = m_r;
    assign o_finished = (state_r == S_DONE);

    // 實例化兩個 Montgomery 模組達成平行運算 (Slide 25)
    RsaMont mont_m_inst (
        .clk(i_clk),
        .rst(i_rst),
        .start(mont_start),
        .a(m_r),
        .b(t_r),
        .N(n_r),
        .out(mont_m_out),
        .finished(mont_m_finished)
    );

    RsaMont mont_t_inst (
        .clk(i_clk),
        .rst(i_rst),
        .start(mont_start),
        .a(t_r),
        .b(t_r),
        .N(n_r),
        .out(mont_t_out),
        .finished(mont_t_finished)
    );

    // PREP 階段硬體：計算 t * 2 mod N
    // 將 t 左移 1 bit，若大於等於 N 則減去 N
    logic [256:0] t_prep_shifted;
    assign t_prep_shifted = {t_r, 1'b0};
    
    logic [255:0] t_prep_next;
    assign t_prep_next = (t_prep_shifted >= n_r) ? (t_prep_shifted - n_r) : t_prep_shifted[255:0];

    always_comb begin
        // Default assignments
        state_w   = state_r;
        m_w       = m_r;
        t_w       = t_r;
        d_w       = d_r;
        n_w       = n_r;
        counter_w = counter_r;
        mont_start = 1'b0;

        case (state_r)
            S_IDLE: begin
                if (i_start) begin
                    state_w   = S_PREP;
                    m_w       = 256'd1;
                    t_w       = i_a;
                    d_w       = i_d;
                    n_w       = i_n;
                    counter_w = 9'd0;
                end
            end

            S_PREP: begin
                // 執行 256 次的 t = t * 2 mod N，等同於計算 y * 2^256 mod N
                if (counter_r < 256) begin
                    t_w = t_prep_next;
                    counter_w = counter_r + 1;
                end else begin
                    state_w = S_MONT;
                    counter_w = 9'd0;
                    mont_start = 1'b1; // 觸發第一次 Montgomery 計算
                end
            end

            S_MONT: begin
                if (counter_r < 256) begin
                    // 等待兩個模組都算完 (約需 256 cycles)
                    if (mont_m_finished && mont_t_finished) begin
                        m_w = d_r[0] ? mont_m_out : m_r; // d 的 i-th bit 為 1 才更新 m
                        t_w = mont_t_out;
                        d_w = d_r >> 1;                  // 將 d 右移，下回合直接看 LSB
                        counter_w = counter_r + 1;
                        
                        if (counter_r + 1 < 256) begin
                            mont_start = 1'b1;           // 觸發下一輪迭代
                        end else begin
                            state_w = S_DONE;
                        end
                    end
                end else begin
                    state_w = S_DONE;
                end
            end

            S_DONE: begin
                state_w = S_IDLE; // 解密完成，回到 IDLE 準備接下一筆
            end
        endcase
    end

    always_ff @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            state_r   <= S_IDLE;
            m_r       <= 0;
            t_r       <= 0;
            d_r       <= 0;
            n_r       <= 0;
            counter_r <= 0;
        end else begin
            state_r   <= state_w;
            m_r       <= m_w;
            t_r       <= t_w;
            d_r       <= d_w;
            n_r       <= n_w;
            counter_r <= counter_w;
        end
    end
endmodule

// ==========================================================
// 子模組：Montgomery Algorithm (Slide 14)
// ==========================================================
module RsaMont (
    input  logic         clk,
    input  logic         rst,
    input  logic         start,
    input  logic [255:0] a,
    input  logic [255:0] b,
    input  logic [255:0] N,
    output logic [255:0] out,
    output logic         finished
);
    logic [8:0]   i_r, i_w;
    logic [257:0] m_r, m_w; // 為了避免加法溢位，多開兩個 bits
    
    // 最後階段：如果 m >= N，則 m = m - N
    assign out = (m_r >= {2'b0, N}) ? (m_r[255:0] - N) : m_r[255:0];
    assign finished = (i_r == 256);

    logic [257:0] m_plus_b;
    logic [257:0] m_plus_b_plus_N;
    
    always_comb begin
        // 透過 a 的第 i 個 bit 決定要不要加 b (利用 i_r[7:0] 索引)
        m_plus_b = a[i_r[7:0]] ? (m_r + {2'b0, b}) : m_r;
        
        // 判斷是否為奇數 (LSB 是否為 1)，是的話加上 N
        m_plus_b_plus_N = m_plus_b[0] ? (m_plus_b + {2'b0, N}) : m_plus_b;
        
        i_w = i_r;
        m_w = m_r;
        
        if (start) begin
            i_w = 0;
            m_w = 0;
        end else if (i_r < 256) begin
            m_w = m_plus_b_plus_N >> 1; // m = m / 2
            i_w = i_r + 1;
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            i_r <= 256; // 重置時停留在完成狀態，避免亂動
            m_r <= 0;
        end else begin
            i_r <= i_w;
            m_r <= m_w;
        end
    end
endmodule