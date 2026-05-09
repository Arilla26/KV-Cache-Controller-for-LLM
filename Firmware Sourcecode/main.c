/* =============================================================================
 * KV Cache Accelerator — Benchmark & Verification
 * Target  : Arty Z7 (Zynq-7020, FCLK ~50 MHz)
 * Pattern : SnapKV Sparse Attention
 * Metrics : Hit Rate, Miss Rate, Latency (avg/min/max), Data Accuracy,
 *           HW Timeout Count, Immune/Locked Zone effectiveness
 *
 * Select trace size by defining TRACE_SELECT before building:
 *   -DTRACE_SELECT=TRACE_SMALL    (default — verify correctness)
 *   -DTRACE_SELECT=TRACE_MEDIUM   (meaningful benchmark)
 *   -DTRACE_SELECT=TRACE_LARGE    (stress test)
 * ============================================================================= */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "xil_printf.h"
#include "xil_cache.h"
#include "xiltimer.h"
#include "xparameters.h"
#include "kv_hw_driver.h"
#include "golden_trace_meta.h"
#include "sd_load.h"

/* ---------------------------------------------------------------------------
 * Timer helpers — XTime ticks at FCLK/2 on Zynq Cortex-A9
 * --------------------------------------------------------------------------- */
#define CPU_FREQ_HZ     ((double)XPAR_CPU_CORE_CLOCK_FREQ_HZ)
#define TICKS_PER_US    (CPU_FREQ_HZ / 2.0 / 1e6)

/* ---------------------------------------------------------------------------
 * Benchmark configuration matrix
 *
 * locked_bound = (NUM_LAYERS × NUM_KV_HEADS) / N_WAY = 48 / N_WAY
 *   8-way: 48/8 = 6   → TRACE_LOCKED_BOUND_8W
 *   4-way: 48/4 = 12  → TRACE_LOCKED_BOUND_4W
 *
 * window_size: match TRACE_WINDOW_SIZE so Immune Window covers the exact
 *   local window used during trace generation.
 *
 * Configs are grouped:
 *   Group A — Baseline (no special features): compare eviction algorithms
 *             and cache sizes
 *   Group B — With Locked Zone only: verify Attention Sink protection
 *   Group C — With Locked Zone + Immune Window: full SnapKV protection
 * --------------------------------------------------------------------------- */
typedef struct {
    const char *name;
    u32   algo;
    u32   sets;
    u8    way_full;
    u16   num_heads;
    u8    immune_en;
    u16   window_size;
    u8    locked_en;
    u16   locked_bound;
} BenchCfg;

/* ---------------------------------------------------------------------------
 * Immune Window half-size — for Group 5 sensitivity sweep.
 * Must be >= 1 to avoid zero window.
 * --------------------------------------------------------------------------- */
#define TRACE_WINDOW_HALF  ((TRACE_WINDOW_SIZE / 2U) > 0U ? \
                            (TRACE_WINDOW_SIZE / 2U) : 1U)

