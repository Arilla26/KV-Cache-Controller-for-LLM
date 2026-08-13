`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/06/2026 03:17:01 PM
// Design Name: 
// Module Name: tb_kv_cache
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

module tb_kv_cache();

    // Khai báo hằng số
    localparam int C_S_AXI_ADDR_WIDTH = 6;
    localparam int C_S_AXI_DATA_WIDTH = 32;
    localparam int C_M_AXI_ADDR_WIDTH = 32;
    localparam int C_M_AXI_DATA_WIDTH = 64;

    // Tín hiệu Clock và Reset
    logic clk;
    logic rst_n;

    // Tín hiệu AXI-Lite (CPU Host)
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

    // Tín hiệu AXI-Full (DDR Memory)
    logic [C_M_AXI_ADDR_WIDTH-1:0] m_axi_awaddr;
    logic                          m_axi_awvalid;
    logic                          m_axi_awready;
    logic [C_M_AXI_DATA_WIDTH-1:0] m_axi_wdata;
    logic                          m_axi_wvalid;
    logic                          m_axi_wready;
    logic [1:0]                    m_axi_bresp;
    logic                          m_axi_bvalid;
    logic                          m_axi_bready;
    logic [C_M_AXI_ADDR_WIDTH-1:0] m_axi_araddr;
    logic                          m_axi_arvalid;
    logic                          m_axi_arready;
    logic [C_M_AXI_DATA_WIDTH-1:0] m_axi_rdata;
    logic [1:0]                    m_axi_rresp;
    logic                          m_axi_rvalid;
    logic                          m_axi_rready;
    
    logic [7:0]                        m_axi_awlen;
    logic [2:0]                        m_axi_awsize;
    logic [1:0]                        m_axi_awburst;
    logic [(C_M_AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb;
    logic                              m_axi_wlast;
    
    logic [7:0]                        m_axi_arlen;
    logic [2:0]                        m_axi_arsize;
    logic [1:0]                        m_axi_arburst;
    logic                              m_axi_rlast;

    // Khởi tạo DUT (Device Under Test)
    kv_cache_axi_wrapper dut (.*);

    // Tạo Clock 100MHz (Chu kỳ 10ns)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // ---------------------------------------------------------
    // BFM 1: Giả lập DDR Memory (Phản hồi tự động)
    // ---------------------------------------------------------
    // Khai bao cac co trang thai doc lap cho BFM
    logic aw_received = 0;
    logic w_received  = 0;
    
    // Khai bao bien dem do tre
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
            
            // --- 1. KENH DIA CHI GHI (AW Channel) ---
            if (!aw_received && !write_processing && !m_axi_bvalid) begin
                m_axi_awready <= 1'b1;
                if (m_axi_awvalid && m_axi_awready) begin
                    m_axi_awready <= 1'b0; // Khoa cong sau khi nhan
                    aw_received   <= 1'b1; // Danh dau da nhan dia chi
                end
            end

            // --- 2. KENH DU LIEU GHI (W Channel) ---
            if (!w_received && !write_processing && !m_axi_bvalid) begin
                m_axi_wready <= 1'b1;
                if (m_axi_wvalid && m_axi_wready) begin
                    if (m_axi_wlast) begin // Doi den goi du lieu cuoi cung
                        m_axi_wready <= 1'b0;
                        w_received   <= 1'b1; // Danh dau da nhan xong du lieu
                    end
                end
            end

            // --- 3. DO TRE VA PHAN HOI GHI (B Channel) ---
            // Khi da nhan du ca dia chi va du lieu, bat dau tinh do tre RAM
            if (aw_received && w_received && !write_processing) begin
                write_processing <= 1'b1;
                write_delay_cnt  <= 25; // Gia lap do tre luu tru: 25 chu ky
                aw_received      <= 1'b0; // Reset co de chuan bi cho luong moi
                w_received       <= 1'b0;
            end

            if (write_processing) begin
                if (write_delay_cnt > 0) begin
                    write_delay_cnt <= write_delay_cnt - 1;
                end else begin
                    m_axi_bvalid     <= 1'b1; // Het do tre, RAM vay co bao xong
                    write_processing <= 1'b0;
                end
            end

            // Ket thuc giao dich ghi
            if (m_axi_bvalid && m_axi_bready) begin
                m_axi_bvalid <= 1'b0; 
            end


            // --- 4. KENH DOC VA DO TRE (AR and R Channel) ---
            if (!read_processing && !m_axi_rvalid) begin
                m_axi_arready <= 1'b1;
                if (m_axi_arvalid && m_axi_arready) begin
                    m_axi_arready   <= 1'b0; // Khoa cong
                    read_processing <= 1'b1;
                    read_delay_cnt  <= 30; // Gia lap do tre tim du lieu: 30 chu ky
                end
            end

            if (read_processing) begin
                if (read_delay_cnt > 0) begin
                    read_delay_cnt <= read_delay_cnt - 1;
                end else begin
                    m_axi_rvalid    <= 1'b1; // Tim thay du lieu
                    m_axi_rdata     <= 64'h00000000_084210FF;
                    m_axi_rlast     <= 1'b1; // Danh dau day la goi cuoi cung
                    read_processing <= 1'b0;
                end
            end

            // Ket thuc giao dich doc
            if (m_axi_rvalid && m_axi_rready) begin
                m_axi_rvalid <= 1'b0;
                m_axi_rlast  <= 1'b0;
            end
        end
    end

    // ---------------------------------------------------------
    // TASKS: Giả lập hành vi CPU
    // ---------------------------------------------------------
    
    // Task viết vào thanh ghi AXI-Lite
    task write_reg(input logic [5:0] addr, input logic [31:0] data);
        begin
            @(posedge clk);
            s_axi_awaddr  = addr;
            s_axi_awvalid = 1'b1;
            s_axi_wdata   = data;
            s_axi_wvalid  = 1'b1;
            s_axi_bready  = 1'b1;

            while (!s_axi_awready || !s_axi_wready) @(posedge clk);
            
            s_axi_awvalid <= 1'b0;
            s_axi_wvalid  <= 1'b0;

            // Chờ phản hồi ghi thành công
            while (!s_axi_bvalid) @(posedge clk);
            s_axi_bready <= 1'b0;
        end
    endtask

    // Task cấu hình hệ thống
    task config_system(
        input logic [1:0] algo, 
        input logic [15:0] heads, 
        input logic immune_en,
        input logic locked_en,
        input logic [13:0] window_size,
        input logic [15:0] locked_bound
    );
        begin
            logic [31:0] reg7_val;
            logic [31:0] reg8_val;
            
            // Reg 7: [31] Immune, [30] Locked, [29:16] Window, [15:0] Bound
            reg7_val = {immune_en, locked_en, window_size, locked_bound};
            write_reg(6'h1C, reg7_val); // Địa chỉ 0x1C = slv_reg7

            // Reg 8: [31:30] Algo, [15:0] Heads
            reg8_val = {algo, 14'd0, heads};
            write_reg(6'h20, reg8_val); // Địa chỉ 0x20 = slv_reg8
        end
    endtask

    // Task gửi yêu cầu Đọc/Ghi Token
    task send_token_req(
        input logic is_write,
        input logic [15:0] layer_head, // Gộp chung cho tiện: [31:16] layer, [15:0] head
        input logic [31:0] token_id,
        input logic [31:0] k_data,
        input logic [31:0] v_data
    );
        begin
            write_reg(6'h04, {16'd0, layer_head}); // slv_reg1
            write_reg(6'h08, token_id);            // slv_reg2
            write_reg(6'h0C, k_data);              // slv_reg3 (K Low)
            write_reg(6'h14, v_data);              // slv_reg5 (V Low)
            
            // Kích hoạt lệnh (slv_reg0: bit 1 = is_write, bit 0 = op_valid)
            write_reg(6'h00, {30'd0, is_write, 1'b1}); 

            // Chờ cho đến khi FSM hoàn thành và dọn cờ
            wait(dut.slv_reg0[0] == 1'b0); 
            $display("Token %0d processed at Time = %0t", token_id, $time);
        end
    endtask

    // ---------------------------------------------------------
    // KỊCH BẢN KIỂM THỬ CHÍNH
    // ---------------------------------------------------------
    initial begin
        // Khởi tạo giá trị ban đầu
        s_axi_awaddr = 0; s_axi_awvalid = 0; s_axi_wdata = 0; s_axi_wvalid = 0; s_axi_bready = 0;
        s_axi_araddr = 0; s_axi_arvalid = 0; s_axi_rready = 0;
        
        // Reset hệ thống
        rst_n = 0;
        #50;
        rst_n = 1;
        #50;

        $display("=== BẮT ĐẦU KIỂM THỬ ===");

        // Task 1: Cấu hình hệ thống ban đầu
        // Chạy thuật toán PLRU (00), 12 Head, Bật Immune, Tắt Locked Zone, Window = 4
        config_system(2'b00, 16'd12, 1'b1, 1'b0, 14'd4, 16'd64);

        // Task 2: Kiểm chứng luồng FSM cơ bản (Cold Miss -> Fill)
        // Ghi Token 1. Vì Cache đang trống, sẽ xảy ra Miss, nạp từ DDR vào
        $display("--- Test 1: Cache Miss & Fill ---");
        send_token_req(1'b1, 16'h0000, 32'd1, 32'hAAAA_BBBB, 32'hCCCC_DDDD);

        // Task 3: Kiểm chứng Cache Hit
        // Đọc lại chính Token 1. FSM phải tìm thấy trong BRAM và không kích hoạt DDR.
        $display("--- Test 2: Cache Hit ---");
        send_token_req(1'b0, 16'h0000, 32'd1, 32'h0, 32'h0);

        // Task 4: Kiểm chứng góc khuất Cờ miễn nhiễm (Hash Collision Deadlock)
        // Bơm liên tục 5 Token có cùng giá trị Hash (cố tình giữ nguyên Layer và Head, thay đổi Token ID sao cho bị băm vào cùng 1 Set).
        // Vì Window Size = 4, 4 Token đầu sẽ lấp đầy 4 Way và bật hết 4 Cờ miễn nhiễm.
        // Token thứ 5 đi vào phải ép mạch Rẽ nhánh dự phòng (Fallback) tước quyền bảo vệ để ghi đè.
        $display("--- Test 3: Immunity Corner Case (4-Way Full) ---");
        send_token_req(1'b1, 16'h0014, 32'd20, 32'h1111, 32'h1111);
        send_token_req(1'b1, 16'h0015, 32'd21, 32'h2222, 32'h2222);
        send_token_req(1'b1, 16'h0016, 32'd22, 32'h3333, 32'h3333);
        send_token_req(1'b1, 16'h0017, 32'd23, 32'h4444, 32'h4444);
        
        // Cú đấm quyết định: Token 104 sẽ đẩy hệ thống vào góc chết
        $display("-> Bom Token thu 5 gay tran Set 0");
        send_token_req(1'b1, 16'h0018, 32'd24, 32'h5555, 32'h5555);
        
        // Task 5: Chuyển đổi cấu hình nóng (Hot-swapping)
        // Chuyển sang thuật toán RANDOM (10), Bật Locked Zone bảo vệ Token 0
        $display("--- Test 4: Hot-swapping & Locked Zone ---");
        config_system(2'b10, 16'd12, 1'b1, 1'b1, 14'd4, 16'd64);
        
        // Ghi Token 0, theo logic nó phải được nhét vào không gian đặc quyền
        send_token_req(1'b1, 16'h0117, 32'd0, 32'hDEAD_BEEF, 32'hCAFE_BABE);

        #200;
        // Task 6: DDR Read Miss & Decode Penalty
        $display("--- Test 5: DDR Read Miss & Decode Penalty ---");
        send_token_req(1'b0, 16'h0000, 32'd999, 32'h0, 32'h0);
        #500;
        $display("=== KẾT THÚC KIỂM THỬ ===");
        $finish;
    end

endmodule