# FPGA-Managed KV Cache for Long-Context LLM Inference

A hardware-managed key–value (KV) cache controller designed in SystemVerilog and implemented on a Xilinx Zynq-7020 FPGA. The cache keeps frequently attended KV entries on-chip to reduce off-chip DDR traffic during transformer (LLM) inference, targeting long-context workloads where the KV cache dominates memory bandwidth.

> Undergraduate capstone project — Computer Engineering, Ho Chi Minh City University of Technology (HCMUT), 2026.

---

## Overview

During autoregressive LLM inference, every generated token attends to the keys and values of all previous tokens. As context length grows, the KV cache grows linearly and the bottleneck shifts from compute to **memory bandwidth** — repeatedly streaming KV data from DDR is expensive.

This project implements a **set-associative, hardware-managed cache** that sits between the compute side and DDR, exploiting the **sparse-attention** access pattern (only a subset of tokens — attention sinks, a local window, and a few heavy hitters — are attended each step) to serve most KV reads on-chip.

**Key idea:** with a sparse-attention workload, a good eviction policy keeps exactly the tokens that will be reused, so on-chip hit rates stay high once the cache is large enough to hold the working set.

---

## Highlights

- **~1,640 lines of SystemVerilog** across 7 RTL modules, plus 4 testbenches.
- **512-set × 8-way** set-associative cache (4,096 entries) with **Fibonacci-hash** set indexing.
- **Tree-PLRU** replacement (N−1 bits/set) plus selectable **FIFO** and **LFSR-random** policies for comparison.
- **BF16 storage codec** (FP32 → BF16 by bit-truncation): **2:1 size reduction**, error bounded at 2⁻⁷ (~0.78%) directly from the IEEE 754 layout.
- **AXI4-Lite slave** (control plane, 9 memory-mapped registers) and **AXI4-Full master** (data plane to DDR3 via the HP port).
- **11-state controller FSM** handling lookup, eviction, write-back, DDR refill, and codec pipelining.
- **Timing closure at 50 MHz on Zynq-7020** with positive worst negative slack (WNS).
- **Runtime-reconfigurable** cache geometry and policy, so all 9 benchmark configurations run on a single bitstream.
- Verified with **self-checking SystemVerilog testbenches** and a Python golden reference model.

---

## Architecture

```
            ┌──────────────────────────────────────────────┐
            │              kv_cache_top (FSM)               │
            │                                               │
  AXI4-Lite │   ┌───────────┐   ┌───────────┐   ┌────────┐  │   AXI4-Full
  ──────────┼──▶│  control  │   │ kv_cache_ │   │ replace│  │  ──────────▶
   (control)│   │  regs     │   │   _set    │   │  ment  │  │   (DDR3 data)
            │   └───────────┘   │ (tag/data)│   │ PLRU/  │  │
            │                   └───────────┘   │ FIFO/  │  │
            │   ┌───────────┐                   │ LFSR   │  │
            │   │ kv_delta_ │                   └────────┘  │
            │   │  codec    │ (BF16 truncation, 2-stage)    │
            │   └───────────┘                               │
            └──────────────────────────────────────────────┘
```

### Modules

| File | Role |
|------|------|
| `kv_cache_top.sv` | Top-level controller; 11-state FSM orchestrating lookup, eviction, write-back, and refill |
| `kv_cache_set.sv` | Tag and data storage for one cache set (BRAM-backed) |
| `plru_tree.sv` | Tree-PLRU replacement (victim selection, N−1 bits per set) |
| `fifo_tracker.sv` | FIFO replacement policy (for comparison) |
| `random_lfsr.sv` | LFSR-based pseudo-random replacement (for comparison) |
| `kv_delta_codec.sv` | BF16 storage codec — FP32→BF16 truncation, 2-stage pipeline |
| `kv_cache_axi_wrapper.sv` | AXI4-Lite slave + AXI4-Full master interface |

---

## Design details

### Sparse-attention workload
The access trace is built from the topology of **Qwen2.5-0.5B** (24 layers, 2 KV heads with grouped-query attention) using a **SnapKV-style** sparse-attention pattern (sink + local window + top-K heavy hitters). The access pattern (which `(layer, head, token)` is requested) is realistic; the KV *values* are synthetic (Gaussian), since hit/miss depends on the **address**, not the value.