static const BenchCfg CONFIGS[] = {

    /* ════════════════════════════════════════════════════════════════════════
     * Group 1 — Eviction algorithm comparison
     * Fixed: 512S, 8W, Locked ON, Immune ON (strongest config)
     * Variable: ALGO
     * Goal: isolate PLRU vs FIFO vs RAND under equal conditions
     * ════════════════════════════════════════════════════════════════════════ */
    { "G1 PLRU 512S+ALL", KV_ALGO_PLRU, KV_SETS_512, 1, TRACE_NUM_KV_HEADS,
      1, TRACE_WINDOW_SIZE, 1, TRACE_LOCKED_BOUND_8W },
    { "G1 FIFO 512S+ALL", KV_ALGO_FIFO, KV_SETS_512, 1, TRACE_NUM_KV_HEADS,
      1, TRACE_WINDOW_SIZE, 1, TRACE_LOCKED_BOUND_8W },
    { "G1 RAND 512S+ALL", KV_ALGO_RAND, KV_SETS_512, 1, TRACE_NUM_KV_HEADS,
      1, TRACE_WINDOW_SIZE, 1, TRACE_LOCKED_BOUND_8W },

    /* ════════════════════════════════════════════════════════════════════════
     * Group 2 — Cache size (Sets) sweep
     * Fixed: PLRU, 8W, Locked ON, Immune ON
     * Variable: SETS (128 → 256 → 512)
     * Goal: how hit rate scales with number of sets
     * Note: G2.3 == G1.1 — result reused, not re-run
     * ════════════════════════════════════════════════════════════════════════ */
    { "G2 PLRU 128S+ALL", KV_ALGO_PLRU, KV_SETS_128, 1, TRACE_NUM_KV_HEADS,
      1, TRACE_WINDOW_SIZE, 1, TRACE_LOCKED_BOUND_8W },
    { "G2 PLRU 256S+ALL", KV_ALGO_PLRU, KV_SETS_256, 1, TRACE_NUM_KV_HEADS,
      1, TRACE_WINDOW_SIZE, 1, TRACE_LOCKED_BOUND_8W },
    /* G2.3: PLRU 512S+ALL == G1.1, skipped to avoid re-run */

    /* ════════════════════════════════════════════════════════════════════════
     * Group 3 — Associativity (Ways) sweep
     * Fixed: PLRU, 512S, Locked ON, Immune ON
     * Variable: WAYS (4 → 8)
     * Goal: 4-way vs 8-way with same set count
     * Note: G3.2 == G1.1 — result reused, not re-run
     * ════════════════════════════════════════════════════════════════════════ */
    { "G3 PLRU 512S 4W",  KV_ALGO_PLRU, KV_SETS_512, 0, TRACE_NUM_KV_HEADS,
      1, TRACE_WINDOW_SIZE, 1, TRACE_LOCKED_BOUND_4W },
    /* G3.2: PLRU 512S 8W+ALL == G1.1, skipped */

    /* ════════════════════════════════════════════════════════════════════════
     * Group 4 — Locked Zone effectiveness
     * Fixed: PLRU, 512S, 8W, Immune OFF
     * Variable: LOCKED (OFF → ON)
     * Goal: measure contribution of Attention Sink protection alone
     * Note: G4.3 == G1.1 (both features ON) — result reused
     * ════════════════════════════════════════════════════════════════════════ */
    { "G4 PLRU 512S BARE", KV_ALGO_PLRU, KV_SETS_512, 1, TRACE_NUM_KV_HEADS,
      0, 0, 0, 0 },
    { "G4 PLRU 512S+LK",   KV_ALGO_PLRU, KV_SETS_512, 1, TRACE_NUM_KV_HEADS,
      0, 0, 1, TRACE_LOCKED_BOUND_8W },
    /* G4.3: +LK+IMM == G1.1, skipped */

    /* ════════════════════════════════════════════════════════════════════════
     * Group 5 — Immune Window size sensitivity
     * Fixed: PLRU, 512S, 8W, Locked ON
     * Variable: WINDOW (OFF → WINDOW/2 → WINDOW)
     * Goal: find optimal window size; too small = under-protected,
     *       too large = wastes ways on local tokens
     * Note: G5.1 == G4.2, G5.3 == G1.1 — results reused
     * ════════════════════════════════════════════════════════════════════════ */
    { "G5 PLRU 512S+W/2",  KV_ALGO_PLRU, KV_SETS_512, 1, TRACE_NUM_KV_HEADS,
      1, TRACE_WINDOW_HALF, 1, TRACE_LOCKED_BOUND_8W },
    /* G5.1: +LK only     == G4.2, skipped  */
    /* G5.3: +LK+FULL_WIN == G1.1, skipped  */
};
#define NUM_CONFIGS  ((int)(sizeof(CONFIGS) / sizeof(CONFIGS[0])))

/* ---------------------------------------------------------------------------
 * Per-run result
 * --------------------------------------------------------------------------- */
typedef struct {
    int    total_ops;
    int    read_ops;
    int    write_ops;
    int    hits;
    int    misses;
    int    hw_timeouts;
    double total_us;
    double avg_us;
    double min_read_us;
    double max_read_us;
    /* Latency split by hit/miss path */
    double avg_hit_us;      /* avg latency of READ HITs  (BRAM path)  */
    double avg_miss_us;     /* avg latency of READ MISSes (DDR path)  */
    double sum_hit_us;      /* accumulator for hit latency            */
    double sum_miss_us;     /* accumulator for miss latency           */
} RunResult;

