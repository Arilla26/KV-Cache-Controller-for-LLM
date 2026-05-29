# KV Cache Controller for LLM — RTL Architecture

Hardware-managed Key-Value cache controller cho LLM inference với
Sparse Attention workload, triển khai trên Arty Z7-20 (Zynq-7020) ở
50 MHz. Thiết kế gồm 7 module SystemVerilog tổ chức theo 3 cấp:
*Replacement Algorithms → Set Manager → Top Controller → AXI Wrapper*.

## Cấu hình mặc định

| Tham số | Giá trị | Ghi chú |
|---------|--------:|---------|
| `NUM_SET` | 512 | Số set của cache |
| `N_WAY` | 8 | Số way per set (đã verify 4 và 8) |
| `MAX_LAYER` | 32 | Số layer LLM tối đa |
| `MAX_HEAD` | 32 | Số attention head tối đa |
| `MAX_TOKENS` | 1024 | Context length tối đa |
| `DK_WIDTH` / `DV_WIDTH` | 64 / 64 bit | Width data Key / Value |
| `DDR_BASE_ADDR` | `0x1100_0000` | Vùng DDR cho KV cache data |
| Clock | 50 MHz (`FCLK_CLK0`) | Từ PS7 |

## Sơ đồ phân cấp

```
┌──────────────────────────────────────────────────────────┐
│  kv_cache_axi_wrapper.sv                                  │
│  ├── AXI4-Lite Slave   (CPU ↔ REG0–REG8, control plane)  │
│  ├── AXI4-Full  Master (PL → DDR via S_AXI_HP0)          │
│  └── kv_cache_top.sv  (u_kv_core)                        │
│      ├── kv_cache_set.sv  ×NUM_SET  (generate)           │
│      │   ├── plru_tree.sv      (u_plru)                  │
│      │   ├── fifo_tracker.sv   (u_fifo)                  │
│      │   └── random_lfsr.sv    (u_random)                │
│      ├── kv_delta_codec.sv    (u_codec_k)                │
│      ├── kv_delta_codec.sv    (u_codec_v)                │
│      └── BRAM array ×N_WAY    (generate, ram_style=block)│
└──────────────────────────────────────────────────────────┘
```

---

## 1. `fifo_tracker.sv`

Thuật toán thay thế **First-In-First-Out** cho 1 cache set.

**Module:** `fifo_tracker #(parameter int N_WAY = 4)`

| Port | Hướng | Mô tả |
|------|-------|-------|
| `clk`, `rst_n` | in | Clock và reset đồng bộ |
| `fill_en` | in | Bật khi điền dữ liệu mới vào set |
| `victim_way` | out | Way được chọn để evict (= `fifo_ptr`) |

**Cơ chế:** Bộ đếm vòng `fifo_ptr` rộng `$clog2(N_WAY)` bit, tăng 1
mỗi lần `fill_en` bật, tự overflow về 0. `victim_way` luôn trỏ vào way
"cũ nhất" theo thứ tự thời gian được điền vào.

**Đặc điểm:** Nhẹ nhất trong 3 thuật toán; không tính đến tần suất
truy cập (có thể evict way đang hot).

---

## 2. `random_lfsr.sv`

Thuật toán thay thế **Random (pseudo-random)** cho 1 cache set.

**Module:** `random_lfsr #(parameter int N_WAY = 4)`

| Port | Hướng | Mô tả |
|------|-------|-------|
| `clk`, `rst_n` | in | Clock và reset |
| `victim_way` | out | Way được chọn ngẫu nhiên |

**Cơ chế:** LFSR 8-bit với đa thức $x^8 + x^6 + x^5 + x^4 + 1$
(taps tại bit 7, 5, 4, 3). Seed ban đầu `8'hFF` (≠ 0 để LFSR không
kẹt). LFSR shift mỗi clock cycle (chạy tự do, không cần enable).
`victim_way` lấy `$clog2(N_WAY)` bit thấp của LFSR.

