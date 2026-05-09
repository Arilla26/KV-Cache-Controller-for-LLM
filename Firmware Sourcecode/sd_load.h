#ifndef SD_LOAD_H
#define SD_LOAD_H

/* =============================================================================
 * sd_load.h — Load SnapKV trace from SD card into DDR
 * Target  : Arty Z7 (Zynq-7020), Vitis bare-metal
 * Requires: xilffs BSP library (enable in BSP Settings -> xilffs)
 *
 * Usage:
 *   // Select trace size BEFORE including this header (or in compiler flags):
 *   #define TRACE_SELECT  TRACE_SMALL    // default
 *   #define TRACE_SELECT  TRACE_MEDIUM
 *   #define TRACE_SELECT  TRACE_LARGE
 *
 *   #include "sd_load.h"
 *   int rc = sd_load_trace();
 *   if (rc != SD_OK) { handle error }
 *
 * File names on SD card (8.3 format, FatFs compatible):
 *   traces.bin   —  741 KB   (TRACE_SMALL)
 *   tracem.bin   — 2964 KB   (TRACE_MEDIUM)
 *   tracel.bin   — 10920 KB  (TRACE_LARGE)
 *
 * FIX LOG v3:
 *   - Supports 3 trace sizes via TRACE_SELECT / TRACE_FILE_SIZE
 *   - SD_EXPECTED derived from TRACE_FILE_SIZE (defined in golden_trace_meta.h)
 *   - SD_BIN_PATH derived from TRACE_FILENAME (defined in golden_trace_meta.h)
 *   - Removed all hardcoded sizes and filenames
 *   - Prints trace name and size at load time for easy verification
 * ============================================================================= */

#include "ff.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "golden_trace_meta.h"   /* defines TRACE_SELECT, TRACE_FILE_SIZE,
                                    TRACE_FILENAME, NUM_TRACE, etc. */

/* ---------------------------------------------------------------------------
 * Derived constants from golden_trace_meta.h
 * --------------------------------------------------------------------------- */
#define SD_LOAD_ADDR    0x10000000UL                    /* DDR target address  */
#define SD_HDR_SIZE     TRACE_HEADER_SIZE               /* 32 bytes            */
#define SD_DATA_ADDR    (SD_LOAD_ADDR + SD_HDR_SIZE)    /* 0x10000020          */
#define SD_EXPECTED     TRACE_FILE_SIZE                 /* per-trace file size */
#define SD_BIN_PATH     TRACE_FILENAME                  /* e.g. "0:/traces.bin"*/
#define SD_CHUNK        524288UL                        /* 512 KB per f_read   */

/* Ensure TRACE_DATA_ADDR in rest of code matches SD_DATA_ADDR */
#undef  TRACE_DATA_ADDR
#define TRACE_DATA_ADDR SD_DATA_ADDR

/* ---------------------------------------------------------------------------
 * Trace size name for logging
 * --------------------------------------------------------------------------- */
#if   TRACE_SELECT == TRACE_SMALL
  #define SD_TRACE_NAME  "SMALL"
#elif TRACE_SELECT == TRACE_MEDIUM
  #define SD_TRACE_NAME  "MEDIUM"
#elif TRACE_SELECT == TRACE_LARGE
  #define SD_TRACE_NAME  "LARGE"
#endif

/* ---------------------------------------------------------------------------
 * Return codes
 * --------------------------------------------------------------------------- */
#define SD_OK            0
#define SD_ERR_MOUNT    -1
#define SD_ERR_OPEN     -2
#define SD_ERR_SIZE     -3
#define SD_ERR_READ     -4
#define SD_ERR_MAGIC    -5

/* ---------------------------------------------------------------------------
 * sd_load_trace — mount SD, read trace file into DDR, validate header.
 * Returns SD_OK on success, negative error code on failure.
 * --------------------------------------------------------------------------- */