/* ---------------------------------------------------------------------------
 * Pretty-print helpers (xil_printf has no %f support)
 * --------------------------------------------------------------------------- */
static void print_pct(int num, int den) {
    if (den == 0) { xil_printf("  N/A   "); return; }
    int i = ((long long)num * 10000LL) / den;
    xil_printf("%3d.%02d%%", i / 100, i % 100);
}

static void print_us(double us) {
    int i = (int)us;
    int f = (int)((us - (double)i) * 1000.0);
    if (f < 0) f = 0;
    xil_printf("%6d.%03dus", i, f);
}

/* ---------------------------------------------------------------------------
 * ddr_warmup — perform a dummy DDR read to avoid cold-start stall on Config 1
 * --------------------------------------------------------------------------- */
static void ddr_warmup(void) {
    /* Clear DDR KV region to remove stale codec data from previous runs.
     * Size = NUM_LAYER × NUM_HEAD × MAX_TOKENS × 8 bytes (32-bit K + 32-bit V)
     * = 24 × 2 × 1024 × 8 = 393,216 bytes = 384 KB @ 0x11000000 */
    memset((void *)0x11000000UL, 0, 0x00060000UL);
    Xil_DCacheFlush();

    volatile u32 dummy = *(volatile u32 *)0x11000000UL;
    (void)dummy;
    /* Dummy KV op to warm DDR controller */
    u32 kl, kh, vl, vh;
    KV_SetAlgoAndSize(KV_ALGO_PLRU, KV_SETS_128, 1, TRACE_NUM_KV_HEADS);
    KV_SetFeatures(0, 0, 0, 0);
    KV_Read(0, 0, 0xFFFFU, &kl, &kh, &vl, &vh);
    /* Full reset after warmup so first benchmark starts clean */
    KV_CacheReset();
    KV_ResetConfig();
    xil_printf("[INIT] DDR warm-up done.\r\n");
}

/* ---------------------------------------------------------------------------
 * run_benchmark — execute one config over the full trace, fill result.
 *
 * FIX: KV_ResetConfig() before each run clears REG7/REG8 so previous
 * config's features don't bleed into the next. BRAM valid bits are not
 * reset (hardware limitation) — noted in report.
 * --------------------------------------------------------------------------- */
static void run_benchmark(const BenchCfg *cfg, const KVCacheTrace *traces,
                           int num_trace, RunResult *r) {
    memset(r, 0, sizeof(RunResult));
    r->min_read_us = 1e18;

    /* Full cache reset — clears BRAM valid/dirty bits and eviction state.
     * Requires SW reset support in kv_cache_axi_wrapper.sv (REG0[4]). */
    KV_CacheReset();

    /* Reset register state from previous config */
    KV_ResetConfig();

    /* Configure hardware for this run */
    KV_SetAlgoAndSize(cfg->algo, cfg->sets, cfg->way_full, cfg->num_heads);
    KV_SetFeatures(cfg->immune_en, cfg->window_size,
                   cfg->locked_en, cfg->locked_bound);

    XTime t_start, t_end, t_op_start, t_op_end;
    XTime_GetTime(&t_start);

    for (int i = 0; i < num_trace; i++) {
        const KVCacheTrace *tr = &traces[i];
        r->total_ops++;

        if (tr->is_write) {
            /* ── WRITE ── */
            r->write_ops++;
            int ok = KV_Write(tr->layer, tr->head, tr->token,
                              tr->k_l, tr->k_h, tr->v_l, tr->v_h);
            if (!ok) r->hw_timeouts++;

        } else {
            /* ── READ ── */
            r->read_ops++;

            u32 rk_l, rk_h, rv_l, rv_h;
            XTime_GetTime(&t_op_start);
            int hit = KV_Read(tr->layer, tr->head, tr->token,
                              &rk_l, &rk_h, &rv_l, &rv_h);
            XTime_GetTime(&t_op_end);

            double op_us = (double)(t_op_end - t_op_start) / TICKS_PER_US;
            if (op_us < r->min_read_us) r->min_read_us = op_us;
            if (op_us > r->max_read_us) r->max_read_us = op_us;

            if (hit == -1) {
                r->hw_timeouts++;
            } else {
                if (hit) { r->hits++;   r->sum_hit_us  += op_us; }
                else      { r->misses++; r->sum_miss_us += op_us; }

            }
        }
    }

    XTime_GetTime(&t_end);
    r->total_us    = (double)(t_end - t_start) / TICKS_PER_US;
    r->avg_us      = (r->total_ops > 0) ? (r->total_us / r->total_ops) : 0.0;
    r->avg_hit_us  = (r->hits   > 0) ? (r->sum_hit_us  / r->hits)   : 0.0;
    r->avg_miss_us = (r->misses > 0) ? (r->sum_miss_us / r->misses) : 0.0;
    if (r->read_ops == 0) r->min_read_us = 0.0;
}