**Đặc điểm:** Phân bố đều, dễ implement HW, không có lock-in pattern.

---

## 3. `plru_tree.sv`

Thuật toán thay thế **Tree-PLRU** (Pseudo Least Recently Used).

**Module:** `plru_tree #(parameter int N_WAY = 4)` *(N_WAY phải là 4 hoặc 8)*

| Port | Hướng | Mô tả |
|------|-------|-------|
| `clk`, `rst_n` | in | Clock và reset |
| `access_en` | in | Bật khi có hit hoặc fill (cần update tree) |
| `access_way` | in | Way vừa được truy cập (MRU way) |
| `victim_way` | out | Way LRU pseudo, ứng viên evict |

**Cơ chế:** Cây nhị phân với `N_WAY - 1` bit (N=8 → 7 bit). Mỗi bit
chỉ "nhánh nào ít dùng gần đây": 0 = trái, 1 = phải.

- **Combinational (`always_comb`):** traverse cây từ root xuống lá
  theo bit hướng để tìm `victim_way`.
- **Sequential (`always_ff`):** khi `access_en` bật, traverse theo
  `access_way` (MSB-first), flip bit ngược chiều để mark đường đó
  là MRU.
- Dùng 6 biến scratch riêng biệt (3 cho comb, 3 cho seq) để tránh
  Vivado nhầm lẫn.

**Đặc điểm:** Xấp xỉ LRU thật, chỉ cần $\log_2(N\_WAY)$ bit thay vì
$N\_WAY \times \log_2(N\_WAY)$ bit của LRU đầy đủ. Hit-rate tốt
nhất trong 3 thuật toán.

---

## 4. `kv_delta_codec.sv`

**Nén BF16** cho Key/Value khi ghi xuống DDR, **giải nén** khi đọc về.

**Module:** `kv_delta_codec` (không có parameter)

| Port | Hướng | Width | Mô tả |
|------|-------|-------|-------|
| `enc_valid_in` / `enc_valid_out` | in/out | 1 | Handshake encoder |
| `raw_in` | in | 64 | Gồm 2 float32: `{float_B[31:0], float_A[31:0]}` |
| `encoded_out` | out | 32 | 2 BF16 đã pack: `{bf16_B, bf16_A}` |
| `dec_valid_in` / `dec_valid_out` | in/out | 1 | Handshake decoder |
| `encoded_in` | in | 32 | 2 BF16 input |
| `decoded_out` | out | 64 | 2 float32 đã restore |

**Cơ chế:**

- **Encoder (Float32 × 2 → BF16 × 2, tỉ số nén 2:1):**
  Stage 1 — lấy 16 bit cao của mỗi float32 (sign + exponent + 7
  mantissa bits cao); là wire slicing thuần (logic depth = 0).
  Stage 2 — register pack thành 32-bit.
- **Decoder (BF16 × 2 → Float32 × 2):**
  Unpack 2 BF16 → restore float32 bằng cách pad 16 bit 0 vào phần
  mantissa thấp.
- Pipeline 2 cycle cho cả encode và decode.

**Đặc tính sai số:** Sai số tương đối tối đa $2^{-7} \approx 0{,}78\%$.

**Lưu ý timing:** Stage 1 là wire slicing thuần — KHÔNG đóng góp vào
critical path bất kể DK_WIDTH. Đây là lý do BF16 codec không phải
bottleneck timing kể cả khi scale data width.

---

## 5. `kv_cache_set.sv`

Quản lý **1 cache set** — valid bits, dirty bits, và mux 3 thuật toán
thay thế.

**Module:** `kv_cache_set #(parameter int N_WAY = 8)`