### Replacement and protection
A **Tree-PLRU** policy naturally retains the frequently attended tokens. Explicit protection mechanisms (a "locked zone" for attention sinks and an "immune window" for recency) were implemented and measured — and found **redundant** for this workload. PLRU already covers both signals: frequency keeps the sink resident, recency keeps the local window resident. Under heavy oversubscription the immune window is actively counter-productive, costing ~3.4 percentage points of hit rate because it reserves entries the top-K set needs.

This negative result is itself a design finding: for sparse-attention KV traffic, a good general policy suffices, and hand-written protection logic is not worth its area.

### BF16 codec
KV arrives as FP32 and is stored as **BF16** by truncating the low 16 mantissa bits (keeping sign + 8-bit exponent + 7 mantissa bits). Sign and exponent are preserved intact, so the magnitude of every value is unchanged and the error bound follows directly from the standard: **≤ 2⁻⁷ (~0.78%)**, independent of the input distribution.

The first-generation codec used **base-delta encoding**, which failed on this data: deltas between neighbouring FP32 values routinely exceed the 5-bit encoding range, saturating almost every entry (mean relative error ≈ 99.6%). BF16 replaced it because it exploits the IEEE 754 layout instead of assuming small differences between values, and because the encoder is pure wire assignment — zero logic on the critical path.

**FP16** was considered and rejected: it has only a 5-bit exponent, so converting from FP32 needs exponent rescaling with overflow/underflow handling, whereas BF16 shares FP32's exponent range and requires none.

---

## Results

Hardware platform: **Arty Z7-20 (Xilinx Zynq-7020, XC7Z020)** at **50 MHz**.

| Metric | Value |
|--------|-------|
| Hit rate (best configuration) | **90.8%** (medium trace), **81.6%** (large trace) |
| Hit rate across the full sweep | **3–99%** over 9 configurations × 3 traces — see below |
| Cache hit latency | **60 ns** (3 cycles, BRAM only — measured by cycle counting in simulation) |
| Timing | **Positive WNS** at 50 MHz; critical path dominated by routing (~65%), not logic depth |
| Resource usage | ~25.3k LUTs (~48% — whole design, including PS7 and AXI infrastructure) |
| Compression | **2:1** (BF16), error bounded at ≤ 2⁻⁷ |
| Stability | **0 hardware timeouts** over 430,080 operations on the large trace |

The wide hit-rate range is the point of the sweep, not a caveat: undersized configurations (128 and 256 sets against a 512-token prefill) collapse to 3–6%, and the jump to 512 sets recovers to 78–82%. The sweep locates the capacity cliff rather than reporting only the best case.

### On latency and the measurement itself

Two numbers must not be conflated:

- **60 ns** is the cache path itself, obtained by counting FSM cycles in the testbench (`Testbench/tb_latency.sv`).
- **~3.8 µs** is the end-to-end wall-clock measured on the board.

The gap is not the cache and it is not primarily the AXI bus. Decomposing one operation: the AXI transactions account for roughly 700 ns, while **~2.5 µs is the firmware's poll-READY loop** — the PS spinning on a status register between operations. The cache core is under 2% of the wall-clock figure.

The correct fix is therefore DMA or an interrupt-driven handshake rather than a faster bus. This also means the on-board benchmark is the right instrument for **hit rate and functional correctness**, but the wrong instrument for latency — hit rate depends on tags and access order, which the polling overhead does not distort, whereas latency is swamped by it.

---

## Repository structure

```
.
├── SystemVerilog Sourcecode/   # RTL design — 7 core modules (cache, FSM, PLRU, codec, AXI)
├── Testbench/                  # 4 testbenches + sample trace (see Testbench/README.md)
├── Firmware Sourcecode/        # Bare-metal C firmware (PS-side control, benchmarks)
├── Vivado RPT File/            # Synthesis & implementation reports (timing, utilization)
└── README.md
```

- **[SystemVerilog Sourcecode](SystemVerilog%20Sourcecode)** — the hardware design: cache datapath, 11-state controller FSM, Tree-PLRU/FIFO/LFSR replacement, BF16 codec, and AXI4-Lite/Full interfaces.
- **[Testbench](Testbench)** — verification: one self-checking testbench for the hardware counters, one cycle-accurate latency measurement, one trace-driven performance harness, and one directed corner-case test.
- **[Firmware Sourcecode](Firmware%20Sourcecode)** — bare-metal C running on the Cortex-A9 (PS) to configure the cache via memory-mapped registers and drive benchmarks.
- **[Vivado RPT File](Vivado%20RPT%20File)** — post-implementation reports documenting timing closure (WNS), resource utilization, and the critical-path analysis.