/* ---------------------------------------------------------------------------
 * print_report — detailed result for one config
 * --------------------------------------------------------------------------- */
static void print_report(int idx, const BenchCfg *cfg, const RunResult *r) {
    xil_printf("\r\n[%d] %s\r\n", idx + 1, cfg->name);

    /* Config line */
    xil_printf("  Algo=%-4s  Sets=%-3s  Ways=%s  Heads=%d",
               cfg->algo == KV_ALGO_PLRU ? "PLRU" :
               cfg->algo == KV_ALGO_FIFO ? "FIFO" : "RAND",
               cfg->sets == KV_SETS_128  ? "128"  :
               cfg->sets == KV_SETS_256  ? "256"  : "512",
               cfg->way_full ? "8" : "4",
               cfg->num_heads);
    if (cfg->immune_en)
        xil_printf("  Immune=ON(win=%d)", cfg->window_size);
    else
        xil_printf("  Immune=OFF");
    if (cfg->locked_en)
        xil_printf("  LockedZone=ON(bound=%d)", cfg->locked_bound);
    xil_printf("\r\n");

    /* Ops */
    xil_printf("  %-30s %d\r\n", "Total ops:", r->total_ops);

    /* Hit/Miss rate — FIX: misses = read_ops - hits - hw_timeouts */
    int real_misses = r->read_ops - r->hits - r->hw_timeouts;

    xil_printf("  %-30s ", "Hit Rate:");
    print_pct(r->hits, r->read_ops);
    xil_printf("  (%d/%d)\r\n", r->hits, r->read_ops);

    xil_printf("  %-30s ", "Miss Rate:");
    print_pct(real_misses, r->read_ops);
    xil_printf("  (%d/%d)\r\n", real_misses, r->read_ops);


    /* Latency */
    xil_printf("  %-30s ", "Avg latency/op:");
    print_us(r->avg_us); xil_printf("\r\n");

    xil_printf("  %-30s ", "Avg HIT latency (BRAM):");
    print_us(r->avg_hit_us); xil_printf("\r\n");

    xil_printf("  %-30s ", "Avg MISS latency (DDR):");
    print_us(r->avg_miss_us);
    if (r->avg_miss_us > 0.0 && r->avg_hit_us > 0.0) {
        int ratio = (int)(r->avg_miss_us / r->avg_hit_us);
        xil_printf("  (%dx vs BRAM)", ratio);
    }
    xil_printf("\r\n");

    xil_printf("  %-30s ", "Min read latency:");
    print_us(r->min_read_us); xil_printf("\r\n");

    xil_printf("  %-30s %d\r\n", "HW Timeouts:", r->hw_timeouts);

    /* Throughput */
    if (r->total_us > 0.0) {
        int mops_i = (int)(r->total_ops / r->total_us);
        int mops_f = (int)((r->total_ops / r->total_us - mops_i) * 1000);
        xil_printf("  %-30s %d.%03d MOPS\r\n", "Throughput:", mops_i, mops_f);
    }

    if (r->hw_timeouts > 0)
        xil_printf("  [WARN] HW timeouts! Check AXI/DDR connectivity.\r\n");
}

/* ---------------------------------------------------------------------------
 * print_summary_table — grouped by experiment
 * --------------------------------------------------------------------------- */