| Port | Hướng | Mô tả |
|------|-------|-------|
| `clk`, `rst_n` | in | Clock và reset |
| `hit_en`, `hit_way` | in | Pulse + way khi có hit (update PLRU) |
| `fill_en`, `fill_way` | in | Pulse + way khi điền data mới |
| `algo_sel` | in (2 bit) | `00` = PLRU, `01` = FIFO, `10` = Random |
| `valid_bits` | out (N_WAY) | Bit valid cho mỗi way |
| `raw_victim` | out | Way nạn nhân thô từ thuật toán |
| `set_dirty_en` | in | Bật khi write hit (mark dirty) |
| `clear_dirty_en` | in | Bật sau khi evict thành công (clear dirty) |
| `dirty_way` | in | Way cần set/clear dirty |
| `dirty_bits` | out (N_WAY) | Bit dirty cho mỗi way |

**Cơ chế:**

- **Valid bits register** (N_WAY bit): set khi `fill_en`.
- **Dirty bits register** (N_WAY bit): set khi `set_dirty_en`
  (write hit/miss), clear khi `clear_dirty_en` (sau eviction).
- **Instantiate đồng thời 3 thuật toán:**
  - `u_plru` — chạy với `access_en = hit_en | fill_en`
  - `u_fifo` — chạy với `fill_en`
  - `u_random` — chạy tự do (LFSR shift mỗi cycle)
- **Mux** chọn `raw_victim` theo `algo_sel`.

Module này chỉ xuất raw victim — quyết định cuối cùng (kết hợp với
immune/locked zone) được làm ở `kv_cache_top`.

**Đặc điểm:** Mỗi set có cả 3 thuật toán cùng tồn tại — chuyển đổi
runtime không cần re-synthesize.

---

## 6. `kv_cache_top.sv` — **MODULE TRUNG TÂM**

Top-level controller tích hợp tất cả logic cache.

**Module:**
```systemverilog
kv_cache_top #(
    NUM_SET=512, N_WAY=8,
    MAX_LAYER=32, MAX_HEAD=32, MAX_TOKENS=1024,
    DK_WIDTH=64, DV_WIDTH=64
)
```

### 6.1 Giao tiếp ngoài

| Nhóm | Tín hiệu chính | Mô tả |
|------|----------------|-------|
| Cấu hình | `algo_sel`, `runtime_num_head`, `locked_*`, `local_window_size`, `immune_enable`, `active_set_mask`, `active_way_mask` | Cấu hình runtime |
| Request | `op_valid`, `op_ready`, `op_is_write`, `op_layer_id`, `op_head_id`, `op_token_idx`, `op_k`, `op_v` | Handshake nhận lệnh từ wrapper |
| Response | `resp_valid`, `resp_is_write`, `resp_hit`, `resp_k`, `resp_v` | Trả kết quả về wrapper |
| DDR | `ddr_ready`, `ddr_wr_*`, `ddr_rd_*`, `ddr_rd_valid` | Giao tiếp với AXI master trong wrapper |

### 6.2 FSM 11 trạng thái (4-bit encoding)

```
S_IDLE → S_LOOKUP_READ → S_LOOKUP_WAIT (pipeline 2-cycle để chốt
                                        valid/dirty/victim)
                              │
                              ├── HIT  ───→ S_RD_RESP   (read hit)
                              │       ───→ S_WR_UPDATE  (write hit)
                              │
                              ├── MISS clean ─→ S_RD_REQ → S_RD_WAIT
                              │                  → S_RD_DEC_WAIT
                              │                  → (write to BRAM)
                              │
                              └── MISS dirty ─→ S_EVICT_READ
                                                 → S_EVICT_ENC_WAIT
                                                 → S_EVICT_DDR_WAIT
                                                 → S_WR_UPDATE / S_RD_REQ
```

State register dùng 4 bit (`state_reg[3:0]`), còn 5 encoding dư có thể
dùng cho mở rộng tương lai.

### 6.3 BRAM array (generate N_WAY tiles)

```systemverilog
generate for (genvar w = 0; w < N_WAY; w++) begin : gen_bram_way
    (* ram_style = "block" *) reg [DATA+TAG_W-1:0] data_mem [NUM_SET-1:0];
    ...
end endgenerate
```