---

## Verification

Four testbenches, each answering a different question — a pass/fail check, a
latency measurement and a performance sweep are different instruments and are
kept separate rather than merged into one script. All of them instantiate the
real `kv_cache_top` DUT and drive it through the AXI4-Lite interface.

| Testbench | Type | Answers |
|---|---|---|
| `Tb_kv_cache_counter.sv` | **Self-checking** (PASS/FAIL) | Are the hardware performance counters correct? |
| `tb_latency.sv` | Cycle measurement | How many cycles does a hit / clean miss / dirty miss take? |
| `tb_kv_trace.sv` | Trace-driven measurement | What hit rate does a configuration achieve? |
| `tb_kv_cache.sv` | Directed functional | Do the corner cases behave as designed? |

Details, including how to run each one, are in **[Testbench/README.md](Testbench/README.md)**.

Beyond simulation, the design was verified against a **Python golden reference
model** that computes the expected output independently, and finally in
hardware-in-the-loop: 430,080 operations on the board with zero timeouts.

---

## Build & simulate

**Simulation (Vivado XSim), from the repository root:**
```bash
xvlog -sv "SystemVerilog Sourcecode"/*.sv Testbench/Tb_kv_cache_counter.sv
xelab -debug typical Tb_kv_cache_counter -s sim
xsim sim -runall
```

Substitute `tb_latency`, `tb_kv_trace` or `tb_kv_cache` for the other testbenches.
`tb_kv_trace` reads `real_trace.txt` from the directory `xsim` is launched from;
a small sample trace is provided in `Testbench/`.

**Synthesis / implementation:** open the design in **Vivado 2025.2**, target `xc7z020clg400-1`, add the sources from `SystemVerilog Sourcecode/`, run synthesis and implementation, and generate the bitstream. The PS↔PL integration uses AXI4-Lite (control) and an AXI4-Full HP port (data); the PS-side configuration firmware is in `Firmware Sourcecode/`. Implementation reports are in `Vivado RPT File/`.

---

## Scope & limitations

This project deliberately focuses on the **KV cache controller** in depth, rather than a full inference accelerator. As a solo capstone, the scope was narrowed (by the advisor) to one well-engineered subsystem instead of a shallow end-to-end system — so the cache datapath, replacement policies, codec, and timing are taken to completion and measured rigorously.

The main architectural consequence, worth stating plainly:

- **The cache sits behind an AXI bus to the processing system**, so it currently behaves as a *managed on-chip buffer* rather than a cache on a compute datapath. A true cache must sit next to the compute engine and serve KV reads in a few cycles without crossing a bus.
- **The natural completion** is to place an on-chip **attention engine (or a tightly-coupled processor)** directly beside the cache, reading KV from BRAM through the core's native `op_valid`/`op_ready` interface. That turns this managed buffer into a cache in the strict sense, and is the clear next step.

Other notes:

- **Data width.** Each entry stores 64-bit K and 64-bit V rather than a full head-dimension vector, so the design fits the BRAM budget of a Zynq-7020. Hit rate and timing results are unaffected — both depend on tags and control logic, not payload width — but the power and utilisation figures should be read in that context. Both widths are parameters.
- **Workload.** The access pattern is realistic (SnapKV on the Qwen2.5-0.5B topology) but KV *values* are synthetic; validation against a real inference run is future work.
- **Latency vs. baseline.** The firmware-driven path has not yet beaten a direct-DDR baseline end to end. The fix is removing the polling loop from the KV read path (DMA, or the on-chip compute engine above), with prefetching as a smaller incremental improvement.

---

## Tech stack

`SystemVerilog` · `C (bare-metal)` · `Xilinx Vivado/Vitis 2025.2` · `Zynq-7020 (Arty Z7-20)` · `AXI4-Lite / AXI4-Full` · `Python` (golden model)

---

## Author

**Le Chanh Nguyen** — Computer Engineering, HCMUT
[GitHub](https://github.com/Arilla26) · [LinkedIn](https://linkedin.com/in/le-chanh-nguyen-1a1159309)