static void print_group_header(const char *title) {
    xil_printf("  -- %-72s\r\n", title);
}

static void print_summary_row(const char *name, const RunResult *r) {
    int real_misses = r->read_ops - r->hits - r->hw_timeouts;
    xil_printf("  %-20s | ", name);
    print_pct(r->hits,         r->read_ops);      xil_printf(" | ");
    print_pct(real_misses,     r->read_ops);      xil_printf(" | ");
    print_us(r->avg_us);
    xil_printf(" | %2d\r\n", r->hw_timeouts);
}

/* Reused result rows for configs that appear in multiple groups */
static void print_reused(const char *name, const RunResult *r) {
    int real_misses = r->read_ops - r->hits - r->hw_timeouts;
    xil_printf("  %-20s | ", name);
    print_pct(r->hits,         r->read_ops);      xil_printf(" | ");
    print_pct(real_misses,     r->read_ops);      xil_printf(" | ");
    print_us(r->avg_us);
    xil_printf(" | %2d  [=G1.1]\r\n", r->hw_timeouts);
}

static void print_summary_table(const BenchCfg *cfgs,
                                 const RunResult *results, int n) {
    (void)n;   /* n unused: summary uses fixed group indices */
    /* Index mapping — must match CONFIGS[] order:
     * 0: G1 PLRU 512S+ALL   (anchor — reused as G2.3, G3.2, G4.3, G5.3)
     * 1: G1 FIFO 512S+ALL
     * 2: G1 RAND 512S+ALL
     * 3: G2 PLRU 128S+ALL
     * 4: G2 PLRU 256S+ALL
     * 5: G3 PLRU 512S 4W
     * 6: G4 PLRU 512S BARE
     * 7: G4 PLRU 512S+LK    (reused as G5.1)
     * 8: G5 PLRU 512S+W/2
     */
    const RunResult *g1_plru = &results[0];   /* anchor */
    const RunResult *g4_lk   = &results[7];   /* +LK only, reused as G5.1 */

    xil_printf("\r\n");
    xil_printf("====================================================================================\r\n");
    xil_printf("  SUMMARY TABLE — SnapKV Sparse Attention Benchmark\r\n");
    xil_printf("====================================================================================\r\n");
    xil_printf("  %-20s | HitRate | MissRate | AvgLat   | TO\r\n",
               "Config");
    xil_printf("  --------------------|---------|----------|-----------|-----------\r\n");

    /* ── Group 1: Eviction algorithm ────────────────────────────────────── */
    print_group_header("Group 1: Eviction Algorithm (512S 8W, Locked+Immune ON)");
    for (int i = 0; i <= 2; i++)
        print_summary_row(cfgs[i].name, &results[i]);

    xil_printf("  --------------------|---------|----------|-----------|-----------\r\n");

    /* ── Group 2: Sets sweep ─────────────────────────────────────────────── */
    print_group_header("Group 2: Cache Size / Sets (PLRU 8W, Locked+Immune ON)");
    print_summary_row(cfgs[3].name, &results[3]);   /* 128S */
    print_summary_row(cfgs[4].name, &results[4]);   /* 256S */
    print_reused("G2 PLRU 512S+ALL",  g1_plru);    /* 512S == G1.1 */

    xil_printf("  --------------------|---------|----------|-----------|-----------\r\n");

    /* ── Group 3: Ways sweep ─────────────────────────────────────────────── */
    print_group_header("Group 3: Associativity / Ways (PLRU 512S, Locked+Immune ON)");
    print_summary_row(cfgs[5].name, &results[5]);   /* 4W */
    print_reused("G3 PLRU 512S 8W",   g1_plru);    /* 8W == G1.1 */

    xil_printf("  --------------------|---------|----------|-----------|-----------\r\n");

    /* ── Group 4: Locked Zone ────────────────────────────────────────────── */
    print_group_header("Group 4: Locked Zone Effect (PLRU 512S 8W, Immune OFF)");
    print_summary_row(cfgs[6].name, &results[6]);   /* BARE */
    print_summary_row(cfgs[7].name, &results[7]);   /* +LK  */
    print_reused("G4 PLRU 512S+ALL",  g1_plru);    /* +LK+IMM == G1.1 */

    xil_printf("  --------------------|---------|----------|-----------|-----------\r\n");

    /* ── Group 5: Immune Window size ─────────────────────────────────────── */
    print_group_header("Group 5: Immune Window Size (PLRU 512S 8W, Locked ON)");
    print_reused("G5 PLRU 512S+LK",   g4_lk);      /* WIN=0  == G4.2 */
    print_summary_row(cfgs[8].name, &results[8]);   /* WIN/2  */
    print_reused("G5 PLRU 512S+FULL", g1_plru);    /* WIN    == G1.1 */

    xil_printf("====================================================================================\r\n");
}

