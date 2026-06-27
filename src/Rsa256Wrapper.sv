// Author: 黃彥富 (YEN-FU HUANG) - B12901171
module Rsa256Wrapper (
    input         avm_rst,
    input         avm_clk,
    output  [4:0] avm_address,
    output        avm_read,
    input  [31:0] avm_readdata,
    output        avm_write,
    output [31:0] avm_writedata,
    input         avm_waitrequest
);

localparam RX_BASE     = 5'b00000; // 0*4
localparam TX_BASE     = 5'b00100; // 1*4
localparam STATUS_BASE = 5'b01000; // 2*4

localparam TX_OK_BIT   = 6;
localparam RX_OK_BIT   = 7;

// 嚴謹的兩階段 FSM
localparam S_GET_KEY_STATUS   = 3'd0;
localparam S_GET_KEY_READ     = 3'd1;
localparam S_GET_DATA_STATUS  = 3'd2;
localparam S_GET_DATA_READ    = 3'd3;
localparam S_WAIT_CALC        = 3'd4;
localparam S_SEND_DATA_STATUS = 3'd5;
localparam S_SEND_DATA_WRITE  = 3'd6;

logic [255:0] n_r, n_w, d_r, d_w, enc_r, enc_w, dec_r, dec_w;
logic [2:0] state_r, state_w;
logic [6:0] bytes_counter_r, bytes_counter_w;
logic [25:0] timeout_counter_r, timeout_counter_w; // Bonus

logic [4:0] avm_address_r, avm_address_w;
logic avm_read_r, avm_read_w, avm_write_r, avm_write_w;

logic rsa_start_r, rsa_start_w;
logic rsa_finished;
logic [255:0] rsa_dec;

assign avm_address = avm_address_r;
assign avm_read = avm_read_r;
assign avm_write = avm_write_r;
// 從 MSB 擷取 8 bits 傳送
assign avm_writedata = dec_r[247:240];

Rsa256Core rsa256_core(
    .i_clk(avm_clk),
    .i_rst(avm_rst),
    .i_start(rsa_start_r),
    .i_a(enc_r),
    .i_d(d_r),
    .i_n(n_r),
    .o_a_pow_d(rsa_dec),
    .o_finished(rsa_finished)
);

