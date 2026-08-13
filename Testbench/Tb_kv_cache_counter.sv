`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05/25/2026 07:06:04 AM
// Design Name: 
// Module Name: Tb_kv_cache_counter
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
// ============================================================================
// tb_kv_cache_counter.sv - Testbench cho HW Counter trong kv_cache_top
//
// MỤC ĐÍCH:
//   - Instantiate REAL kv_cache_top.sv (không phải copy logic vào tb)
//   - Drive request signals + mock DDR
//   - Verify counter outputs (dbg_hit_op_cnt, dbg_miss_op_cnt, ...)
//
// CHIẾN LƯỢC:
//   - Bypass AXI wrapper, drive trực tiếp op_valid/op_is_write/... vào core
//   - Mock DDR slave: trả lời ddr_ready ngay, ddr_rd_valid sau N cycle
//   - Đọc 5 counter outputs trực tiếp (không qua AXI)
//
// CHẠY:
//   Vivado: Add tb_kv_cache_counter.sv as simulation top
//           Run Behavioral Simulation
//
// EXPECTED OUTPUT:
//   [TEST 1] 3 HIT ops          → hit_op=3, miss_op=0
//   [TEST 2] 2 MISS ops         → miss_op=2, miss_cyc >> hit_cyc/op
//   [TEST 3] Mixed workload     → đếm chính xác từng loại
//   [TEST 4] dbg_clear pulse    → counters về 0
//   [TEST 5] Gap MISS/HIT > 5x  → DDR chậm hơn BRAM rõ rệt
// ============================================================================

module tb_kv_cache_counter;

    // ────────────────────────────────────────────────────────────────────
    // Parameters
    // ────────────────────────────────────────────────────────────────────
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

    // ────────────────────────────────────────────────────────────────────
    // DUT signals
    // ────────────────────────────────────────────────────────────────────
    logic clk;
    logic rst_n;

    // Config (cấu hình mặc định cho test: PLRU, no special features)
    logic [1:0]  algo_sel          = 2'b00;   // PLRU
    logic [15:0] runtime_num_head  = 16'd2;
    logic [31:0] locked_sets_bound = 32'd0;
    logic [31:0] local_window_size = 32'd0;
    logic        locked_zone_enable = 1'b0;
    logic        immune_enable      = 1'b0;
    logic [31:0] active_set_mask   = 32'h0000_01FF;  // 512 sets
    logic [N_WAY-1:0] active_way_mask = 8'hFF;       // all 8 ways

    // Request interface
    logic                          op_valid;
    logic                          op_ready;
    logic                          op_is_write;
    logic [LAYER_BITS-1:0]         op_layer_id;
    logic [HEAD_BITS-1:0]          op_head_id;
    logic [TOKEN_BITS-1:0]         op_token_idx;
    logic [DK_WIDTH-1:0]           op_k;
    logic [DV_WIDTH-1:0]           op_v;

    // Response
    logic                          resp_valid;
    logic                          resp_is_write;
    logic                          resp_hit;
    logic [DK_WIDTH-1:0]           resp_k;
    logic [DV_WIDTH-1:0]           resp_v;

    // DDR interface (mocked)
    logic                          ddr_ready;
    logic                          ddr_wr_en;
    logic [LAYER_BITS-1:0]         ddr_wr_layer_id;
    logic [HEAD_BITS-1:0]          ddr_wr_head_id;
    logic [TOKEN_BITS-1:0]         ddr_wr_token_idx;
    logic [31:0]                   ddr_wr_k;
    logic [31:0]                   ddr_wr_v;
    logic                          ddr_rd_en;
    logic [LAYER_BITS-1:0]         ddr_rd_layer_id;
    logic [HEAD_BITS-1:0]          ddr_rd_head_id;
    logic [TOKEN_BITS-1:0]         ddr_rd_token_idx;
    logic                          ddr_rd_valid;
    logic [31:0]                   ddr_rd_k;
    logic [31:0]                   ddr_rd_v;

    // HW Counters (đầu ra cần verify)
    logic        dbg_clear;
    logic [31:0] dbg_hit_op_cnt;
    logic [31:0] dbg_miss_op_cnt;
    logic [31:0] dbg_hit_cyc_cnt;
    logic [31:0] dbg_miss_cyc_cnt;
    logic [31:0] dbg_total_cyc_cnt;

    // ────────────────────────────────────────────────────────────────────
    // DUT INSTANTIATION - REAL kv_cache_top.sv
    // ────────────────────────────────────────────────────────────────────
    kv_cache_top #(
        .NUM_SET(NUM_SET),
        .N_WAY(N_WAY),
        .MAX_LAYER(MAX_LAYER),
        .MAX_HEAD(MAX_HEAD),
        .MAX_TOKENS(MAX_TOKENS),
        .DK_WIDTH(DK_WIDTH),
        .DV_WIDTH(DV_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .algo_sel(algo_sel), .runtime_num_head(runtime_num_head),
        .locked_sets_bound(locked_sets_bound),
        .local_window_size(local_window_size),
        .locked_zone_enable(locked_zone_enable),
        .immune_enable(immune_enable),
        .active_set_mask(active_set_mask),
        .active_way_mask(active_way_mask),

        .op_valid(op_valid), .op_ready(op_ready),
        .op_is_write(op_is_write),
        .op_layer_id(op_layer_id), .op_head_id(op_head_id),
        .op_token_idx(op_token_idx),
        .op_k(op_k), .op_v(op_v),

        .resp_valid(resp_valid), .resp_is_write(resp_is_write),
        .resp_hit(resp_hit),
        .resp_k(resp_k), .resp_v(resp_v),

        .ddr_ready(ddr_ready),
        .ddr_wr_en(ddr_wr_en),
        .ddr_wr_layer_id(ddr_wr_layer_id),
        .ddr_wr_head_id(ddr_wr_head_id),
        .ddr_wr_token_idx(ddr_wr_token_idx),
        .ddr_wr_k(ddr_wr_k), .ddr_wr_v(ddr_wr_v),
        .ddr_rd_en(ddr_rd_en),
        .ddr_rd_layer_id(ddr_rd_layer_id),
        .ddr_rd_head_id(ddr_rd_head_id),
        .ddr_rd_token_idx(ddr_rd_token_idx),
        .ddr_rd_valid(ddr_rd_valid),
        .ddr_rd_k(ddr_rd_k), .ddr_rd_v(ddr_rd_v),

        // ─── COUNTER OUTPUTS (cái cần test) ───
        .dbg_clear(dbg_clear),
        .dbg_hit_op_cnt(dbg_hit_op_cnt),
        .dbg_miss_op_cnt(dbg_miss_op_cnt),
        .dbg_hit_cyc_cnt(dbg_hit_cyc_cnt),
        .dbg_miss_cyc_cnt(dbg_miss_cyc_cnt),
        .dbg_total_cyc_cnt(dbg_total_cyc_cnt)
    );

    // ────────────────────────────────────────────────────────────────────
    // MOCK DDR - luôn trả lời ngay (zero latency để test pure FSM)
    //   - ddr_ready = 1 ngay khi có req
    //   - ddr_rd_valid trễ 5 cycle để mô phỏng DDR access
    //   - Trả về dữ liệu cố định 0xDEADBEEF
    // ────────────────────────────────────────────────────────────────────
    assign ddr_ready = 1'b1;

    logic [3:0] ddr_rd_delay_cnt;
    logic       ddr_rd_pending;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ddr_rd_valid     <= 1'b0;
            ddr_rd_delay_cnt <= '0;
            ddr_rd_pending   <= 1'b0;
            ddr_rd_k         <= 32'hDEADBEEF;
            ddr_rd_v         <= 32'hCAFEBABE;
        end else begin
            ddr_rd_valid <= 1'b0;  // default

            if (ddr_rd_en && !ddr_rd_pending) begin
                ddr_rd_pending   <= 1'b1;
                ddr_rd_delay_cnt <= 4'd5;  // 5-cycle DDR latency
            end else if (ddr_rd_pending) begin
                if (ddr_rd_delay_cnt > 0) begin
                    ddr_rd_delay_cnt <= ddr_rd_delay_cnt - 1;
                end else begin
                    ddr_rd_valid   <= 1'b1;
                    ddr_rd_pending <= 1'b0;
                end
            end
        end
    end

    // ────────────────────────────────────────────────────────────────────
    // Clock - 10 ns period (100 MHz simulation, FSM behavior identical)
    // ────────────────────────────────────────────────────────────────────
    always #5 clk = ~clk;

    // ────────────────────────────────────────────────────────────────────
    // Helper: issue 1 op (write or read) and wait until resp_valid
    // ────────────────────────────────────────────────────────────────────
    task automatic do_op(
        input bit                  is_write,
        input [LAYER_BITS-1:0]     layer,
        input [HEAD_BITS-1:0]      head,
        input [TOKEN_BITS-1:0]     token,
        input [DK_WIDTH-1:0]       k,
        input [DV_WIDTH-1:0]       v,
        output bit                 hit_out
    );
        int timeout_cycles;

        // Wait for core to be ready
        wait (op_ready === 1'b1);
        @(posedge clk);

        // Assert request
        op_valid     <= 1'b1;
        op_is_write  <= is_write;
        op_layer_id  <= layer;
        op_head_id   <= head;
        op_token_idx <= token;
        op_k         <= k;
        op_v         <= v;

        @(posedge clk);
        op_valid <= 1'b0;

        // Wait for response with timeout
        timeout_cycles = 200;
        while (!resp_valid && timeout_cycles > 0) begin
            @(posedge clk);
            timeout_cycles--;
        end

        if (timeout_cycles == 0) begin
            $display("  [TIMEOUT] resp_valid never asserted!");
            hit_out = 1'b0;
        end else begin
            hit_out = resp_hit;
        end

        @(posedge clk);
    endtask

    // ────────────────────────────────────────────────────────────────────
    // Helper: pulse dbg_clear for 1 cycle
    // ────────────────────────────────────────────────────────────────────
    task automatic clear_counters();
        @(posedge clk);
        dbg_clear <= 1'b1;
        @(posedge clk);
        dbg_clear <= 1'b0;
        @(posedge clk);
    endtask

    // ────────────────────────────────────────────────────────────────────
    // Snapshot counter values
    // ────────────────────────────────────────────────────────────────────
    task automatic snapshot(
        output [31:0] hit_op,
        output [31:0] miss_op,
        output [31:0] hit_cyc,
        output [31:0] miss_cyc,
        output [31:0] total_cyc
    );
        hit_op    = dbg_hit_op_cnt;
        miss_op   = dbg_miss_op_cnt;
        hit_cyc   = dbg_hit_cyc_cnt;
        miss_cyc  = dbg_miss_cyc_cnt;
        total_cyc = dbg_total_cyc_cnt;
    endtask

    // ────────────────────────────────────────────────────────────────────
    // Test counters (PASS/FAIL counters)
    // ────────────────────────────────────────────────────────────────────
    int tests_passed = 0;
    int tests_failed = 0;

    task automatic check(input string name, input bit cond);
        if (cond) begin
            $display("  PASS: %s", name);
            tests_passed++;
        end else begin
            $display("  FAIL: %s", name);
            tests_failed++;
        end
    endtask

    // ────────────────────────────────────────────────────────────────────
    // MAIN TEST SEQUENCE
    // ────────────────────────────────────────────────────────────────────
    logic [31:0] h_op, m_op, h_cyc, m_cyc, t_cyc;
    logic [31:0] h_op_2, m_op_2, h_cyc_2, m_cyc_2;
    bit hit_result;

    initial begin
        // Init signals
        clk          = 1'b0;
        rst_n        = 1'b0;
        op_valid     = 1'b0;
        op_is_write  = 1'b0;
        op_layer_id  = '0;
        op_head_id   = '0;
        op_token_idx = '0;
        op_k         = '0;
        op_v         = '0;
        dbg_clear    = 1'b0;

        // Reset
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        $display("====================================================");
        $display(" HW Counter Verification - Real kv_cache_top DUT");
        $display("====================================================");

        // ────────────────────────────────────────────────────────────
        // TEST 1: 3 WRITE ops - WRITES KHÔNG được đếm vào counter
        //   (Counter chỉ tính READ ops, đảm bảo nhất quán với Hit Rate)
        // ────────────────────────────────────────────────────────────
        $display("\n[TEST 1] WRITE ops should NOT increment counter (read-only counter)");
        clear_counters();
        snapshot(h_op, m_op, h_cyc, m_cyc, t_cyc);
        $display("  Initial: hit_op=%0d miss_op=%0d hit_cyc=%0d miss_cyc=%0d",
                 h_op, m_op, h_cyc, m_cyc);
        check("Initial counters all zero",
              (h_op == 0) && (m_op == 0) && (h_cyc == 0) && (m_cyc == 0));

        // 3 writes vào 3 token khác nhau (để fill cache cho TEST 2)
        do_op(1'b1, 0, 0, 10'd10, 64'hAAAA_AAAA_1111_1111, 64'hBBBB_BBBB_2222_2222, hit_result);
        do_op(1'b1, 0, 0, 10'd20, 64'hCCCC_CCCC_3333_3333, 64'hDDDD_DDDD_4444_4444, hit_result);
        do_op(1'b1, 0, 0, 10'd30, 64'hEEEE_EEEE_5555_5555, 64'hFFFF_FFFF_6666_6666, hit_result);

        snapshot(h_op, m_op, h_cyc, m_cyc, t_cyc);
        $display("  After 3 WRITES: hit_op=%0d miss_op=%0d hit_cyc=%0d miss_cyc=%0d total=%0d",
                 h_op, m_op, h_cyc, m_cyc, t_cyc);
        // Counter chỉ đếm READ - WRITES không được tính vào hit/miss
        check("WRITE ops NOT counted in hit_op (read-only counter)", h_op == 0);
        check("WRITE ops NOT counted in miss_op (read-only counter)", m_op == 0);
        check("hit_cyc unchanged after WRITES", h_cyc == 0);
        check("miss_cyc unchanged after WRITES", m_cyc == 0);
        // total_cyc VẪN tăng (đếm mọi cycle non-IDLE, kể cả writes)
        check("total_cyc > 0 (writes still consume cycles)", t_cyc > 0);

        // ────────────────────────────────────────────────────────────
        // TEST 2: 3 READ ops vào cùng các key đã write → HIT
        // ────────────────────────────────────────────────────────────
        $display("\n[TEST 2] READ same keys → expect HIT");
        clear_counters();

        do_op(1'b0, 0, 0, 10'd10, 64'h0, 64'h0, hit_result);
        $display("  Read token=10: hit=%0b", hit_result);
        do_op(1'b0, 0, 0, 10'd20, 64'h0, 64'h0, hit_result);
        $display("  Read token=20: hit=%0b", hit_result);
        do_op(1'b0, 0, 0, 10'd30, 64'h0, 64'h0, hit_result);
        $display("  Read token=30: hit=%0b", hit_result);

        snapshot(h_op, m_op, h_cyc, m_cyc, t_cyc);
        $display("  After 3 READs: hit_op=%0d miss_op=%0d hit_cyc=%0d miss_cyc=%0d",
                 h_op, m_op, h_cyc, m_cyc);
        check("3 reads → 3 HITs (hit_op == 3)", h_op == 3);
        check("No MISSes for read-after-write", m_op == 0);
        check("hit_cyc > 0", h_cyc > 0);

        // T_HIT avg = hit_cyc / hit_op (cycle/op)
        if (h_op > 0) begin
            $display("  T_HIT pure (avg cycle/op): %0d", h_cyc / h_op);
            check("T_HIT < 20 cycles (BRAM speed)", (h_cyc / h_op) < 20);
        end

        // ────────────────────────────────────────────────────────────
        // TEST 3: READ token chưa tồn tại → MISS (refill from DDR)
        // ────────────────────────────────────────────────────────────
        $display("\n[TEST 3] READ unknown keys → expect MISS");
        clear_counters();

        do_op(1'b0, 0, 0, 10'd100, 64'h0, 64'h0, hit_result);
        $display("  Read token=100: hit=%0b", hit_result);
        do_op(1'b0, 0, 0, 10'd200, 64'h0, 64'h0, hit_result);
        $display("  Read token=200: hit=%0b", hit_result);

        snapshot(h_op, m_op, h_cyc, m_cyc, t_cyc);
        $display("  After 2 unknown READs: hit_op=%0d miss_op=%0d miss_cyc=%0d",
                 h_op, m_op, m_cyc);
        check("2 reads → 2 MISSes (miss_op == 2)", m_op == 2);

        if (m_op > 0) begin
            $display("  T_MISS pure (avg cycle/op): %0d", m_cyc / m_op);
            check("T_MISS > 5 cycles (DDR latency)", (m_cyc / m_op) > 5);
        end

        // ────────────────────────────────────────────────────────────
        // TEST 4: dbg_clear pulse → counters về 0
        // ────────────────────────────────────────────────────────────
        $display("\n[TEST 4] dbg_clear pulse resets all counters");
        // Counters đang có giá trị từ TEST 3
        snapshot(h_op, m_op, h_cyc, m_cyc, t_cyc);
        $display("  Before clear: hit_op=%0d miss_op=%0d", h_op, m_op);

        clear_counters();

        snapshot(h_op, m_op, h_cyc, m_cyc, t_cyc);
        $display("  After clear:  hit_op=%0d miss_op=%0d hit_cyc=%0d miss_cyc=%0d total=%0d",
                 h_op, m_op, h_cyc, m_cyc, t_cyc);
        check("All counters cleared",
              (h_op == 0) && (m_op == 0) &&
              (h_cyc == 0) && (m_cyc == 0) && (t_cyc == 0));

        // ────────────────────────────────────────────────────────────
        // TEST 5: Mixed READ + WRITE - chỉ READs được đếm
        //   Insight: với 5 READs (4 HIT + 1 MISS) xen kẽ 3 WRITEs,
        //            counter chỉ ghi 5 reads, không nhiễm bởi writes.
        // ────────────────────────────────────────────────────────────
        $display("\n[TEST 5] Mixed READ+WRITE - writes must NOT contaminate counter");
        clear_counters();

        // Sequence: R R W R R W R W R
        //          (R hit, R hit, write, R hit, R hit, write, R miss, write, R miss)
        // → 5 reads = 4 HIT + 2 MISS (nếu tokens 10/20 trong cache, 800/900 không)
        do_op(1'b0, 0, 0, 10'd10, 64'h0, 64'h0, hit_result);  // R hit
        do_op(1'b0, 0, 0, 10'd20, 64'h0, 64'h0, hit_result);  // R hit
        do_op(1'b1, 0, 0, 10'd55, 64'h1, 64'h2, hit_result);  // W (ignore)
        do_op(1'b0, 0, 0, 10'd10, 64'h0, 64'h0, hit_result);  // R hit
        do_op(1'b0, 0, 0, 10'd20, 64'h0, 64'h0, hit_result);  // R hit
        do_op(1'b1, 0, 0, 10'd66, 64'h3, 64'h4, hit_result);  // W (ignore)
        do_op(1'b0, 0, 0, 10'd800, 64'h0, 64'h0, hit_result); // R miss
        do_op(1'b1, 0, 0, 10'd77, 64'h5, 64'h6, hit_result);  // W (ignore)
        do_op(1'b0, 0, 0, 10'd900, 64'h0, 64'h0, hit_result); // R miss

        snapshot(h_op, m_op, h_cyc, m_cyc, t_cyc);
        $display("  Sequence: 9 ops (3 WRITES interleaved with 6 READS)");
        $display("  Counter: hit_op=%0d miss_op=%0d (expect 4 HIT + 2 MISS = 6 READs only)",
                 h_op, m_op);
        $display("           hit_cyc=%0d → avg=%0d cycle/op", h_cyc, (h_op>0) ? h_cyc/h_op : 0);
        $display("           miss_cyc=%0d → avg=%0d cycle/op", m_cyc, (m_op>0) ? m_cyc/m_op : 0);

        check("Counter = 6 READ ops only (3 WRITEs excluded)", (h_op + m_op) == 6);
        check("4 HIT + 2 MISS expected (tokens 10/20 in cache, 800/900 not)",
              (h_op == 4) && (m_op == 2));

        if (h_op > 0 && m_op > 0) begin
            int t_hit_avg, t_miss_avg, gap_x10;
            t_hit_avg  = h_cyc / h_op;
            t_miss_avg = m_cyc / m_op;
            gap_x10    = (t_hit_avg > 0) ? (t_miss_avg * 10) / t_hit_avg : 0;
            $display("  Gap MISS/HIT = %0d.%0dx", gap_x10/10, gap_x10%10);
            check("Gap > 1.5x (MISS slower than HIT)", gap_x10 > 15);
        end

        // ────────────────────────────────────────────────────────────
        // SUMMARY
        // ────────────────────────────────────────────────────────────
        $display("\n====================================================");
        $display(" RESULTS: %0d PASSED, %0d FAILED", tests_passed, tests_failed);
        $display("====================================================");

        if (tests_failed == 0)
            $display(" ALL TESTS PASSED - Counter logic OK, safe to re-synthesize.");
        else
            $display(" SOME TESTS FAILED - DO NOT re-synthesize. Debug logic first.");

        $finish;
    end

    // Safety timeout - testbench tự kill nếu chạy quá lâu
    initial begin
        #50000;
        $display("[FATAL] Testbench timeout - DUT may be stuck");
        $finish;
    end

endmodule