static int sd_load_trace(void)
{
    static FATFS fs;
    FIL     fil;
    FRESULT res;
    UINT    bytes_read;
    u8     *dst        = (u8 *)SD_LOAD_ADDR;
    u32     total_read = 0UL;
    u32     remaining  = (u32)SD_EXPECTED;

    /* Print selected trace info */
    xil_printf("[SD] Trace      : %s (%s)\r\n", SD_BIN_PATH, SD_TRACE_NAME);
    xil_printf("[SD] DDR target : 0x%08X\r\n",  (unsigned int)SD_LOAD_ADDR);
    xil_printf("[SD] Expected   : %u bytes\r\n", (unsigned int)SD_EXPECTED);

    /* 1. Mount SD card */
    res = f_mount(&fs, "0:/", 1);
    if (res != FR_OK) {
        xil_printf("[SD] f_mount failed: %d\r\n", (int)res);
        return SD_ERR_MOUNT;
    }
    xil_printf("[SD] SD card mounted OK\r\n");

    /* 2. Open file */
    res = f_open(&fil, SD_BIN_PATH, FA_READ);
    if (res != FR_OK) {
        xil_printf("[SD] Cannot open %s (err=%d)\r\n", SD_BIN_PATH, (int)res);
        xil_printf("[SD] Make sure %s is in SD card root.\r\n", SD_BIN_PATH);
        f_unmount("0:/");
        return SD_ERR_OPEN;
    }
    xil_printf("[SD] File opened OK\r\n");

    /* 3. Read SD_EXPECTED bytes in chunks directly into DDR */
    xil_printf("[SD] Loading to DDR 0x%08X ", (unsigned int)SD_LOAD_ADDR);

    while (remaining > 0UL) {
        u32 chunk = (remaining > SD_CHUNK) ? (u32)SD_CHUNK : remaining;

        res = f_read(&fil, dst + total_read, (UINT)chunk, &bytes_read);

        if (res != FR_OK) {
            xil_printf("\r\n[SD] f_read error at offset %u (FatFs err=%d)\r\n",
                       (unsigned int)total_read, (int)res);
            f_close(&fil);
            f_unmount("0:/");
            return SD_ERR_READ;
        }

        if (bytes_read == 0U) {
            xil_printf("\r\n[SD] Unexpected EOF at offset %u"
                       " (got %u / %u bytes)\r\n",
                       (unsigned int)total_read,
                       (unsigned int)total_read,
                       (unsigned int)SD_EXPECTED);
            f_close(&fil);
            f_unmount("0:/");
            return SD_ERR_SIZE;
        }

        total_read += (u32)bytes_read;
        remaining  -= (u32)bytes_read;
        xil_printf(".");   /* one dot per 512 KB chunk */
    }

    f_close(&fil);
    f_unmount("0:/");
    xil_printf("\r\n[SD] Read complete: %u bytes\r\n", (unsigned int)total_read);

    /* 4. Flush D-cache so CPU sees data written by SD DMA controller */
    Xil_DCacheFlushRange(SD_LOAD_ADDR, total_read);

    /* 5. Validate magic header "KVCACHE1" */
    if (!trace_validate(dst)) {
        xil_printf("[SD] Invalid magic header!\r\n");
        xil_printf("[SD] Got: 0x%02X 0x%02X 0x%02X 0x%02X "
                   "0x%02X 0x%02X 0x%02X 0x%02X\r\n",
                   dst[0], dst[1], dst[2], dst[3],
                   dst[4], dst[5], dst[6], dst[7]);
        return SD_ERR_MAGIC;
    }

    xil_printf("[SD] Header OK  : %u entries | %u layers | %u KV heads"
               " | prefill=%u | decode=%u | window=%u | topk=%u\r\n",
               (unsigned int)NUM_TRACE,
               (unsigned int)TRACE_NUM_LAYERS,
               (unsigned int)TRACE_NUM_KV_HEADS,
               (unsigned int)TRACE_PREFILL_LEN,
               (unsigned int)TRACE_DECODE_LEN,
               (unsigned int)TRACE_WINDOW_SIZE,
               (unsigned int)TRACE_TOPK);

    return SD_OK;
}

#endif /* SD_LOAD_H */