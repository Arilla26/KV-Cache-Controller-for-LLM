#ifndef GOLDEN_TRACE_META_H
#define GOLDEN_TRACE_META_H

#include "xil_types.h"

/* =============================================================================
 * KV Cache Trace Metadata
 * Model   : Qwen2.5-0.5B (synthetic, seed-fixed, realistic distribution)
 * Pattern : SnapKV Sparse Attention
 *             - Token 0        : Attention Sink  → Locked Zone
 *             - Local window   : N recent tokens → Immune Window
 *             - Top-K          : Heavy hitter    → eviction algorithm target
 *
 * DDR layout (Zynq-7020, 512MB: 0x00100000 - 0x1FFFFFFF):
 *   0x10000000  File header (32 bytes, magic "KVCACHE1")
 *   0x10000020  Trace data  (N * 26 bytes)
 *
 * Three trace sizes — select ONE by defining TRACE_SELECT before including:
 *   #define TRACE_SELECT  TRACE_SMALL    (default if not defined)
 *   #define TRACE_SELECT  TRACE_MEDIUM
 *   #define TRACE_SELECT  TRACE_LARGE
 * ============================================================================= */

/* ---------------------------------------------------------------------------
 * Trace size identifiers
 * --------------------------------------------------------------------------- */
#define TRACE_SMALL   0
#define TRACE_MEDIUM  1
#define TRACE_LARGE   2

#ifndef TRACE_SELECT
#define TRACE_SELECT  TRACE_SMALL
#endif

/* ---------------------------------------------------------------------------
 * Packed struct — 26 bytes, no compiler padding
 *
 * Header layout (32 bytes):
 *   u8[8]  magic          "KVCACHE1"
 *   u32    num_entries
 *   u16    num_layers
 *   u16    num_kv_heads
 *   u16    prefill_len
 *   u16    decode_len
 *   u16    window_size
 *   u16    topk
 *   u8     pattern        0 = SnapKV
 *   u8[7]  reserved
 * --------------------------------------------------------------------------- */
typedef struct __attribute__((packed)) {
    u8  is_write;       /* 1=WRITE new KV, 0=READ from cache        */
    u8  expected_hit;   /* 1=must HIT (sink/window), 0=don't care   */
    u16 layer;          /* layer index [0..23]                       */
    u16 head;           /* KV head index GQA [0..1]                  */
    u32 token;          /* token position in sequence                */
    u32 k_l;            /* Key   bits [31: 0]                        */
    u32 k_h;            /* Key   bits [63:32]                        */
    u32 v_l;            /* Value bits [31: 0]                        */
    u32 v_h;            /* Value bits [63:32]                        */
} KVCacheTrace;

/* ---------------------------------------------------------------------------
 * Common constants (same across all traces)
 * --------------------------------------------------------------------------- */
#define TRACE_NUM_LAYERS    24U
#define TRACE_NUM_KV_HEADS  2U
#define TRACE_STRUCT_SIZE   26U
#define TRACE_HEADER_SIZE   32U
#define TRACE_DDR_LOAD_ADDR 0x10000000UL
#define TRACE_DATA_ADDR     (TRACE_DDR_LOAD_ADDR + TRACE_HEADER_SIZE)

/* ---------------------------------------------------------------------------
 * Per-trace parameters
 *
 * TRACE_SMALL  — verify correctness
 *   Prefill 32 tokens × 24L × 2H = 1,536 unique entries (37.5% cache)
 *   Expected hit ~100% — all prefill fits in 512S×8W
 *
 * TRACE_MEDIUM — meaningful benchmark
 *   Prefill 256 tokens — working set 33tok×24L×2H = 1,584 slots (38.7%)
 *   Expected hit ~51% for expected_hit=1 entries
 *
 * TRACE_LARGE  — stress test / differentiate eviction algorithms
 *   Prefill 512 tokens — working set 65tok×24L×2H = 3,120 slots (76.2%)
 *   Expected hit ~50% for expected_hit=1 entries
 * --------------------------------------------------------------------------- */
#if   TRACE_SELECT == TRACE_SMALL

  #define TRACE_FILENAME      "0:/traces.bin"
  #define NUM_TRACE           29184UL
  #define TRACE_PREFILL_LEN   32U
  #define TRACE_DECODE_LEN    32U
  #define TRACE_WINDOW_SIZE   8U
  #define TRACE_TOPK          8U
  /* File size = HEADER(32) + 29184 * 26 = 758,816 bytes */
  #define TRACE_FILE_SIZE     758816UL

#elif TRACE_SELECT == TRACE_MEDIUM

  #define TRACE_FILENAME      "0:/tracem.bin"
  #define NUM_TRACE           116736UL
  #define TRACE_PREFILL_LEN   256U
  #define TRACE_DECODE_LEN    64U
  #define TRACE_WINDOW_SIZE   16U
  #define TRACE_TOPK          16U
  /* File size = HEADER(32) + 116736 * 26 = 3,035,168 bytes */
  #define TRACE_FILE_SIZE     3035168UL

#elif TRACE_SELECT == TRACE_LARGE

  #define TRACE_FILENAME      "0:/tracel.bin"
  #define NUM_TRACE           430080UL
  #define TRACE_PREFILL_LEN   512U
  #define TRACE_DECODE_LEN    128U
  #define TRACE_WINDOW_SIZE   32U
  #define TRACE_TOPK          32U
  /* File size = HEADER(32) + 430080 * 26 = 11,182,112 bytes */
  #define TRACE_FILE_SIZE     11182112UL

#else
  #error "TRACE_SELECT must be TRACE_SMALL, TRACE_MEDIUM, or TRACE_LARGE"
#endif

/* ---------------------------------------------------------------------------
 * Locked Zone bound: token 0 locked → bound = 48 / N_WAY
 *   8-way: locked_bound = 6
 *   4-way: locked_bound = 12
 * These values are set at runtime in main.c via KV_SetFeatures().
 * --------------------------------------------------------------------------- */
#define TRACE_LOCKED_BOUND_8W   6U
#define TRACE_LOCKED_BOUND_4W   12U

/* ---------------------------------------------------------------------------
 * Validate binary file magic header "KVCACHE1"
 * --------------------------------------------------------------------------- */
static inline int trace_validate(const u8 *buf) {
    return (buf[0]=='K' && buf[1]=='V' && buf[2]=='C' && buf[3]=='A'
         && buf[4]=='C' && buf[5]=='H' && buf[6]=='E' && buf[7]=='1');
}

#endif /* GOLDEN_TRACE_META_H */