Tách N_WAY = 8 BRAM tiles độc lập để lách giới hạn 1 Mb/BRAM tile của
Zynq-7020. Mỗi tile lưu tag + data cho 1 way trên tất cả NUM_SET sets.

### 6.4 Set Manager (generate NUM_SET instances)

`generate` 512 instances của `kv_cache_set`, broadcast `hit_way` /
`fill_way` / `dirty_way` đến tất cả sets, mỗi set chỉ phản hồi khi
`hash_val` chỉ vào nó.

### 6.5 Codec Pipeline

Instantiate 2 codec độc lập: `u_codec_k` cho Key, `u_codec_v` cho
Value. Đi qua codec mỗi khi ghi (eviction) hoặc đọc (refill) DDR.

### 6.6 Fibonacci hash

```systemverilog
localparam logic [31:0] FIBO_CONST = 32'h9E3779B9;  // Knuth constant
linear_addr = {layer, head, token};
hash_product = linear_addr * FIBO_CONST;
hash_val     = hash_product[31 -: SET_BITS];  // top bits
```

Hash function chia đều địa chỉ tuyến tính (`{layer, head, token}`) vào
NUM_SET sets, giảm collision so với modulo. Phép nhân 32-bit dùng
2 DSP48E1.

### 6.7 Immune Flag + Hit/Miss logic

- **Immune Window:** way được bảo vệ khỏi eviction nếu
  `(max_token_id − tag_token) ≤ local_window_size`. Bảo toàn các
  token gần đây nhất.
- **Locked Zone:** token 0 (BOS token) luôn nằm ở way cố định
  `linear_id mod N_WAY`. Bảo toàn attention sink.
- **Hit detection:** so sánh tag song song trên tất cả N_WAY active.
- **Allocation:** ưu tiên invalid way → bypass immune/inactive ways
  → cuối cùng dùng `raw_victim` từ thuật toán.

### 6.8 Registered state update

Latch input vào register ở `S_IDLE` khi `op_valid` bật. Latch
`valid_bits`/`dirty_bits`/`raw_victim` từ set manager ở
`S_LOOKUP_READ`. Tính `cur_set_idx` với áp dụng Locked Zone offset.

---

## 7. `kv_cache_axi_wrapper.sv` — **AXI INTERFACE**

Wrapper bao quanh `kv_cache_top`, cung cấp giao tiếp AXI4-Lite (slave)
với PS và AXI4-Full (master) với DDR.

**Module:**
```systemverilog
kv_cache_axi_wrapper #(
    C_S_AXI_ADDR_WIDTH=6,  C_S_AXI_DATA_WIDTH=32,
    C_M_AXI_ADDR_WIDTH=32, C_M_AXI_DATA_WIDTH=64,
    NUM_SET=512, N_WAY=8,
    NUM_LAYER=32, NUM_HEAD=32, MAX_TOKENS=1024
)
```

### 7.1 AXI4-Lite Slave Register Map

| Offset | Register | Mô tả |
|-------:|----------|-------|
| `0x00` | `slv_reg0` — CTRL/STATUS | `[0]`=START, `[1]`=IS_WRITE, `[2]`=READY, `[3]`=HIT, `[4]`=SW_RST |
| `0x04` | `slv_reg1` | `[31:16]`=LAYER_ID, `[15:0]`=HEAD_ID |
| `0x08` | `slv_reg2` | TOKEN_IDX |
| `0x0C` | `slv_reg3` | KEY low (32 bit) |
| `0x10` | `slv_reg4` | KEY high (32 bit) |
| `0x14` | `slv_reg5` | VALUE low |
| `0x18` | `slv_reg6` | VALUE high |
| `0x1C` | `slv_reg7` | `[31]`=IMMUNE_EN, `[30]`=LOCKED_EN, `[29:16]`=LOCAL_WINDOW_SIZE, `[15:0]`=LOCKED_SETS_BOUND |
| `0x20` | `slv_reg8` | `[31:30]`=ALGO_SEL, `[29:28]`=SET_SEL, `[27]`=WAY_SEL, `[15:0]`=RUNTIME_NUM_HEAD |

