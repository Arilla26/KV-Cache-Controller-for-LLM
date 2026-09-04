#!/usr/bin/env python3
"""
generate_trace.py — SnapKV Sparse Attention KV Cache Trace Generator
=====================================================================
Model   : Qwen2.5-0.5B (synthetic, seed-fixed, realistic distribution)
Pattern : SnapKV = token-0 sink (Locked Zone) +
                   local window (Immune Window) +
                   top-K heavy hitter (eviction algorithm)

Output  : trace_s.bin / trace_m.bin / trace_l.bin
Format  : 32-byte header + N × 26-byte KVCacheTrace structs

KVCacheTrace (packed, 26 bytes):
  u8  is_write      1=WRITE new KV, 0=READ from cache
  u8  expected_hit  1=must HIT, 0=don't care
  u16 layer         0..23
  u16 head          0..1  (GQA: 2 KV heads)
  u32 token         token position in sequence
  u32 k_l           Key   bits [31:0]
  u32 k_h           Key   bits [63:32]
  u32 v_l           Value bits [31:0]
  u32 v_h           Value bits [63:32]

Header (32 bytes):
  u8[8]  magic      "KVCACHE1"
  u32    num_entries
  u16    num_layers
  u16    num_kv_heads
  u16    prefill_len
  u16    decode_len
  u16    window_size
  u16    topk
  u8     pattern    0=SnapKV
  u8[7]  reserved
"""

import struct
import numpy as np
import json
import os
import sys

# ─────────────────────────────────────────────────────────────────────────────
# Fixed format constants (binary layout — not configurable)
# ─────────────────────────────────────────────────────────────────────────────
STRUCT_FMT  = "<BBHHIIIIi"   # NOTE: last field unused, keep layout
STRUCT_SIZE = 26             # bytes (packed: 1+1+2+2+4+4+4+4+4 = 26)
HEADER_SIZE = 32
HEADER_MAGIC = b"KVCACHE1"

PATTERN_SNAPKV = 0

DEFAULT_CONFIG = "trace_config.json"


# ─────────────────────────────────────────────────────────────────────────────
# Configuration loading
#
# Model topology and trace parameters live in an external JSON file, so a
# benchmark configuration can be changed without editing this script.
# ─────────────────────────────────────────────────────────────────────────────
MODEL_REQUIRED = ("num_layers", "num_kv_heads", "master_seed")
TRACE_REQUIRED = ("name", "filename", "prefill", "decode", "window", "topk")


def _as_int(value, field):
    """Accept both 48879 and "0xBEEF" for integer fields."""
    if isinstance(value, bool):
        raise ValueError(f"field '{field}' must be an integer, got a boolean")
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value, 0)
        except ValueError:
            pass
    raise ValueError(f"field '{field}' must be an integer, got {value!r}")


