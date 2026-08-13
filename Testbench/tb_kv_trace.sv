`timescale 1ns / 1ps 
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/09/2026 10:31:47 AM
// Design Name: 
// Module Name: tb_kv_trace
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

module tb_kv_trace();

    // Khai bao hang so
    localparam int C_S_AXI_ADDR_WIDTH = 6;
    localparam int C_S_AXI_DATA_WIDTH = 32;
    localparam int C_M_AXI_ADDR_WIDTH = 32;
    localparam int C_M_AXI_DATA_WIDTH = 64;

    // Tin hieu Clock va Reset
    logic clk;
    logic rst_n;

    // Tin hieu AXI-Lite (CPU Host)
    logic [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr;
    logic                          s_axi_awvalid;
    logic                          s_axi_awready;
    logic [C_S_AXI_DATA_WIDTH-1:0] s_axi_wdata;
    logic                          s_axi_wvalid;
    logic                          s_axi_wready;
    logic [1:0]                    s_axi_bresp;
    logic                          s_axi_bvalid;
    logic                          s_axi_bready;
    logic [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr;
    logic                          s_axi_arvalid;
    logic                          s_axi_arready;
    logic [C_S_AXI_DATA_WIDTH-1:0] s_axi_rdata;
    logic [1:0]                    s_axi_rresp;
    logic                          s_axi_rvalid;
    logic                          s_axi_rready;

    // Tin hieu AXI-Full (Giao tiep DDR)
    logic [C_M_AXI_ADDR_WIDTH-1:0] m_axi_awaddr;
    logic [7:0]                    m_axi_awlen;
    logic [2:0]                    m_axi_awsize;
    logic                          m_axi_awvalid;
    logic                          m_axi_awready;
    logic [C_M_AXI_DATA_WIDTH-1:0] m_axi_wdata;
    logic                          m_axi_wlast;
    logic                          m_axi_wvalid;
    logic                          m_axi_wready;
    logic [1:0]                    m_axi_bresp;
    logic                          m_axi_bvalid;
    logic                          m_axi_bready;
    logic [C_M_AXI_ADDR_WIDTH-1:0] m_axi_araddr;
    logic [7:0]                    m_axi_arlen;
    logic [2:0]                    m_axi_arsize;
    logic                          m_axi_arvalid;
    logic                          m_axi_arready;
    logic [C_M_AXI_DATA_WIDTH-1:0] m_axi_rdata;
    logic                          m_axi_rlast;
    logic                          m_axi_rvalid;
    logic                          m_axi_rready;

    // Tin hieu giao tiep Token (Ket noi qua AXI-Lite phia trong)
    logic op_ready; // Tin hieu phan hoi tu DUT

    // Bien dung cho doc file Trace
    integer fd, scan_file;
    int tr_layer, tr_head, tr_token;
    logic [63:0] tr_k, tr_v;
    logic [15:0] packed_addr;

    // Tao Clock 100MHz (Chu ky 10ns)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // =========================================================
    // KHOI INSTANTIATE DUT (kv_cache_axi_wrapper)
    // =========================================================
    kv_cache_axi_wrapper #(
        .C_S_AXI_ADDR_WIDTH(C_S_AXI_ADDR_WIDTH),
        .C_S_AXI_DATA_WIDTH(C_S_AXI_DATA_WIDTH),
        .C_M_AXI_ADDR_WIDTH(C_M_AXI_ADDR_WIDTH),
        .C_M_AXI_DATA_WIDTH(C_M_AXI_DATA_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );

    // Trich xuat tin hieu op_ready tu ben trong DUT de dong bo Testbench
    assign op_ready = dut.op_ready;

    // =========================================================
    // KHOI BFM GIẢ LẬP DDR (AXI-FULL SLAVE MOCK)
    // =========================================================
    logic aw_received = 0;
    logic w_received  = 0;
    int   write_delay_cnt  = 0;
    logic write_processing = 0;
    int   read_delay_cnt   = 0;
    logic read_processing  = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            m_axi_awready    <= 1'b0;
            m_axi_wready     <= 1'b0;
            m_axi_bvalid     <= 1'b0;
            m_axi_arready    <= 1'b0;
            m_axi_rvalid     <= 1'b0;
            aw_received      <= 1'b0;
            w_received       <= 1'b0;
            write_processing <= 1'b0;
            read_processing  <= 1'b0;
        end else begin
            
            // KÊNH GHI
            if (!aw_received && !write_processing && !m_axi_bvalid) begin
                m_axi_awready <= 1'b1;
                if (m_axi_awvalid && m_axi_awready) begin
                    m_axi_awready <= 1'b0;
                    aw_received   <= 1'b1;
                end
            end

            if (!w_received && !write_processing && !m_axi_bvalid) begin
                m_axi_wready <= 1'b1;
                if (m_axi_wvalid && m_axi_wready) begin
                    if (m_axi_wlast) begin 
                        m_axi_wready <= 1'b0;
                        w_received   <= 1'b1;
                    end
                end
            end

            if (aw_received && w_received && !write_processing) begin
                write_processing <= 1'b1;
                write_delay_cnt  <= 25; 
                aw_received      <= 1'b0; 
                w_received       <= 1'b0;
            end

            if (write_processing) begin
                if (write_delay_cnt > 0) begin
                    write_delay_cnt <= write_delay_cnt - 1;
                end else begin
                    m_axi_bvalid     <= 1'b1; 
                    write_processing <= 1'b0;
                end
            end

            if (m_axi_bvalid && m_axi_bready) begin
                m_axi_bvalid <= 1'b0; 
            end

            // KÊNH ĐỌC
            if (!read_processing && !m_axi_rvalid) begin
                m_axi_arready <= 1'b1;
                if (m_axi_arvalid && m_axi_arready) begin
                    m_axi_arready   <= 1'b0;
                    read_processing <= 1'b1;
                    read_delay_cnt  <= 30; 
                end
            end

            if (read_processing) begin
                if (read_delay_cnt > 0) begin
                    read_delay_cnt <= read_delay_cnt - 1;
                end else begin
                    m_axi_rvalid    <= 1'b1; 
                    m_axi_rdata     <= 64'h00000000_084210FF;
                    m_axi_rlast     <= 1'b1; 
                    read_processing <= 1'b0;
                end
            end

            if (m_axi_rvalid && m_axi_rready) begin
                m_axi_rvalid <= 1'b0;
                m_axi_rlast  <= 1'b0;
            end
        end
    end

    // =========================================================
    // TASK GIAO TIẾP AXI-LITE
    // =========================================================
    task write_reg(input logic [C_S_AXI_ADDR_WIDTH-1:0] addr, input logic [31:0] data);
        begin
            @(posedge clk);
            s_axi_awaddr  <= addr;
            s_axi_awvalid <= 1'b1;
            s_axi_wdata   <= data;
            s_axi_wvalid  <= 1'b1;
            
            wait(s_axi_awready && s_axi_wready);
            @(posedge clk);
            s_axi_awvalid <= 1'b0;
            s_axi_wvalid  <= 1'b0;
            s_axi_bready  <= 1'b1;
            
            wait(s_axi_bvalid);
            @(posedge clk);
            s_axi_bready  <= 1'b0;
        end
    endtask

    task send_token_req(
        input logic is_write, 
        input logic [15:0] addr, 
        input logic [31:0] token, 
        input logic [63:0] k_data, 
        input logic [63:0] v_data
    );
        begin
            // 1. Ghi Layer & Head (Address) vao slv_reg1 (6'h04)
            write_reg(6'h04, {16'h0000, addr});
            
            // 2. Ghi Token ID vao slv_reg2 (6'h08)
            write_reg(6'h08, token);
            
            // 3. Ghi 32-bit thap cua K vao slv_reg3 (6'h0C)
            write_reg(6'h0C, k_data[31:0]);
            
            // 4. Ghi 32-bit cao cua K vao slv_reg4 (6'h10)
            write_reg(6'h10, k_data[63:32]);
            
            // 5. Ghi 32-bit thap cua V vao slv_reg5 (6'h14)
            write_reg(6'h14, v_data[31:0]);
            
            // 6. Ghi 32-bit cao cua V vao slv_reg6 (6'h18)
            write_reg(6'h18, v_data[63:32]);
            
            // 7. Kich hoat op_valid (bit 0) va op_is_write (bit 1) trong slv_reg0 (6'h00)
            write_reg(6'h00, {30'h0, is_write, 1'b1});
        end
    endtask

    // =========================================================
    // MAIN TRACE-DRIVEN TEST
    // =========================================================
    // Khai bao cac bien cau hinh cho FSM
    logic [1:0]  cfg_algo_sel;
    logic        cfg_locked_en;
    logic        cfg_immune_en;
    logic [7:0]  cfg_bounder;
    logic [7:0]  cfg_window_size;
    logic [15:0] cfg_runtime_num_head;

    // Bien chua du lieu sau khi tong hop
    logic [31:0] reg7_data;
    logic [31:0] reg8_data;
    
    // Cac bien ho trơ
    int total_cmds = 0;
    int fail_cnt = 0;
    int current_latency = 0;
    int hit_cnt = 0;
    int miss_cnt = 0;
    longint total_cycles = 0;
    int min_hit_cycles = 1000;
    int max_miss_cycles = 0;
    
    initial begin
        // 1. Khoi tao cac tin hieu
        rst_n = 0;
        s_axi_awaddr = 0; s_axi_awvalid = 0; s_axi_wdata = 0; s_axi_wvalid = 0;
        s_axi_bready = 0; s_axi_araddr = 0; s_axi_arvalid = 0; s_axi_rready = 0;
        m_axi_awready = 0; m_axi_wready = 0; m_axi_bvalid = 0;
        m_axi_arready = 0; m_axi_rvalid = 0; m_axi_rdata = 0; m_axi_rlast = 0;
        
        #100 rst_n = 1;
        #100;
        
        // 2. Cau hinh thanh ghi he thong
        $display("--- BAT DAU KHOI TAO HE THONG ---");
        
        // Dinh nghia thong so
        cfg_algo_sel         = 2'b10;  // 00: PLRU, 01: FIFO, 10: RANDOM
        cfg_locked_en        = 1'b1;   // Bat che do Sink
        cfg_immune_en        = 1'b1;   // Bat che do Local
        cfg_bounder          = 8'd36;  // Boundary cho mo hinh GPT-2
        cfg_window_size      = 8'd4;   // Kich thuoc cua so
        cfg_runtime_num_head = 16'd12; // Mo hinh GPT-2 co 12 Head

        // Tong hop thanh ghi bang toan tu noi chuoi { }
        // reg7: Bit 31(immune), 30(locked), 29:24(0), 23:16(window), 15:8(0), 7:0(bounder)
        reg7_data = {cfg_immune_en, cfg_locked_en, 6'b0, cfg_window_size, 8'b0, cfg_bounder};
        
        // reg8: Bit 31:30(algo), 29:16(0), 15:0(num_head)
        reg8_data = {cfg_algo_sel, 14'b0, cfg_runtime_num_head};

        // Ghi xuong mach phan cung
        write_reg(6'h1C, reg7_data); 
        write_reg(6'h20, reg8_data);
        #100;
        
        // 3. Bat dau doc va chay Trace
        $display("--- BAT DAU TRACE-DRIVEN SIMULATION ---");
        
        // Khởi tạo fd bằng hàm mở file
        fd = $fopen("real_trace.txt", "r");
        
        // Kiểm tra xem việc khởi tạo có thành công không
        if (fd == 0) begin
            $display("Loi: Khong doc duoc file. Hay kiem tra lai ten file hoac thu muc xsim!");
            $finish;
        end
        
        while (!$feof(fd)) begin
        scan_file = $fscanf(fd, "%d,%d,%d,%h,%h\n", tr_layer, tr_head, tr_token, tr_k, tr_v);
        if (scan_file == 5) begin
            total_cmds++;
            packed_addr = (tr_layer << 8) | tr_head;
            
            // 1 & 2. Chay song song Bom lenh (Driver) va Do tre (Monitor)
            current_latency = 0;
            
            fork
                begin : AXI_DRIVER_THREAD
                    // Luong 1: Bom lenh vao he thong (Se ton thoi gian delay cua AXI)
                    send_token_req(1'b1, packed_addr, tr_token, tr_k, tr_v);
                end
                
                begin : FSM_MONITOR_THREAD
                    // Luong 2: Canh dung khoanh khac FSM bat dau xu ly
                    wait(op_ready == 1'b0);
                    
                    // Bat dau dem nhip clock thuc te cua loi mach FSM
                    while (op_ready == 1'b0) begin
                        @(posedge clk);
                        current_latency++;
                        
                        if (current_latency > 1000) break; // Timeout Watchdog
                    end
                end
            join
            
            // Cong don vao tong chu ky cua he thong
            total_cycles = total_cycles + current_latency;
            
            // 3. Phân loại Hiệu năng (Profiler)
            if (current_latency > 1000) begin
                $display("[FAIL] Lệnh %0d bi treo! Token ID: %0d", total_cmds, tr_token);
                fail_cnt++;
                $finish; 
            end else begin
                if (current_latency < 15) begin
                    // Tốn ít chu kỳ -> Cache Hit
                    hit_cnt++;
                    // Cập nhật Hit Time (Độ trễ nhỏ nhất)
                    if (current_latency < min_hit_cycles) min_hit_cycles = current_latency;
                end else begin
                    // Tốn nhiều chu kỳ -> Phải truy cập DDR -> Cache Miss
                    miss_cnt++;
                    // Cập nhật Miss Time (Độ trễ lớn nhất)
                    if (current_latency > max_miss_cycles) max_miss_cycles = current_latency;
                end
            end
        end
    end
    
    $fclose(fd);
    
    // 4. In bảng báo cáo Kiến trúc Máy tính
    $display("==================================================");
    $display("         ARCHITECTURAL PERFORMANCE REPORT         ");
    $display("==================================================");
    $display(" [1] SYSTEM CONFIGURATION");
    $display("  Cache Organization : %0d Sets x %0d Ways", dut.NUM_SET, dut.N_WAY);
    if (cfg_algo_sel == 2'b00)
        $display("  Replacement Algo   : PLRU");
    else if (cfg_algo_sel == 2'b01)
        $display("  Replacement Algo   : FIFO");
    else if (cfg_algo_sel == 2'b10)
        $display("  Replacement Algo   : RANDOM");
    else
        $display("  Replacement Algo   : Unknown");
    $display("  Locked Zone (Sink) : %s (Boundary = %0d)", cfg_locked_en ? "ENABLED" : "DISABLED", cfg_bounder);
    $display("  Immune Flag (Local): %s (Window Size = %0d)", cfg_immune_en ? "ENABLED" : "DISABLED", cfg_window_size);
    $display(" ------------------------------------------------ ");
    $display(" [2] EXECUTION RESULTS");
    $display("  Total Trace Commands   : %0d", total_cmds);
    $display("  System Hang/Failures   : %0d", fail_cnt);
    $display("  Cache Hit Count        : %0d", hit_cnt);
    $display("  Cache Miss Count       : %0d", miss_cnt);
    $display("  Hit Rate               : %0.2f %%", (hit_cnt * 100.0) / total_cmds);
    $display(" ------------------------------------------------ ");
    $display(" [3] LATENCY ANALYSIS");
    $display("  Cache Hit Time (Best)  : %0d Cycles", min_hit_cycles);
    $display("  Cache Miss Time (Worst): %0d Cycles", max_miss_cycles);
    $display("  Total Execution Cycles : %0d Cycles", total_cycles);
    $display("  Average Latency/Cmd    : %0.2f Cycles", real'(total_cycles) / real'(total_cmds));
    $display("==================================================");
        
        #1000;
        $finish;
    end

endmodule