always_comb begin
    // 預設保持狀態，避免 Latch
    n_w = n_r;
    d_w = d_r;
    enc_w = enc_r;
    dec_w = dec_r;
    state_w = state_r;
    bytes_counter_w = bytes_counter_r;
    timeout_counter_w = timeout_counter_r;
    rsa_start_w = 0;
    
    avm_address_w = avm_address_r;
    avm_read_w = avm_read_r;
    avm_write_w = avm_write_r;

    // 關鍵修復：只有在真的有讀寫請求時，才需要看 waitrequest 的臉色
    if ((avm_read_r | avm_write_r) == 1'b0 || avm_waitrequest == 1'b0) begin
        case (state_r)
            // ===================================
            // Phase 1: 獲取金鑰 (N 與 d 共 64 bytes)
            // ===================================
            S_GET_KEY_STATUS: begin
                if (avm_readdata[RX_OK_BIT]) begin
                    avm_address_w = RX_BASE; // 準備在下個 Cycle 讀取 RX 資料
                    state_w = S_GET_KEY_READ;
                end
            end

            S_GET_KEY_READ: begin
                // 這個 Cycle 讀出來的 readdata 才是真正的 Cipher Byte
                if (bytes_counter_r < 32) begin
                    n_w = {n_r[247:0], avm_readdata[7:0]};
                end else begin
                    d_w = {d_r[247:0], avm_readdata[7:0]};
                end

                if (bytes_counter_r == 63) begin
                    state_w = S_GET_DATA_STATUS;
                    bytes_counter_w = 0;
                end else begin
                    state_w = S_GET_KEY_STATUS;
                    bytes_counter_w = bytes_counter_r + 1;
                end
                // 每次讀完 Data，馬上切回 Status 準備下一輪輪詢
                avm_address_w = STATUS_BASE;
            end

            // ===================================
            // Phase 2: 獲取密文 (32 bytes) + Bonus
            // ===================================
            S_GET_DATA_STATUS: begin
                timeout_counter_w = timeout_counter_r + 1;
                if (timeout_counter_r > 26'd25_000_000) begin
                    // 🌟 Bonus 機制啟動：重置並重新讀取 Key
                    state_w = S_GET_KEY_STATUS;
                    bytes_counter_w = 0;
                    timeout_counter_w = 0;
                    n_w = 0;
                    d_w = 0;
                end else if (avm_readdata[RX_OK_BIT]) begin
                    avm_address_w = RX_BASE;
                    state_w = S_GET_DATA_READ;
                    timeout_counter_w = 0;
                end
            end

            S_GET_DATA_READ: begin
                enc_w = {enc_r[247:0], avm_readdata[7:0]};
                if (bytes_counter_r == 31) begin
                    state_w = S_WAIT_CALC;
                    bytes_counter_w = 0;
                    avm_read_w = 0; // 停止讀取，釋放 Bus
                    rsa_start_w = 1; // 啟動 Core
                end else begin
                    state_w = S_GET_DATA_STATUS;
                    bytes_counter_w = bytes_counter_r + 1;
                    avm_address_w = STATUS_BASE;
                end
            end

            // ===================================
            // Phase 3: 等待核心運算完成
            // ===================================
            S_WAIT_CALC: begin
                if (rsa_finished) begin
                    dec_w = rsa_dec; // 擷取明文
                    state_w = S_SEND_DATA_STATUS;
                    avm_read_w = 1;
                    avm_address_w = STATUS_BASE; // 準備檢查 TX 狀態
                end
            end

            // ===================================
            // Phase 4: 送出明文 (31 bytes)
            // ===================================
            S_SEND_DATA_STATUS: begin
                if (avm_readdata[TX_OK_BIT]) begin
                    avm_read_w = 0;
                    avm_write_w = 1;
                    avm_address_w = TX_BASE;
                    state_w = S_SEND_DATA_WRITE;
                end
            end

            S_SEND_DATA_WRITE: begin
                // 當執行到這裡時，avm_writedata 已經由 assign 穩定驅動了
                dec_w = dec_r << 8; // 為下一次傳送做準備
                if (bytes_counter_r == 30) begin // 依照簡報只需傳 31 bytes (0~30)
                    state_w = S_GET_DATA_STATUS; // 返回等待下一份密文
                    bytes_counter_w = 0;
                end else begin
                    state_w = S_SEND_DATA_STATUS;
                    bytes_counter_w = bytes_counter_r + 1;
                end
                avm_write_w = 0;
                avm_read_w = 1;
                avm_address_w = STATUS_BASE;
            end
        endcase
    end
end

always_ff @(posedge avm_clk or posedge avm_rst) begin
    if (avm_rst) begin
        n_r <= 0;
        d_r <= 0;
        enc_r <= 0;
        dec_r <= 0;
        // 開機直接發出讀取 STATUS 的請求
        avm_address_r <= STATUS_BASE;
        avm_read_r <= 1;
        avm_write_r <= 0;
        state_r <= S_GET_KEY_STATUS;
        bytes_counter_r <= 0;
        timeout_counter_r <= 0;
        rsa_start_r <= 0;
    end else begin
        n_r <= n_w;
        d_r <= d_w;
        enc_r <= enc_w;
        dec_r <= dec_w;
        avm_address_r <= avm_address_w;
        avm_read_r <= avm_read_w;
        avm_write_r <= avm_write_w;
        state_r <= state_w;
        bytes_counter_r <= bytes_counter_w;
        timeout_counter_r <= timeout_counter_w;
        rsa_start_r <= rsa_start_w;
    end
end

endmodule