# RSA-256 Hardware Decryptor (FPGA / SystemVerilog)

A pipelined RSA-256 decryption accelerator for the Terasic **DE2-115 (Intel Cyclone IV)** board.
The design receives a private key and ciphertext from a host PC over RS-232, performs modular
exponentiation entirely in hardware using **Montgomery multiplication**, and streams the
recovered plaintext back to the host.

> **Course context & academic integrity.** This was built as Lab 2 of NTUEE Digital Circuit Lab.
> If you reuse or reference this work, please respect your own course's academic-integrity policy.
> The original RTL is shared for portfolio purposes only.

---

## Highlights

- **Montgomery modular exponentiation** implemented as a finite-state machine instead of a
  software-style loop, avoiding excessively long combinational paths.
- **Two parallel Montgomery units** compute `m·t·2⁻²⁵⁶ mod N` (conditional multiply) and
  `t²·2⁻²⁵⁶ mod N` (square) simultaneously every iteration, collapsing the 256-bit exponentiation
  to roughly **65 k clock cycles** per block.
- **Custom Avalon-MM master FSM** that drives the Qsys RS-232 IP, with status polling and data
  transfer kept in strictly separate states to eliminate read-after-status desync.
- **Hot-reload bonus**: an idle-timeout counter (~0.5 s @ 50 MHz) lets the machine accept a fresh
  key + ciphertext stream continuously, with no board reset required.

---

## Architecture

```
 PC (Python host)                FPGA (DE2-115)
 ───────────────                 ──────────────────────────────────────────
                       RS-232          ┌────────────────────────────────┐
 key.bin (N, d) ─────────────────────► │ Qsys SoC                       │
 ciphertext     ─────────────────────► │   └─ RS-232 IP (Avalon-MM)     │
                                       │            ▲   │               │
                                       │   Avalon-MM│   ▼               │
                                       │   ┌────────────────────────┐   │
                                       │   │ Rsa256Wrapper (Master) │   │
                                       │   │  status-poll / RX / TX │   │
                                       │   │  256-bit shift assembly│   │
                                       │   └───────────┬────────────┘   │
                                       │   ┌───────────▼────────────┐   │
                                       │   │ Rsa256Core (FSM)       │   │
                                       │   │  S_PREP  → y·2²⁵⁶ mod N │   │
                                       │   │  S_MONT  → 2× RsaMont   │   │
                                       │   └────────────────────────┘   │
 plaintext      ◄───────────────────── │                                │
                                       └────────────────────────────────┘
```

**Data path**

1. Host sends 32-byte `N`, 32-byte `d`, then 32-byte ciphertext blocks over RS-232 @ 115200-8N1.
2. The RS-232 Qsys IP exposes RX/TX/STATUS registers as an Avalon-MM slave.
3. `Rsa256Wrapper` (Avalon-MM **master**) polls STATUS, reads 8-bit bytes, and shift-assembles
   them into 256-bit `n_r`, `d_r`, `enc_r`, then asserts `i_start`.
4. `Rsa256Core` runs Montgomery exponentiation and asserts `o_finished`.
5. The wrapper transmits the top **31 bytes** of the 256-bit result back to the host (the MSB is a
   padding `0x00` byte that is intentionally discarded by slicing `[247:240]`).

---

## Module overview

| Module | Role | Original work |
| --- | --- | :---: |
| `Rsa256Core.sv` | Exponentiation FSM (`S_IDLE/PREP/MONT/DONE`) + two `RsaMont` units | ✅ |
| `RsaMont` (in `Rsa256Core.sv`) | 256-cycle Montgomery multiply, 258-bit accumulator | ✅ |
| `Rsa256Wrapper.sv` | Avalon-MM master FSM, byte assembly, hot-reload timeout | ✅ |
| `DE2_115.sv` | Board top-level; instantiates the Qsys system | Course template |
| `DE2_115.qsf` / `.sdc` | Pin assignments / timing constraints | Course template |
| `tb_verilog/` | Simulation testbenches | Mixed |
| `pc_python/` | Host serial driver + reference model + golden vectors | Course-provided |

---

## Repository layout

```
.
├── src/
│   ├── Rsa256Core.sv        # original RTL
│   ├── Rsa256Wrapper.sv     # original RTL
│   ├── DE2_115/
│   │   ├── DE2_115.sv       # top-level (instantiate your generated Qsys here)
│   │   ├── DE2_115.qsf      # pin assignments
│   │   └── DE2_115.sdc      # timing constraints
│   ├── tb_verilog/          # testbenches
│   └── pc_python/           # host-side scripts (see note below)
└── README.md
```

> The Qsys/Platform Designer system (`rsa_qsys`) is **not** checked in. Before building, generate an
> RS-232 IP system in Platform Designer and connect `clk`, `reset_reset_n`, `uart_*` as referenced
> in `DE2_115.sv`. Quartus build artifacts (`db/`, `output_files/`, `*.qws`, …) are git-ignored.

---

## Build & run

**Synthesis (Intel Quartus Prime)**
1. Open the project for the DE2-115 (Cyclone IV).
2. Generate the `rsa_qsys` RS-232 system in Platform Designer and instantiate it in `DE2_115.sv`.
3. Compile and program the `.sof` onto the board.

**Host side**
```bash
# adjust the serial port for your OS (e.g. /dev/ttyUSB0 or COM3)
python pc_python/rs232.py <serial_port>
```
The script sends `key.bin` (N‖d) followed by ciphertext blocks and writes the recovered plaintext
to `dec.bin`.

**Simulation**
```bash
# example with VCS; tb.sv drives Rsa256Core against the golden vectors
vcs -sverilog src/Rsa256Core.sv src/tb_verilog/tb.sv && ./simv
```

---

## Engineering notes (real-hardware debugging)

These were the most instructive bugs to solve and are the most representative of the work:

- **Simulation deadlock (`Too slow, abort`).** An early version placed the entire Montgomery loop
  in combinational logic, leaving the FSM stuck in `S_MONT`. Refactoring each Montgomery step into a
  counter-driven sequential module — and running two of them in parallel — brought a full decrypt
  back into the testbench's cycle budget.
- **Avalon-MM read/status desync.** Latching `avm_readdata` in the same cycle that `RX_OK` went high
  captured the *previous* status byte (e.g. `0xC0`) instead of payload. Splitting "poll STATUS" and
  "read DATA" into separate states — set the data address first, then sample one cycle later — fixed
  the alignment.
- **Off-by-one plaintext shift.** Output appeared shifted by one byte because the 256-bit result
  carries a leading `0x00` pad. Slicing the transmit bus as `[247:240]` (top 31 bytes) instead of
  `[255:248]` removed the artifact.

## Known limitations / future work

- `o_finished` is asserted for a single cycle; a held/ack-based handshake would be more robust.
- The hot-reload timeout is a hard-coded constant; exposing it as a parameter would aid portability.

---

## License

Original RTL (`Rsa256Core.sv`, `Rsa256Wrapper.sv`) and this README are released under the MIT
License (see `LICENSE`). Course-provided scaffolding (board templates, reference model, and golden
vectors) is **not** covered by this license and remains under its original terms — consider removing
those files before making the repository public.