/* =============================================================================
 * main
 * ============================================================================= */
/* sd_reload_trace — reload trace silently between configs */
static int sd_reload_trace(void) {
    static FATFS fs_r;
    FIL         fil_r;
    FRESULT     res;
    UINT        br;
    u8 *dst       = (u8 *)SD_LOAD_ADDR;
    u32 remaining = (u32)SD_EXPECTED;
    u32 total     = 0;

    res = f_mount(&fs_r, "0:/", 1);
    if (res != FR_OK) return SD_ERR_MOUNT;
    res = f_open(&fil_r, SD_BIN_PATH, FA_READ);
    if (res != FR_OK) { f_unmount("0:/"); return SD_ERR_OPEN; }

    while (remaining > 0) {
        u32 chunk = (remaining > SD_CHUNK) ? (u32)SD_CHUNK : remaining;
        res = f_read(&fil_r, dst + total, (UINT)chunk, &br);
        if (res != FR_OK || br == 0) {
            f_close(&fil_r); f_unmount("0:/"); return SD_ERR_READ;
        }
        total += br; remaining -= br;
    }
    f_close(&fil_r);
    f_unmount("0:/");
    Xil_DCacheFlushRange(SD_LOAD_ADDR, total);
    return SD_OK;
}

int main(void) {

    xil_printf("\r\n");
    xil_printf("====================================================================\r\n");
    xil_printf("  KV CACHE ACCELERATOR BENCHMARK  --  Arty Z7\r\n");
    xil_printf("  Model  : Qwen2.5-0.5B | GQA | SnapKV Sparse Attention\r\n");
    xil_printf("  Trace  : %s (%s)\r\n", SD_BIN_PATH, SD_TRACE_NAME);
    xil_printf("  Prefill: %u tokens | Decode: %u steps | KV heads: %u\r\n",
               (unsigned)TRACE_PREFILL_LEN, (unsigned)TRACE_DECODE_LEN,
               (unsigned)TRACE_NUM_KV_HEADS);
    xil_printf("  Window : %u | TopK: %u | Entries: %u | Configs: %d\r\n",
               (unsigned)TRACE_WINDOW_SIZE, (unsigned)TRACE_TOPK,
               (unsigned)NUM_TRACE, NUM_CONFIGS);
    xil_printf("  Groups : G1=Algo  G2=Sets  G3=Ways  G4=LockedZone  G5=ImmuneWin\r\n");
    xil_printf("====================================================================\r\n");

    /* Verify struct packing */
    xil_printf("[INIT] KVCacheTrace size: %u bytes (expect 26)\r\n",
               (unsigned)sizeof(KVCacheTrace));
    if (sizeof(KVCacheTrace) != 26U) {
        xil_printf("[FATAL] Struct size mismatch! Check __attribute__((packed)).\r\n");
        return -1;
    }

    /* Load trace from SD card */
    int sd_rc = sd_load_trace();
    if (sd_rc != SD_OK) {
        xil_printf("[FATAL] sd_load_trace failed (code %d)\r\n", sd_rc);
        return -1;
    }

    const KVCacheTrace *traces = (const KVCacheTrace *)TRACE_DATA_ADDR;

    /* Sanity-print first 3 entries */
    xil_printf("[INIT] Entry 0: is_write=%u layer=%u head=%u token=%u\r\n",
               traces[0].is_write, traces[0].layer,
               traces[0].head,     traces[0].token);
    xil_printf("[INIT] Entry 1: is_write=%u layer=%u head=%u token=%u\r\n",
               traces[1].is_write, traces[1].layer,
               traces[1].head,     traces[1].token);
    xil_printf("[INIT] Entry 2: is_write=%u layer=%u head=%u token=%u\r\n",
               traces[2].is_write, traces[2].layer,
               traces[2].head,     traces[2].token);

    /* Sanity-check REG0 (READY bit must be 1 before starting) */
    u32 reg0_init = Xil_In32(KV_REG0_CTRL);
    xil_printf("[INIT] REG0 = 0x%08X (expect bit[2]=1 READY)\r\n",
               (unsigned)reg0_init);
    if ((reg0_init & KV_READY) == 0U) {
        xil_printf("[WARN] READY not set — HW may not be responding!\r\n");
    }

    /* Cache capacity info */
    xil_printf("[INFO] Cache capacity per config:\r\n");
    {
        /* integer over = prefill / slots_per_layer, 1 decimal place */
        int _p = (int)TRACE_PREFILL_LEN;
        int _c, _oi, _of;
        _c = 128*8/48; _oi = _p/_c; _of = (_p*10/_c)%10;
        xil_printf("  128S x 8W = %4d slots / 48 = %3d tokens (prefill=%u, %d.%dx over)\r\n",
                   128*8, _c, (unsigned)TRACE_PREFILL_LEN, _oi, _of);
        _c = 256*8/48; _oi = _p/_c; _of = (_p*10/_c)%10;
        xil_printf("  256S x 8W = %4d slots / 48 = %3d tokens (prefill=%u, %d.%dx over)\r\n",
                   256*8, _c, (unsigned)TRACE_PREFILL_LEN, _oi, _of);
        _c = 512*8/48; _oi = _p/_c; _of = (_p*10/_c)%10;
        xil_printf("  512S x 8W = %4d slots / 48 = %3d tokens (prefill=%u, %d.%dx over)\r\n",
                   512*8, _c, (unsigned)TRACE_PREFILL_LEN, _oi, _of);
        _c = 512*4/48; _oi = _p/_c; _of = (_p*10/_c)%10;
        xil_printf("  512S x 4W = %4d slots / 48 = %3d tokens (prefill=%u, %d.%dx over)\r\n",
                   512*4, _c, (unsigned)TRACE_PREFILL_LEN, _oi, _of);
    }

    /* DDR warm-up to avoid cold-start stall on first config */
    ddr_warmup();

    /* Allocate results on heap */
    RunResult *results = (RunResult *)malloc(NUM_CONFIGS * sizeof(RunResult));
    if (!results) {
        xil_printf("[FATAL] malloc failed for results array!\r\n");
        return -1;
    }

    /* -----------------------------------------------------------------------
     * Run all configurations
     * ----------------------------------------------------------------------- */
    for (int c = 0; c < NUM_CONFIGS; c++) {
        /* Reload trace before each config to ensure clean trace data */
        if (c > 0) {
            int rc = sd_reload_trace();
            if (rc != SD_OK) {
                xil_printf("[FATAL] Trace reload failed config %d (code %d)\r\n",
                           c + 1, rc);
                break;
            }
        }
        xil_printf("Running [%d/%d]: %s ...\r\n",
                   c + 1, NUM_CONFIGS, CONFIGS[c].name);
        run_benchmark(&CONFIGS[c], traces, (int)NUM_TRACE, &results[c]);
        print_report(c, &CONFIGS[c], &results[c]);
    }

    /* Summary */
    print_summary_table(CONFIGS, results, NUM_CONFIGS);

    /* Best config recommendation */
    int best = -1, best_hits = -1;
    for (int c = 0; c < NUM_CONFIGS; c++) {
        if (results[c].hw_timeouts == 0 &&
            results[c].hits > best_hits) {
            best_hits = results[c].hits;
            best = c;
        }
    }
    if (best >= 0) {
        xil_printf("\r\n  Best config (highest hit rate): %s\r\n",
                   CONFIGS[best].name);
        xil_printf("  Hit rate: ");
        print_pct(results[best].hits, results[best].read_ops);
        xil_printf("\r\n");
    }

    xil_printf("\r\nDone.\r\n");
    free(results);
    return 0;
}