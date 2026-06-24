# FPGA-Managed KV Cache for Long-Context LLM Inference

A hardware-managed key–value (KV) cache controller designed in SystemVerilog and implemented on a Xilinx Zynq-7020 FPGA. The cache keeps frequently attended KV entries on-chip to reduce off-chip DDR traffic during transformer (LLM) inference, targeting long-context workloads where the KV cache dominates memory bandwidth.

> Undergraduate capstone project — Computer Engineering, Ho Chi Minh City University of Technology (HCMUT), 2026.

---

## Overview

During autoregressive LLM inference, every generated token attends to the keys and values of all previous tokens. As context length grows, the KV cache grows linearly and the bottleneck shifts from compute to **memory bandwidth** — repeatedly streaming KV data from DDR is expensive.

This project implements a **set-associative, hardware-managed cache** that sits between the compute side and DDR, exploiting the **sparse-attention** access pattern (only a subset of tokens — attention sinks, a local window, and a few heavy hitters — are attended each step) to serve most KV reads on-chip.

**Key idea:** with a sparse-attention workload, a good eviction policy keeps exactly the tokens that will be reused, so on-chip hit rates stay high (80–99%) without corrupting any data.

---

## Highlights

- **~1,640 lines of SystemVerilog** across 7 RTL modules.
- **512-set × 8-way** set-associative cache (4,096 entries) with **Fibonacci-hash** set indexing.
- **Tree-PLRU** replacement (N−1 bits/set) plus selectable **FIFO** and **LFSR-random** policies for comparison.
- **BF16 storage codec** (FP32 accumulator → BF16 by bit-truncation): **2:1 size reduction**, bounded error ≤ 2⁻⁷, non-accumulating across sequence length.
- **AXI4-Lite slave** (control plane, 9 memory-mapped registers) and **AXI4-Full master** (data plane to DDR3 via the HP port).
- **11-state controller FSM** handling lookup, eviction, write-back, DDR refill, and codec pipelining.
- **Timing closure at 50 MHz on Zynq-7020** with positive worst negative slack (WNS).
- Verified against a **Python golden model** with self-checking SystemVerilog testbenches (Verilator / Vivado XSim).

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
| `kv_dma_dispatcher.sv` | DMA command-queue dispatcher (latency-reduction extension) |

---

## Design details

### Sparse-attention workload
The access trace is built from the topology of **Qwen2.5-0.5B** (24 layers, 2 KV heads with grouped-query attention) using a **SnapKV-style** sparse-attention pattern (sink + local window + top-K heavy hitters). The access pattern (which `(layer, head, token)` is requested) is realistic; the KV *values* are synthetic (Gaussian, matching real distributions), since hit/miss depends on the **address**, not the value.

### Replacement and protection
A **Tree-PLRU** policy naturally retains the frequently attended tokens. Explicit protection mechanisms (a "locked zone" for attention sinks and an "immune window" for recency) were implemented and measured — and found **redundant** for this workload, since PLRU already keeps those tokens. This negative result is itself a design finding: for sparse-attention KV traffic, a good general policy suffices.

### BF16 codec
KV arrives as FP32 (representing the FP32 accumulator output of attention) and is stored as **BF16** by truncating the low 16 mantissa bits (keeping sign + 8-bit exponent + 7 mantissa bits). This mirrors the FP32→BF16 cast real LLMs perform when moving KV to cache: **2:1 storage**, error bounded at 2⁻⁷ (~0.78%), full FP32 dynamic range preserved, and error that does **not** accumulate with context length. (Delta coding was rejected — its error grows with sequence length; FP8 was rejected for precision loss and outlier risk.)

---

## Results

Hardware platform: **Arty Z7-20 (Xilinx Zynq-7020, XC7Z020)** at **50 MHz**.

