# Verification

Four testbenches covering the KV cache controller, each answering a different
question. They are deliberately kept separate: a pass/fail check, a latency
measurement, and a performance sweep are different instruments and should not
be conflated.

| Testbench | Type | Answers |
|---|---|---|
| `Tb_kv_cache_counter.sv` | **Self-checking** (PASS/FAIL) | Are the hardware performance counters correct? |
| `tb_latency.sv` | Cycle measurement | How many cycles does a hit / clean miss / dirty miss take? |
| `tb_kv_trace.sv` | Trace-driven measurement | What hit rate does a given configuration achieve? |
| `tb_kv_cache.sv` | Directed functional | Do the corner cases behave as designed? |

All four instantiate the real `kv_cache_top` DUT and drive it through the
AXI4-Lite control interface — no logic is re-implemented inside the testbench.

---

## `Tb_kv_cache_counter.sv` — self-checking

The only testbench that decides pass/fail on its own. It exercises the
read-only hit/miss counters through five scenarios and reports
`RESULTS: n PASSED, m FAILED` at the end.

The checks that matter most:

- **WRITE operations must not increment the read counters.** A counter that
  is contaminated by writes silently corrupts every hit-rate number
  downstream, so this is checked before anything else.
- **Mixed READ/WRITE sequence.** Nine interleaved operations where only six
  are reads; the counter must report exactly those six.
- **`dbg_clear` fully resets all counters**, so consecutive benchmark
  configurations don't leak state into each other.

On failure it prints `DO NOT re-synthesize` — the testbench is used as a gate
before spending time on synthesis and implementation.

A watchdog `$finish`es the simulation if the DUT stalls, so a hang shows up as
a timeout rather than an infinite run.

## `tb_latency.sv` — cycle-accurate latency

Separates three paths with a configurable DDR model latency
(`DDR_RD_LAT`, `DDR_WR_LAT`):

- `T_hit` — BRAM only, no DDR access
- `T_miss(clean)` — refill from DDR, victim not dirty
- `T_miss(dirty)` — write-back of the victim, then refill

**This is the source of the reported hit latency.** It comes from counting
clock cycles in simulation, not from wall-clock timing on the board — the
on-board benchmark measures the whole round trip through the firmware and
cannot isolate the cache path.

Writes `kv_cache_latency.vcd` for waveform inspection.

## `tb_kv_trace.sv` — trace-driven performance

Replays an access trace and reports hit rate, best-case hit latency,
worst-case miss latency, and average cycles per command, along with the
configuration that produced them.

Reads `real_trace.txt` from the simulation working directory, one access per
line:

```
layer,head,token,key_hex,value_hex
```

A small sample trace (`real_trace.txt`, 160 accesses) is included so the
testbench runs out of the box. It follows the same shape as the full
benchmark traces: a prefill phase followed by decode steps that re-touch the
sink token and a recent local window.

A hung command (over 1000 cycles) is reported as a failure and stops the run.
Note that this testbench **measures** behaviour rather than asserting it — it
does not compare each access against an expected hit/miss outcome.

## `tb_kv_cache.sv` — directed functional

Five scenarios driven in sequence:

1. Cache miss and fill
2. Cache hit
3. Immunity corner case — a 4-way set already full, then a fifth token forced
   into the same set
4. Hot-swapping and Locked Zone routing
5. DDR read miss and the decode penalty path

Prints a trace of what happened; correctness is confirmed by waveform
inspection rather than by assertions.

---

## Running

From the repository root, with Vivado XSim:

```bash
xvlog -sv "SystemVerilog Sourcecode"/*.sv Testbench/Tb_kv_cache_counter.sv
xelab -debug typical Tb_kv_cache_counter -s sim
xsim sim -runall
```

Substitute `tb_latency`, `tb_kv_trace` or `tb_kv_cache` for the other
testbenches. `tb_kv_trace` expects `real_trace.txt` in the working directory
from which `xsim` is launched.