def load_config(path=DEFAULT_CONFIG):
    """
    Read the benchmark configuration from a JSON file.

    Returns (model, traces): model holds the topology parameters, traces is a
    list of per-trace parameter dicts. Exits with a readable message if the
    file is missing or malformed, rather than failing on a KeyError halfway
    through generation.
    """
    try:
        with open(path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except FileNotFoundError:
        raise SystemExit(f"ERROR: config file not found: {path}")
    except json.JSONDecodeError as e:
        raise SystemExit(f"ERROR: {path} is not valid JSON — {e}")

    if not isinstance(cfg, dict):
        raise SystemExit(f"ERROR: {path} must hold a JSON object at the top level")

    model = cfg.get("model")
    if not isinstance(model, dict):
        raise SystemExit(f"ERROR: {path} is missing a 'model' object")
    missing = [k for k in MODEL_REQUIRED if k not in model]
    if missing:
        raise SystemExit(f"ERROR: 'model' is missing field(s): {', '.join(missing)}")

    try:
        model = dict(
            num_layers   = _as_int(model["num_layers"],   "model.num_layers"),
            num_kv_heads = _as_int(model["num_kv_heads"], "model.num_kv_heads"),
            master_seed  = _as_int(model["master_seed"],  "model.master_seed"),
            name         = str(model.get("name", "unnamed model")),
        )
    except ValueError as e:
        raise SystemExit(f"ERROR: {e}")

    traces = cfg.get("traces")
    if not isinstance(traces, list) or not traces:
        raise SystemExit(f"ERROR: {path} must define a non-empty 'traces' list")

    parsed = []
    for i, tr in enumerate(traces):
        if not isinstance(tr, dict):
            raise SystemExit(f"ERROR: traces[{i}] must be an object")
        missing = [k for k in TRACE_REQUIRED if k not in tr]
        if missing:
            label = tr.get("name", f"index {i}")
            raise SystemExit(f"ERROR: trace '{label}' is missing field(s): "
                             f"{', '.join(missing)}")
        try:
            parsed.append(dict(
                name        = str(tr["name"]),
                filename    = str(tr["filename"]),
                prefill     = _as_int(tr["prefill"], f"traces[{i}].prefill"),
                decode      = _as_int(tr["decode"],  f"traces[{i}].decode"),
                window      = _as_int(tr["window"],  f"traces[{i}].window"),
                topk        = _as_int(tr["topk"],    f"traces[{i}].topk"),
                description = str(tr.get("description", "")),
            ))
        except ValueError as e:
            raise SystemExit(f"ERROR: {e}")

    return model, parsed


# Populated by main() from the JSON config before any trace is generated.
NUM_LAYERS   = None
NUM_KV_HEADS = None
MASTER_SEED  = None
MODEL_NAME   = None


# ─────────────────────────────────────────────────────────────────────────────
# Synthetic KV generation
# Realistic distribution:
#   Keys   ~ N(0, 0.02)  (small magnitude, like post-RoPE keys)
#   Values ~ N(0, 0.1)   (larger variance, like MLP outputs)
# Each (layer, head) has its own projection direction → not identical across layers
# ─────────────────────────────────────────────────────────────────────────────
def make_kv_bank(num_tokens, rng):
    """
    Returns kv_bank[layer][head][token] = (k_l, k_h, v_l, v_h)
    Each value is a u32.
    Uses float32 → reinterpret as u32 (matches what real hardware would see).
    """
    bank = {}
    for layer in range(NUM_LAYERS):
        bank[layer] = {}
        for head in range(NUM_KV_HEADS):
            # Per-layer, per-head scale to make distributions non-identical
            k_scale = 0.02 * (1.0 + 0.1 * layer)
            v_scale = 0.10 * (1.0 + 0.05 * layer)

            # Generate 64-bit key and value as two float32 halves
            k_raw = rng.normal(0.0, k_scale, (num_tokens, 2)).astype(np.float32)
            v_raw = rng.normal(0.0, v_scale, (num_tokens, 2)).astype(np.float32)

            # Reinterpret float32 bits as u32
            k_l = k_raw[:, 0].view(np.uint32)
            k_h = k_raw[:, 1].view(np.uint32)
            v_l = v_raw[:, 0].view(np.uint32)
            v_h = v_raw[:, 1].view(np.uint32)

            bank[layer][head] = (k_l, k_h, v_l, v_h)
    return bank


# ─────────────────────────────────────────────────────────────────────────────
# Attention score simulation
# Real attention has "heavy hitter" property: a few tokens get most of the
# score. We model this with power-law decay from a random permutation.
# Token 0 always gets a large score bonus (Attention Sink).
# Recent tokens get higher scores (recency bias).
# ─────────────────────────────────────────────────────────────────────────────
def simulate_attention_scores(context_len, current_pos, rng):
    """
    Returns attention score array of shape (context_len,).
    Higher = more important = more likely to be top-K.
    """
    scores = np.zeros(context_len, dtype=np.float32)

    # Base: random heavy-hitter pattern (power-law)
    ranks = rng.permutation(context_len).astype(np.float32)
    scores += 1.0 / (ranks + 1.0)

    # Recency bias: token closer to current_pos scores higher
    positions = np.arange(context_len, dtype=np.float32)
    recency   = np.exp(-0.02 * (current_pos - positions))
    scores   += 0.5 * recency

    # Attention sink: token 0 always high
    scores[0] += 10.0

    return scores


# ─────────────────────────────────────────────────────────────────────────────
# SnapKV access set selection
# Returns sorted list of token indices to READ in this decode step.
# ─────────────────────────────────────────────────────────────────────────────
def snapkv_access_set(context_len, current_pos, window, topk, rng):
    """
    SnapKV: sink (token 0) + local window (last W tokens) + top-K heavy hitter

    context_len : number of tokens available (prefill + decode steps so far)
    current_pos : index of the token being generated (= context_len)
    window      : number of most-recent tokens always included
    topk        : number of heavy-hitter tokens to select

    Returns: sorted list of token indices, each with expected_hit flag.
    """
    access = set()

    # 1. Attention Sink — token 0 always accessed
    access.add(0)

    # 2. Local window — last `window` tokens before current_pos
    local_start = max(0, context_len - window)
    for t in range(local_start, context_len):
        access.add(t)

    # 3. Top-K heavy hitter from the non-window prefix
    prefix_len = local_start  # tokens 1 .. local_start-1
    if prefix_len > 1 and topk > 0:
        scores  = simulate_attention_scores(prefix_len, current_pos, rng)
        scores[0] = -1e9   # token 0 already included, exclude from top-K
        topk_actual = min(topk, prefix_len - 1)
        top_indices = np.argpartition(scores, -topk_actual)[-topk_actual:]
        for t in top_indices:
            if t > 0:   # safety: never re-add token 0 via this path
                access.add(int(t))

    return sorted(access)


# ─────────────────────────────────────────────────────────────────────────────
# Pack one entry into 26 bytes
# ─────────────────────────────────────────────────────────────────────────────
def pack_entry(is_write, expected_hit, layer, head, token, k_l, k_h, v_l, v_h):
    """
    Struct layout (packed, no padding):
      u8  is_write
      u8  expected_hit
      u16 layer
      u16 head
      u32 token
      u32 k_l
      u32 k_h
      u32 v_l
      u32 v_h
    Total = 1+1+2+2+4+4+4+4+4 = 26 bytes
    """
    return struct.pack("<BBHHIIIIi",
        int(is_write)   & 0xFF,
        int(expected_hit) & 0xFF,
        int(layer)      & 0xFFFF,
        int(head)       & 0xFFFF,
        int(token)      & 0xFFFFFFFF,
        int(k_l)        & 0xFFFFFFFF,
        int(k_h)        & 0xFFFFFFFF,
        int(v_l)        & 0xFFFFFFFF,
        int(v_h)        & 0x7FFFFFFF,   # signed field, keep positive
    )


def pack_entry_26(is_write, expected_hit, layer, head, token, k_l, k_h, v_l, v_h):
    """Pack exactly 26 bytes using two separate struct calls to avoid signed issues."""
    part1 = struct.pack("<BBHHI",
        int(is_write)    & 0xFF,
        int(expected_hit) & 0xFF,
        int(layer)       & 0xFFFF,
        int(head)        & 0xFFFF,
        int(token)       & 0xFFFFFFFF,
    )  # 10 bytes
    part2 = struct.pack("<IIII",
        int(k_l) & 0xFFFFFFFF,
        int(k_h) & 0xFFFFFFFF,
        int(v_l) & 0xFFFFFFFF,
        int(v_h) & 0xFFFFFFFF,
    )  # 16 bytes
    raw = part1 + part2   # 26 bytes
    assert len(raw) == 26, f"pack bug: {len(raw)} bytes"
    return raw


# ─────────────────────────────────────────────────────────────────────────────
# Write binary header (32 bytes)
# ─────────────────────────────────────────────────────────────────────────────
def write_header(f, num_entries, prefill, decode, window, topk):
    hdr = HEADER_MAGIC                              # 8 bytes
    hdr += struct.pack("<I",  num_entries)          # 4 bytes  num_entries
    hdr += struct.pack("<HH", NUM_LAYERS, NUM_KV_HEADS)  # 4 bytes
    hdr += struct.pack("<HH", prefill, decode)      # 4 bytes
    hdr += struct.pack("<HH", window, topk)         # 4 bytes
    hdr += struct.pack("<B",  PATTERN_SNAPKV)       # 1 byte   pattern
    hdr += b'\x00' * 7                              # 7 bytes  reserved
    assert len(hdr) == HEADER_SIZE
    f.write(hdr)


# ─────────────────────────────────────────────────────────────────────────────
# Generate one trace file
# ─────────────────────────────────────────────────────────────────────────────
def generate_trace(cfg, out_dir="."):
    prefill  = cfg["prefill"]
    decode   = cfg["decode"]
    window   = cfg["window"]
    topk     = cfg["topk"]
    filename = cfg["filename"]
    name     = cfg["name"]

    print(f"\n{'='*60}")
    print(f"Generating Trace {name}: {filename}")
    print(f"  {cfg['description']}")
    print(f"  Prefill={prefill}, Decode={decode}, Window={window}, TopK={topk}")
    print(f"{'='*60}")

    # Seeded RNG — deterministic
    rng = np.random.default_rng(MASTER_SEED ^ (prefill * 0x1000 + decode))

    # Pre-generate KV data for all tokens (prefill + decode)
    total_tokens = prefill + decode
    print(f"  Generating KV bank for {total_tokens} tokens × {NUM_LAYERS} layers × {NUM_KV_HEADS} heads...")
    kv_bank = make_kv_bank(total_tokens, rng)

    # ── Phase 1: collect entries in memory to get count for header ──
    # (entries list of bytes objects)
    entries = []

    # ── PREFILL: WRITE all (layer, head, token) pairs ──────────────
    print(f"  Writing prefill ({prefill} tokens × {NUM_LAYERS}L × {NUM_KV_HEADS}H = {prefill*NUM_LAYERS*NUM_KV_HEADS:,} WRITEs)...")
    for token in range(prefill):
        for layer in range(NUM_LAYERS):
            for head in range(NUM_KV_HEADS):
                k_l, k_h, v_l, v_h = (
                    kv_bank[layer][head][0][token],
                    kv_bank[layer][head][1][token],
                    kv_bank[layer][head][2][token],
                    kv_bank[layer][head][3][token],
                )
                entries.append(pack_entry_26(
                    is_write=1, expected_hit=0,
                    layer=layer, head=head, token=token,
                    k_l=k_l, k_h=k_h, v_l=v_l, v_h=v_h
                ))

    # ── DECODE: step-by-step ────────────────────────────────────────
    print(f"  Writing decode ({decode} steps)...")

    # Track which (layer, head, token) are currently in cache.
    # We model cache state at high level: a token is "in cache" if it
    # was recently written and not evicted. For expected_hit annotation,
    # we use a conservative rule:
    #   - Token 0: always expected_hit=1 (Locked Zone)
    #   - Local window tokens: always expected_hit=1 (Immune Window)
    #   - Top-K tokens: expected_hit=1 only if prefill fitted in cache
    #     (i.e., no eviction pressure on those tokens)
    #
    # This is a simplified model — actual hit depends on runtime eviction.
    # We annotate conservatively so expected_hit=1 means "should definitely hit".

    prefill_fits = (prefill * NUM_LAYERS * NUM_KV_HEADS) <= (512 * 8)

    for step in range(decode):
        decode_token = prefill + step
        context_len  = prefill + step   # tokens available BEFORE this step

        # ── WRITE: new decode token ────────────────────────────────
        for layer in range(NUM_LAYERS):
            for head in range(NUM_KV_HEADS):
                k_l, k_h, v_l, v_h = (
                    kv_bank[layer][head][0][decode_token],
                    kv_bank[layer][head][1][decode_token],
                    kv_bank[layer][head][2][decode_token],
                    kv_bank[layer][head][3][decode_token],
                )
                entries.append(pack_entry_26(
                    is_write=1, expected_hit=0,
                    layer=layer, head=head, token=decode_token,
                    k_l=k_l, k_h=k_h, v_l=v_l, v_h=v_h
                ))

        # ── READ: sparse access set for this decode step ───────────
        access_tokens = snapkv_access_set(
            context_len=context_len,
            current_pos=decode_token,
            window=window,
            topk=topk,
            rng=rng,
        )

        local_start = max(0, context_len - window)

        for t in access_tokens:
            # Determine expected_hit
            is_sink   = (t == 0)
            is_local  = (t >= local_start)
            is_topk   = (not is_sink and not is_local)

            if is_sink:
                exp_hit = 1   # Locked Zone — always in cache
            elif is_local:
                exp_hit = 1   # Immune Window — always in cache
            elif is_topk and prefill_fits:
                exp_hit = 1   # Prefill fits → heavy hitter still in cache
            else:
                exp_hit = 0   # Uncertain — depends on eviction algorithm

            for layer in range(NUM_LAYERS):
                for head in range(NUM_KV_HEADS):
                    k_l, k_h, v_l, v_h = (
                        kv_bank[layer][head][0][t],
                        kv_bank[layer][head][1][t],
                        kv_bank[layer][head][2][t],
                        kv_bank[layer][head][3][t],
                    )
                    entries.append(pack_entry_26(
                        is_write=0, expected_hit=exp_hit,
                        layer=layer, head=head, token=t,
                        k_l=k_l, k_h=k_h, v_l=v_l, v_h=v_h
                    ))

        if (step + 1) % 16 == 0 or step == decode - 1:
            print(f"    Step {step+1}/{decode}: {len(entries):,} entries so far")

    # ── Write file ──────────────────────────────────────────────────
    num_entries  = len(entries)
    total_bytes  = HEADER_SIZE + num_entries * STRUCT_SIZE
    out_path     = os.path.join(out_dir, filename)

    print(f"\n  Total entries : {num_entries:,}")
    print(f"  File size     : {total_bytes:,} bytes ({total_bytes/1024:.1f} KB)")

    with open(out_path, "wb") as f:
        write_header(f, num_entries, prefill, decode, window, topk)
        for e in entries:
            f.write(e)

    actual_size = os.path.getsize(out_path)
    assert actual_size == total_bytes, f"Size mismatch: {actual_size} vs {total_bytes}"

    # ── Verify magic ────────────────────────────────────────────────
    with open(out_path, "rb") as f:
        magic = f.read(8)
    assert magic == HEADER_MAGIC, f"Magic mismatch: {magic}"

    # ── Stats ───────────────────────────────────────────────────────
    write_count = sum(1 for e in entries if e[0] == 1)
    read_count  = num_entries - write_count
    exp_hit_count = sum(1 for e in entries if e[0] == 0 and e[1] == 1)
    exp_hit_pct   = exp_hit_count / read_count * 100 if read_count > 0 else 0

    print(f"  WRITEs        : {write_count:,}")
    print(f"  READs         : {read_count:,}")
    print(f"  Expected HITs : {exp_hit_count:,} / {read_count:,} = {exp_hit_pct:.1f}%")
    print(f"  Written to    : {out_path}")
    print(f"  ✓ Magic verified OK")

    return out_path


# ─────────────────────────────────────────────────────────────────────────────
# Verify a trace file by reading back header + first few entries
# ─────────────────────────────────────────────────────────────────────────────
def verify_trace(path):
    print(f"\n  Verifying {os.path.basename(path)}...")
    with open(path, "rb") as f:
        # Header
        magic       = f.read(8)
        num_entries = struct.unpack("<I", f.read(4))[0]
        num_layers, num_kv_heads = struct.unpack("<HH", f.read(4))
        prefill, decode          = struct.unpack("<HH", f.read(4))
        window, topk             = struct.unpack("<HH", f.read(4))
        pattern                  = struct.unpack("<B", f.read(1))[0]
        f.read(7)  # reserved

        assert magic == HEADER_MAGIC
        assert num_layers   == NUM_LAYERS
        assert num_kv_heads == NUM_KV_HEADS

        print(f"    Magic      : {magic.decode()}")
        print(f"    Entries    : {num_entries:,}")
        print(f"    Prefill    : {prefill}, Decode: {decode}")
        print(f"    Window     : {window}, TopK: {topk}")
        print(f"    Pattern    : {'SnapKV' if pattern == 0 else 'Unknown'}")

        # Read first 3 entries
        print(f"    First 3 entries:")
        for i in range(min(3, num_entries)):
            raw = f.read(STRUCT_SIZE)
            assert len(raw) == STRUCT_SIZE
            is_w, exp_h, layer, head, token, kl, kh, vl, vh = struct.unpack("<BBHHIIIII", raw)
            print(f"      [{i}] {'WRITE' if is_w else 'READ ':5s} "
                  f"exp_hit={exp_h} L={layer:2d} H={head} T={token:4d} "
                  f"kl=0x{kl:08X} kh=0x{kh:08X}")

        # Check file size
        f.seek(0, 2)
        actual_size = f.tell()
        expected_size = HEADER_SIZE + num_entries * STRUCT_SIZE
        assert actual_size == expected_size, \
            f"Size mismatch: {actual_size} vs {expected_size}"
        print(f"    File size  : {actual_size:,} bytes ✓")
    print(f"    ✓ Verification passed")


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
def main():
    global NUM_LAYERS, NUM_KV_HEADS, MASTER_SEED, MODEL_NAME

    # Usage: generate_trace.py [config.json] [output_dir]
    cfg_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_CONFIG
    out_dir  = sys.argv[2] if len(sys.argv) > 2 else "."

    model, traces = load_config(cfg_path)
    NUM_LAYERS   = model["num_layers"]
    NUM_KV_HEADS = model["num_kv_heads"]
    MASTER_SEED  = model["master_seed"]
    MODEL_NAME   = model["name"]

    os.makedirs(out_dir, exist_ok=True)

    print("SnapKV Sparse Attention Trace Generator")
    print(f"Config file      : {os.path.abspath(cfg_path)}")
    print(f"Output directory : {os.path.abspath(out_dir)}")
    print(f"Model            : {MODEL_NAME} (synthetic, seed=0x{MASTER_SEED:08X})")
    print(f"Layers           : {NUM_LAYERS}, KV heads: {NUM_KV_HEADS}")
    print(f"Pattern          : SnapKV (sink + local window + top-K)")
    print(f"Traces           : {', '.join(t['name'] for t in traces)}")

    generated = []
    for cfg in traces:
        path = generate_trace(cfg, out_dir)
        generated.append(path)

    print(f"\n{'='*60}")
    print("VERIFICATION")
    print(f"{'='*60}")
    for path in generated:
        verify_trace(path)

    print(f"\n{'='*60}")
    print("SUMMARY — copy these files to SD card root:")
    print(f"{'='*60}")
    for path in generated:
        size = os.path.getsize(path)
        print(f"  {os.path.basename(path):20s}  {size:>10,} bytes  ({size/1024:.1f} KB)")

    names = " / ".join(os.path.basename(p) for p in generated)
    print(f"\nDone. Copy {names} to SD card.")
    print("Update sd_load.h and main.c to select which trace to load.")


if __name__ == "__main__":
    main()