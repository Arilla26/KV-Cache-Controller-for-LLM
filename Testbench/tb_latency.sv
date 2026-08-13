`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 06/07/2026 06:01:03 PM
// Design Name: 
// Module Name: tb_latency
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////
//==========================================================
// tb_kv_cache_latency.sv
// Testbench đo latency lõi cache: T_hit, T_miss(clean), T_miss(dirty)
//
// Mục tiêu:
//   - Đo chính xác số chu kỳ mỗi đường (đếm từ op_valid tới resp_valid)
//   - Sinh waveform (VCD) cho 3 kịch bản để đưa vào báo cáo/slide
//   - DDR model có độ trễ cấu hình (DDR_RD_LAT, DDR_WR_LAT)
//
// Cấu hình test: BARE (PLRU, KHÔNG Locked Zone, KHÔNG Immune)
//                để khớp cấu hình tốt nhất trong báo cáo.
//
// Chạy (XSim):
//   xvlog -sv kv_delta_codec.sv plru_tree.sv fifo_tracker.sv \
//             random_lfsr.sv kv_cache_set.sv kv_cache_top.sv \
//             tb_kv_cache_latency.sv
//   xelab -debug typical tb_kv_cache_latency -s sim
//   xsim sim -runall
//
// Chạy (Verilator/Icarus tuỳ chọn) - xem cuối file.
//==========================================================

module tb_kv_cache_latency;

    // ---------------- Tham số ----------------
    localparam int NUM_SET    = 512;
    localparam int N_WAY      = 8;
    localparam int MAX_LAYER  = 32;
    localparam int MAX_HEAD   = 32;
    localparam int MAX_TOKENS = 1024;
    localparam int DK_WIDTH   = 64;
    localparam int DV_WIDTH   = 64;

    localparam int LAYER_BITS = $clog2(MAX_LAYER);
    localparam int HEAD_BITS  = $clog2(MAX_HEAD);
    localparam int TOKEN_BITS = $clog2(MAX_TOKENS);

    localparam time CLK_PERIOD = 20ns;   // 50 MHz

    // Độ trễ DDR mô phỏng (số chu kỳ). Đổi tuỳ ý để khảo sát.
    localparam int DDR_RD_LAT = 10;      // chu kỳ chờ đọc DDR
    localparam int DDR_WR_LAT = 10;      // chu kỳ chờ ghi DDR (BVALID)

    // ---------------- Tín hiệu ----------------
    logic clk, rst_n;

    // Config
    logic [1:0]  algo_sel;
    logic [15:0] runtime_num_head;
    logic [31:0] locked_sets_bound;
    logic [31:0] local_window_size;
    logic        locked_zone_enable;
    logic        immune_enable;
    logic [31:0] active_set_mask;
    logic [N_WAY-1:0] active_way_mask;

    // Request
    logic                   op_valid;
    logic                   op_ready;
    logic                   op_is_write;
    logic [LAYER_BITS-1:0]  op_layer_id;
    logic [HEAD_BITS-1:0]   op_head_id;
    logic [TOKEN_BITS-1:0]  op_token_idx;
    logic [DK_WIDTH-1:0]    op_k;
    logic [DV_WIDTH-1:0]    op_v;

    // Response
    logic                   resp_valid;
    logic                   resp_is_write;
    logic                   resp_hit;
    logic [DK_WIDTH-1:0]    resp_k;
    logic [DV_WIDTH-1:0]    resp_v;

    // DDR interface
    logic                   ddr_ready;
    logic                   ddr_wr_en;
    logic [LAYER_BITS-1:0]  ddr_wr_layer_id;
    logic [HEAD_BITS-1:0]   ddr_wr_head_id;
    logic [TOKEN_BITS-1:0]  ddr_wr_token_idx;
    logic [31:0]            ddr_wr_k, ddr_wr_v;
    logic                   ddr_rd_en;
    logic [LAYER_BITS-1:0]  ddr_rd_layer_id;
    logic [HEAD_BITS-1:0]   ddr_rd_head_id;
    logic [TOKEN_BITS-1:0]  ddr_rd_token_idx;
    logic                   ddr_rd_valid;
    logic [31:0]            ddr_rd_k, ddr_rd_v;


    // ---------------- DUT ----------------
    kv_cache_top #(
        .NUM_SET(NUM_SET), .N_WAY(N_WAY),
        .MAX_LAYER(MAX_LAYER), .MAX_HEAD(MAX_HEAD), .MAX_TOKENS(MAX_TOKENS),
        .DK_WIDTH(DK_WIDTH), .DV_WIDTH(DV_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .algo_sel(algo_sel),
        .runtime_num_head(runtime_num_head),
        .locked_sets_bound(locked_sets_bound),
        .local_window_size(local_window_size),
        .locked_zone_enable(locked_zone_enable),
        .immune_enable(immune_enable),
        .active_set_mask(active_set_mask),
        .active_way_mask(active_way_mask),
        .op_valid(op_valid), .op_ready(op_ready), .op_is_write(op_is_write),
        .op_layer_id(op_layer_id), .op_head_id(op_head_id), .op_token_idx(op_token_idx),
        .op_k(op_k), .op_v(op_v),
        .resp_valid(resp_valid), .resp_is_write(resp_is_write), .resp_hit(resp_hit),
        .resp_k(resp_k), .resp_v(resp_v),
        .ddr_ready(ddr_ready),
        .ddr_wr_en(ddr_wr_en), .ddr_wr_layer_id(ddr_wr_layer_id),
        .ddr_wr_head_id(ddr_wr_head_id), .ddr_wr_token_idx(ddr_wr_token_idx),
        .ddr_wr_k(ddr_wr_k), .ddr_wr_v(ddr_wr_v),
        .ddr_rd_en(ddr_rd_en), .ddr_rd_layer_id(ddr_rd_layer_id),
        .ddr_rd_head_id(ddr_rd_head_id), .ddr_rd_token_idx(ddr_rd_token_idx),
        .ddr_rd_valid(ddr_rd_valid), .ddr_rd_k(ddr_rd_k), .ddr_rd_v(ddr_rd_v)
    );

    // ---------------- Clock ----------------
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ==========================================================
    // DDR MODEL - độ trễ cấu hình
    //   READ : sau khi thấy ddr_rd_en & ddr_ready, chờ DDR_RD_LAT
    //          chu kỳ rồi phát ddr_rd_valid (1 cycle) + data.
    //   WRITE: sau khi thấy ddr_wr_en & ddr_ready ... thực ra
    //          ddr_ready chính là tín hiệu "DDR sẵn sàng/chấp nhận".
    //   Ở đây ta mô hình ddr_ready như "đã hoàn tất" sau N chu kỳ
    //   kể từ khi có request (giống chờ BVALID / rd handshake).
    // ==========================================================
    // Mô hình đơn giản: ddr_ready là pulse phát ra sau LAT chu kỳ
    // kể từ khi nhận request write; ddr_rd_valid tương tự cho read.
    int rd_cnt, wr_cnt;
    logic rd_pending, wr_pending;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ddr_ready    <= 1'b0;
            ddr_rd_valid <= 1'b0;
            ddr_rd_k     <= 32'h0;
            ddr_rd_v     <= 32'h0;
            rd_cnt       <= 0;
            wr_cnt       <= 0;
            rd_pending   <= 1'b0;
            wr_pending   <= 1'b0;
        end else begin
            ddr_ready    <= 1'b0;   // mặc định pulse
            ddr_rd_valid <= 1'b0;

            // ---- WRITE path: FSM ở EVICT_DDR_WAIT chờ ddr_ready ----
            if (ddr_wr_en && !wr_pending && !rd_pending) begin
                wr_pending <= 1'b1;
                wr_cnt     <= DDR_WR_LAT;
            end else if (wr_pending) begin
                if (wr_cnt <= 1) begin
                    ddr_ready  <= 1'b1;   // báo ghi xong
                    wr_pending <= 1'b0;
                end else begin
                    wr_cnt <= wr_cnt - 1;
                end
            end

            // ---- READ path: FSM ở RD_REQ chờ ddr_ready, RD_WAIT chờ ddr_rd_valid ----
            // RD_REQ cần ddr_ready để sang RD_WAIT; rồi RD_WAIT cần ddr_rd_valid.
            if (ddr_rd_en && !rd_pending && !wr_pending) begin
                // chấp nhận request đọc ngay (ddr_ready) ...
                ddr_ready  <= 1'b1;
                rd_pending <= 1'b1;
                rd_cnt     <= DDR_RD_LAT;
            end else if (rd_pending) begin
                if (rd_cnt <= 1) begin
                    ddr_rd_valid <= 1'b1;          // data về
                    ddr_rd_k     <= 32'hBF16_0AA0;  // BF16-pattern giả
                    ddr_rd_v     <= 32'hBF16_0BB0;
                    rd_pending   <= 1'b0;
                end else begin
                    rd_cnt <= rd_cnt - 1;
                end
            end
        end
    end

    // ==========================================================
    // Đo latency: đếm chu kỳ từ op_valid (được nhận) tới resp_valid
    // ==========================================================
    int    cyc_counter;
    int    launch_cyc;
    logic  measuring;
    string cur_label;

    // bộ đếm chu kỳ toàn cục
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cyc_counter <= 0;
        else        cyc_counter <= cyc_counter + 1;
    end

    // ---------------- Task: phát 1 op và đo ----------------
    task automatic do_op(
        input string             label,
        input logic              is_write,
        input [LAYER_BITS-1:0]   layer,
        input [HEAD_BITS-1:0]    head,
        input [TOKEN_BITS-1:0]   token,
        input [DK_WIDTH-1:0]     kdata,
        input [DV_WIDTH-1:0]     vdata
    );
        int t_start, t_end;
        // chờ op_ready (DUT ở IDLE)
        @(posedge clk);
        while (!op_ready) @(posedge clk);

        // phát op
        op_valid     <= 1'b1;
        op_is_write  <= is_write;
        op_layer_id  <= layer;
        op_head_id   <= head;
        op_token_idx <= token;
        op_k         <= kdata;
        op_v         <= vdata;
        t_start = cyc_counter;
        @(posedge clk);
        op_valid <= 1'b0;   // 1-cycle pulse

        // chờ resp_valid
        while (!resp_valid) @(posedge clk);
        t_end = cyc_counter;

        $display("[%0t] %-18s : %0d chu ky (resp_hit=%0b, is_write=%0b)",
                  $time, label, (t_end - t_start), resp_hit, resp_is_write);
        @(posedge clk);
    endtask

    // ==========================================================
    // KỊCH BẢN TEST
    // ==========================================================
    initial begin
        // VCD cho waveform
        $dumpfile("kv_cache_latency.vcd");
        $dumpvars(0, tb_kv_cache_latency);

        // --- Config BARE: PLRU, không Locked, không Immune ---
        algo_sel           = 2'd0;          // 0 = PLRU (giả định; chỉnh nếu encoding khác)
        runtime_num_head   = 16'd2;
        locked_sets_bound  = 32'd0;
        local_window_size  = 32'd0;
        locked_zone_enable = 1'b0;
        immune_enable      = 1'b0;
        active_set_mask    = 32'h1FF;        // 512 set (9 bit) đều active
        active_way_mask    = '1;             // 8 way đều active

        op_valid = 0; op_is_write = 0;
        op_layer_id = 0; op_head_id = 0; op_token_idx = 0; op_k = 0; op_v = 0;

        // Reset
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (3) @(posedge clk);

        $display("=================================================");
        $display(" ĐO LATENCY LÕI CACHE - DDR_RD_LAT=%0d, DDR_WR_LAT=%0d", DDR_RD_LAT, DDR_WR_LAT);
        $display("=================================================");

        // ----------------------------------------------------------
        // (1) MISS-CLEAN: đọc 1 token chưa có, set trống → miss, victim sạch
        //     (layer=1, head=0, token=5) - chưa từng ghi
        // ----------------------------------------------------------
        do_op("MISS-CLEAN (read)", 1'b0, 1, 0, 5, 64'h0, 64'h0);

        // ----------------------------------------------------------
        // (2) HIT: ghi 1 token rồi đọc lại CHÍNH token đó → hit
        //     Ghi (write) token (2,0,7) trước để nạp vào cache.
        //     Sau đó đọc lại (2,0,7) → hit.
        // ----------------------------------------------------------
        do_op("WRITE (fill)",      1'b1, 2, 0, 7, 64'hAAAA_BBBB_CCCC_DDDD, 64'h1111_2222_3333_4444);
        do_op("HIT (read)",        1'b0, 2, 0, 7, 64'h0, 64'h0);

        // ----------------------------------------------------------
        // (3) MISS-DIRTY: dùng 9 tổ hợp (layer,head,token) ĐỒNG SET (set 0)
        //     tính sẵn bằng Fibonacci hash. Ghi 8 cái đầu (đầy 8 way, đều
        //     dirty), rồi ĐỌC cái thứ 9 cùng set → buộc evict 1 way DIRTY.
        //     Đây là đường miss-dirty thật: EVICT (ghi DDR) → RD (đọc DDR).
        // ----------------------------------------------------------
        // 8 way fill (đều WRITE → dirty), cùng set 0:
        do_op("DIRTY fill w0", 1'b1, 0, 0,   0, 64'hD0, 64'hE0);
        do_op("DIRTY fill w1", 1'b1, 0, 0, 233, 64'hD1, 64'hE1);
        do_op("DIRTY fill w2", 1'b1, 0, 0, 610, 64'hD2, 64'hE2);
        do_op("DIRTY fill w3", 1'b1, 0, 1, 196, 64'hD3, 64'hE3);
        do_op("DIRTY fill w4", 1'b1, 0, 1, 573, 64'hD4, 64'hE4);
        do_op("DIRTY fill w5", 1'b1, 0, 2, 159, 64'hD5, 64'hE5);
        do_op("DIRTY fill w6", 1'b1, 0, 2, 769, 64'hD6, 64'hE6);
        do_op("DIRTY fill w7", 1'b1, 0, 3, 122, 64'hD7, 64'hE7);
        // token thứ 9 cùng set → set đã đầy 8 way dirty → evict 1 way dirty:
        do_op("MISS-DIRTY (read)", 1'b0, 0, 3, 732, 64'h0, 64'h0);

        repeat (10) @(posedge clk);
        $display("=================================================");
        $display(" HOAN TAT. Mo kv_cache_latency.vcd de xem waveform.");
        $display(" Doi chieu: T_hit ~3cy, T_miss_clean ~5cy+DDR, T_miss_dirty ~8cy+2*DDR");
        $display("=================================================");
        $finish;
    end

    // Timeout an toàn
    initial begin
        #(CLK_PERIOD * 5000);
        $display("ERROR: TIMEOUT");
        $finish;
    end

endmodule

//==========================================================
// GHI CHÚ:
//
// 1. algo_sel encoding: TB giả định 0 = PLRU. Nếu RTL dùng encoding
//    khác (xem kv_cache_set / plru_tree), chỉnh lại algo_sel.
//
// 2. MISS-DIRTY: cách trên ghi 16 write rồi đọc token mới. Nếu muốn
//    ÉP CHÍNH XÁC victim dirty trong 1 set, cần tính các token cùng set:
//    set = Fibonacci_hash({layer,head,token}) & active_set_mask.
//    Ghi đủ N_WAY (=8) token cùng set (đều write → dirty), rồi đọc
//    token thứ 9 cùng set → chắc chắn evict 1 way dirty.
//    Có thể thêm hàm tính token đồng-set nếu cần độ chắc chắn 100%.
//
// 3. Đếm cycle: do_op đo từ chu kỳ phát op_valid (được nhận, op_ready=1)
//    tới chu kỳ resp_valid=1. KHÔNG tính chu kỳ IDLE chờ trước đó.
//    Khớp quy ước báo cáo: T_hit = 3, T_miss_clean = 5+D, T_miss_dirty = 8+2D.
//
// 4. Đổi DDR_RD_LAT / DDR_WR_LAT ở localparam để khảo sát ảnh hưởng
//    độ trễ DDR. Phần phần cứng (3/5/8 cy) KHÔNG đổi; chỉ phần +DDR đổi.
//==========================================================