| Metric | Value |
|--------|-------|
| Hit rate | **81–99%** across 9 cache configurations and 3 workload traces |
| Cache hit latency | **60 ns** (3 cycles, BRAM only — no DDR access) |
| Timing | **Positive WNS** at 50 MHz; critical path dominated by routing (~65%), not logic depth |
| Resource usage | ~25.3k LUTs (~48%) |
| Compression | **2:1** (BF16), bounded error ≤ 2⁻⁷ |

Latency analysis showed that the on-chip cache path is fast (60 ns), while most end-to-end wall-clock time came from the **AXI-Lite communication interface**, not the cache core — motivating the DMA command-queue extension (`kv_dma_dispatcher.sv`).

---

## Repository structure

```
.
├── SystemVerilog Sourcecode/   # RTL design — 7 core modules (cache, FSM, PLRU, codec, AXI)
├── Firmware Sourcecode/        # Bare-metal C firmware (PS-side control, benchmarks)
├── Vivado RPT File/            # Synthesis & implementation reports (timing, utilization)
└── README.md
```

- **[SystemVerilog Sourcecode](SystemVerilog%20Sourcecode)** — the hardware design: cache datapath, 11-state controller FSM, Tree-PLRU/FIFO/LFSR replacement, BF16 codec, and AXI4-Lite/Full interfaces.
- **[Firmware Sourcecode](Firmware%20Sourcecode)** — bare-metal C running on the Cortex-A9 (PS) to configure the cache via memory-mapped registers and drive benchmarks.
- **[Vivado RPT File](Vivado%20RPT%20File)** — post-implementation reports documenting timing closure (WNS), resource utilization, and the critical-path analysis.

---

## Build & simulate

**Simulation (Vivado XSim or Verilator):**
```bash
# Compile the RTL with Vivado XSim (run from the repo root)
xvlog -sv "SystemVerilog Sourcecode"/*.sv
xelab -debug typical <testbench_top> -s sim
xsim sim -runall
```

**Synthesis / implementation:** open the design in **Vivado 2025.2**, target `xc7z020clg400-1`, add the sources from `SystemVerilog Sourcecode/`, run synthesis and implementation, and generate the bitstream. The PS↔PL integration uses AXI4-Lite (control) and an AXI4-Full HP port (data); the PS-side configuration firmware is in `Firmware Sourcecode/`. Implementation reports are in `Vivado RPT File/`.

---

## Scope & limitations

This project deliberately focuses on the **KV cache controller** in depth, rather than a full inference accelerator. As a solo capstone, the scope was scoped down (by the advisor) to one well-engineered subsystem instead of a shallow end-to-end system — so the cache datapath, replacement policies, codec, and timing are taken to completion and measured rigorously.

The main architectural consequence, worth stating plainly:

- **The cache sits behind an AXI bus to the processing system**, so it currently behaves as a *managed on-chip buffer* rather than a cache on a compute datapath. A true cache must sit next to the compute engine and serve KV reads in a few cycles without bus overhead. This is also why the bus-mediated DMA path does not beat a direct-DDR baseline — every access pays a bus cost.
- **The natural completion** is to place an on-chip **attention engine (or a tightly-coupled processor)** directly beside the cache, reading KV from BRAM without crossing the bus. That turns this managed buffer into a cache in the strict sense, and is the clear next step.

Other notes:
- **Workload:** the access pattern is realistic (SnapKV on the Qwen2.5-0.5B topology) but KV *values* are synthetic; accuracy validation against a real inference run is future work.
- **Latency vs. baseline:** the DMA path has not yet beaten a direct-DDR baseline; prefetching is a candidate improvement.

---

## Tech stack

`SystemVerilog` · `C (bare-metal)` · `Xilinx Vivado/Vitis 2025.2` · `Zynq-7020 (Arty Z7-20)` · `AXI4-Lite / AXI4-Full` · `Verilator` · `Python` (golden model)

---

## Author

**Le Chanh Nguyen** — Computer Engineering, HCMUT
[GitHub](https://github.com/Arilla26) · [LinkedIn](https://linkedin.com/in/le-chanh-nguyen-1a1159309)