### 7.2 Software Reset

`slv_reg0[4]` (`SW_RST`) điều khiển `cache_sw_rst_reg`:
```
rst_n_core = rst_n & ~cache_sw_rst_reg
```
PS có thể reset core mà không reset toàn bộ wrapper (giữ nguyên
register state).

### 7.3 AXI4-Full Master FSM (DDR ↔ PL)

**Write FSM 4 trạng thái:**
```
M_WR_IDLE → M_WR_ADDR → M_WR_DATA → M_WR_RESP → M_WR_IDLE
```

**Read FSM 3 trạng thái:**
```
M_RD_IDLE → M_RD_ADDR → M_RD_DATA → M_RD_IDLE
```

| Thông số | Giá trị |
|----------|---------|
| `DDR_BASE_ADDR` | `0x1100_0000` |
| Địa chỉ tính theo | `DDR_BASE + ({layer, head, token} << 3)` |
| Mỗi entry | 8 byte (32-bit K + 32-bit V đã BF16) |
| `AWBURST` / `ARBURST` | INCR |
| `AWCACHE` / `ARCACHE` | `4'b0011` (Normal Non-cacheable Bufferable) |
| `AWLEN` / `ARLEN` | 0 (1 beat per transaction) |
| `AWSIZE` / `ARSIZE` | `3'b011` (8 byte) |

Đường này nối với cổng `S_AXI_HP0` của PS7 → đi thẳng tới DDR
controller, không qua ARM CPU.

---

## Tài nguyên đã đo (sau Place & Route, XC7Z020-CLG400-1)

| Tài nguyên | Sử dụng | Khả dụng | Tỉ lệ |
|------------|--------:|---------:|------:|
| Slice LUT | 25.342 | 53.200 | 47,64% |
| Slice Register | 19.551 | 106.400 | 18,38% |
| Block RAM Tile | 20 | 140 | 14,29% |
| DSP48E1 | 2 | 220 | 0,91% |
| Slice | 7.308 | 13.300 | 54,95% |

## Timing đã đo (50 MHz)

| Thông số | Giá trị |
|----------|--------:|
| WNS | +1,736 ns |
| WHS | +0,033 ns |
| Data path delay (critical) | 17,954 ns (logic 35,2% + route 64,8%) |
| Logic levels critical path | 16 |
| Timing violations | 0 |
| Critical path | RAMB18 (tag) → CARRY4×6 (Fibonacci hash) → LUT chain (immune + victim) → fo=927 routing → PLRU `tree_bits_reg` |
| $f_{max}$ ước tính | ~55,5 MHz |

## Công suất đã đo

| Thành phần | Công suất |
|------------|----------:|
| Tổng | 1,562 W |
| Dynamic | 1,422 W |
| Static (rò rỉ) | 0,140 W |
| PS7 (ARM + DDR) | 1,258 W (80,5% dynamic) |
| PL Logic (LUT/FF) | 0,028 W |
| PL BRAM | 0,040 W |
| PL Clock | 0,050 W |
| PL Signals (routing) | 0,042 W |
| Junction temp | 43°C (Max Ambient 67°C) |

---

## File summary

| File | Vai trò |
|------|---------|
| `fifo_tracker.sv` | Thuật toán thay thế FIFO (1 set) |
| `random_lfsr.sv` | Thuật toán thay thế Random (1 set) |
| `plru_tree.sv` | Thuật toán Tree-PLRU (1 set) |
| `kv_delta_codec.sv` | Codec BF16 truncation 64↔32 bit |
| `kv_cache_set.sv` | Set manager (valid/dirty/algo mux) |
| `kv_cache_top.sv` | Top controller: FSM 11 states + hash + BRAM array |
| `kv_cache_axi_wrapper.sv` | AXI4-Lite slave + AXI4-Full master (HP0) |
