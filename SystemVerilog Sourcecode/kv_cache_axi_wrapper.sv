`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 03/26/2026 02:00:31 PM
// Design Name: 
// Module Name: kv_cache_axi_wrapper
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

module kv_cache_axi_wrapper #(
    parameter int C_S_AXI_ADDR_WIDTH = 6, 
    parameter int C_S_AXI_DATA_WIDTH = 32,
    parameter int C_M_AXI_ADDR_WIDTH = 32,
    parameter int C_M_AXI_DATA_WIDTH = 64, // Giao tiếp 64-bit cho DDR
    
    // Tham số cấu hình cho Core
    parameter int NUM_SET    = 512,
    parameter int N_WAY      = 8,
    parameter int NUM_LAYER  = 32,
    parameter int NUM_HEAD   = 32,
    parameter int MAX_TOKENS = 1024
) (
    input logic clk,
    input logic rst_n,

    // =========================================================
    // 1. CỔNG AXI4-LITE SLAVE (Giao tiếp với CPU Host)
    // =========================================================
    input  logic [C_S_AXI_ADDR_WIDTH-1:0]       s_axi_awaddr,
    input  logic                                s_axi_awvalid,
    output logic                                s_axi_awready,
    input  logic [C_S_AXI_DATA_WIDTH-1:0]       s_axi_wdata,
    input  logic [(C_S_AXI_DATA_WIDTH/8)-1:0]   s_axi_wstrb,
    input  logic                                s_axi_wvalid,
    output logic                                s_axi_wready,
    output logic [1:0]                          s_axi_bresp,
    output logic                                s_axi_bvalid,
    input  logic                                s_axi_bready,
    
    input  logic [C_S_AXI_ADDR_WIDTH-1:0]       s_axi_araddr,
    input  logic                                s_axi_arvalid,
    output logic                                s_axi_arready,
    output logic [C_S_AXI_DATA_WIDTH-1:0]       s_axi_rdata,
    output logic [1:0]                          s_axi_rresp,
    output logic                                s_axi_rvalid,
    input  logic                                s_axi_rready,

    // =========================================================
    // 2. CỔNG AXI4-FULL MASTER (Giao tiếp với DDR)
    // =========================================================
    output logic [C_M_AXI_ADDR_WIDTH-1:0]       m_axi_awaddr,
    output logic [7:0]                          m_axi_awlen,
    output logic [2:0]                          m_axi_awsize,
    output logic [1:0]                          m_axi_awburst,
    output logic [2:0]                          m_axi_awprot,
    output logic [3:0]                          m_axi_awcache,
    output logic                                m_axi_awvalid,
    input  logic                                m_axi_awready,
    
    output logic [C_M_AXI_DATA_WIDTH-1:0]       m_axi_wdata,
    output logic [(C_M_AXI_DATA_WIDTH/8)-1:0]   m_axi_wstrb,
    output logic                                m_axi_wlast,
    output logic                                m_axi_wvalid,
    input  logic                                m_axi_wready,
    
    input  logic [1:0]                          m_axi_bresp,
    input  logic                                m_axi_bvalid,
    output logic                                m_axi_bready,
    
    output logic [C_M_AXI_ADDR_WIDTH-1:0]       m_axi_araddr,
    output logic [7:0]                          m_axi_arlen,
    output logic [2:0]                          m_axi_arsize,
    output logic [1:0]                          m_axi_arburst,
    output logic [2:0]                          m_axi_arprot,
    output logic [3:0]                          m_axi_arcache,
    output logic                                m_axi_arvalid,
    input  logic                                m_axi_arready,
    
    input  logic [C_M_AXI_DATA_WIDTH-1:0]       m_axi_rdata,
    input  logic                                m_axi_rlast,
    input  logic                                m_axi_rvalid,
    output logic                                m_axi_rready
);

    // =========================================================
    // KHAI BÁO TÍN HIỆU KẾT NỐI NỘI BỘ (INTERNAL WIRES)
    // =========================================================
    logic op_valid, op_ready, op_is_write;
    logic [$clog2(NUM_LAYER)-1:0]  op_layer_id;
    logic [$clog2(NUM_HEAD)-1:0]   op_head_id;
    logic [$clog2(MAX_TOKENS)-1:0] op_token_idx;
    logic [63:0] op_k, op_v;

    logic resp_valid, resp_is_write, resp_hit;
    logic [63:0] resp_k, resp_v;

    logic ddr_rd_en, ddr_rd_valid, ddr_ready;
    logic ddr_wr_en;
    logic [31:0] ddr_rd_k, ddr_rd_v, ddr_wr_k, ddr_wr_v;
    
    logic [$clog2(NUM_LAYER)-1:0]  ddr_wr_layer_id, ddr_rd_layer_id;
    logic [$clog2(NUM_HEAD)-1:0]   ddr_wr_head_id,  ddr_rd_head_id;
    logic [$clog2(MAX_TOKENS)-1:0] ddr_wr_token_idx, ddr_rd_token_idx;

    logic [$clog2(NUM_LAYER)-1:0]  ddr_addr_layer;
    logic [$clog2(NUM_HEAD)-1:0]   ddr_addr_head;
    logic [$clog2(MAX_TOKENS)-1:0] ddr_addr_token;

    // Bộ dồn kênh (Multiplexer) chọn địa chỉ DDR cho Đọc hoặc Ghi
    assign ddr_addr_layer = ddr_wr_en ? ddr_wr_layer_id : ddr_rd_layer_id;
    assign ddr_addr_head  = ddr_wr_en ? ddr_wr_head_id  : ddr_rd_head_id;
    assign ddr_addr_token = ddr_wr_en ? ddr_wr_token_idx : ddr_rd_token_idx;

    // =========================================================
    // KHỐI 1: AXI4-LITE SLAVE REGISTER MAP
    // =========================================================
    
    // slv_reg0: Điều khiển & Trạng thái (Control & Status)
    // - Bit [0] : START (CPU ghi 1 để ra lệnh chạy. Lõi sẽ tự clear về 0)
    // - Bit [1] : IS_WRITE (1 = Lệnh Ghi Data vào Cache, 0 = Lệnh Đọc)
    // - Bit [2] : READY (1 = Lõi đang rảnh, CPU cần đợi bit này lên 1 mới được ra lệnh)
    // - Bit [3] : HIT (1 = Hit, 0 = Miss. Cờ này từ IP Core truyền ra, chỉ xem sau khi lệnh Đọc kết thúc)
    // - Bit [4] : RESET
    // - Bit [31:5]: Reserved
    logic [31:0] slv_reg0;

    // slv_reg1: Tọa độ Cache (Layer ID & Head ID)
    // - Bit [31:16]: LAYER_ID
    // - Bit [15:0] : HEAD_ID
    logic [31:0] slv_reg1;

    // slv_reg2: Chỉ số Token (Token Index)
    // - Bit [31:0] : TOKEN_IDX
    logic [31:0] slv_reg2;

    // slv_reg3: Dữ liệu KEY (Nửa thấp - Low)
    // - Bit [31:0] : KEY_L
    logic [31:0] slv_reg3;

    // slv_reg4: Dữ liệu KEY (Nửa cao - High)
    // - Bit [31:0] : KEY_H
    logic [31:0] slv_reg4;

    // slv_reg5: Dữ liệu VALUE (Nửa thấp - Low)
    // - Bit [31:0] : VAL_L
    logic [31:0] slv_reg5;

    // slv_reg6: Dữ liệu VALUE (Nửa cao - High)
    // - Bit [31:0] : VAL_H
    logic [31:0] slv_reg6;

    // slv_reg7: Các tính năng Nâng cao (Advanced Features)
    // - Bit [31]   : IMMUNE_ENABLE (1 = Bật bảo vệ token theo window)
    // - Bit [30]   : LOCKED_ZONE_ENABLE (1 = Khóa cứng Token 0 không cho đào thải)
    // - Bit [29:16]: LOCAL_WINDOW_SIZE (Kích thước cửa sổ miễn nhiễm)
    // - Bit [15:0] : LOCKED_SETS_BOUND (Giới hạn vùng Set bị khóa)
    logic [31:0] slv_reg7;

    // slv_reg8: Cấu hình Kiến trúc & Thuật toán (Architecture Config)
    // - Bit [31:30]: ALGO_SEL (00: PLRU, 01: FIFO, 10: RANDOM)
    // - Bit [29:28]: SET_SEL (00: 128 Set, 01: 256 Set, 10: 512 Set)
    // - Bit [27]   : WAY_SEL (1: Mở full các Way, 0: Cắt giảm Way để tiết kiệm điện)
    // - Bit [15:0] : RUNTIME_NUM_HEAD (Số lượng Head chạy thực tế)
    logic [31:0] slv_reg8;
    
    logic aw_en;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            aw_en         <= 1'b1;
        end else begin
            if (~s_axi_awready && s_axi_awvalid && s_axi_wvalid && aw_en) begin
                s_axi_awready <= 1'b1;
                aw_en         <= 1'b0;
            end else if (s_axi_bready && s_axi_bvalid) begin
                aw_en         <= 1'b1;
                s_axi_awready <= 1'b0;
            end else begin
                s_axi_awready <= 1'b0;
            end

            if (~s_axi_wready && s_axi_wvalid && s_axi_awvalid && aw_en) begin
                s_axi_wready <= 1'b1;
            end else begin
                s_axi_wready <= 1'b0;
            end
        end
    end

    logic slv_reg_wren;
    assign slv_reg_wren = s_axi_wready && s_axi_wvalid && s_axi_awready && s_axi_awvalid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            slv_reg0 <= '0; slv_reg1 <= '0; slv_reg2 <= '0; slv_reg3 <= '0;
            slv_reg4 <= '0; slv_reg5 <= '0; slv_reg6 <= '0; slv_reg7 <= '0;
            slv_reg8 <= '0;
        end else begin
    
            // --- Ghi từ CPU (có thể xảy ra bất kỳ lúc nào) ---
            if (slv_reg_wren) begin
                case (s_axi_awaddr[C_S_AXI_ADDR_WIDTH-1:2])
                    4'h0: slv_reg0 <= s_axi_wdata;
                    4'h1: slv_reg1 <= s_axi_wdata;
                    4'h2: slv_reg2 <= s_axi_wdata;
                    4'h3: slv_reg3 <= s_axi_wdata;
                    4'h4: slv_reg4 <= s_axi_wdata;
                    4'h5: slv_reg5 <= s_axi_wdata;
                    4'h6: slv_reg6 <= s_axi_wdata;
                    4'h7: slv_reg7 <= s_axi_wdata;
                    4'h8: slv_reg8 <= s_axi_wdata;
                    default: ;
                endcase
            end
    
            // --- Auto-clear START bit sau khi core nhận lệnh ---
            // Tách khỏi if/else → luôn được check mọi cycle
            if (slv_reg0[0] == 1'b1 && op_ready == 1'b1)
                slv_reg0[0] <= 1'b0;
    
            // --- READY bit — luôn cập nhật, không bị block ---
            slv_reg0[2] <= op_ready;
    
            // --- Bắt kết quả từ core — luôn cập nhật, không bị block ---
            if (resp_valid) begin
                slv_reg0[3] <= resp_hit;
                if (!resp_is_write) begin
                    slv_reg3 <= resp_k[31:0];
                    slv_reg4 <= resp_k[63:32];
                    slv_reg5 <= resp_v[31:0];
                    slv_reg6 <= resp_v[63:32];
                end
            end
    
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_bvalid <= 1'b0;
            s_axi_bresp  <= 2'b00; 
        end else begin
            if (s_axi_awready && s_axi_awvalid && s_axi_wready && s_axi_wvalid && ~s_axi_bvalid) begin
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00; 
            end else if (s_axi_bready && s_axi_bvalid) begin
                s_axi_bvalid <= 1'b0; 
            end
        end
    end

    // Xử lý luồng Đọc AXI-Lite
    logic axi_arready_reg;
    logic axi_rvalid_reg;
    assign s_axi_arready = axi_arready_reg;
    assign s_axi_rvalid  = axi_rvalid_reg;
    assign s_axi_rresp   = 2'b00;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_arready_reg <= 1'b0;
            axi_rvalid_reg  <= 1'b0;
        end else begin
            if (~axi_arready_reg && s_axi_arvalid) begin
                axi_arready_reg <= 1'b1;
            end else begin
                axi_arready_reg <= 1'b0;
            end

            if (axi_arready_reg && s_axi_arvalid && ~axi_rvalid_reg) begin
                axi_rvalid_reg <= 1'b1;
            end else if (axi_rvalid_reg && s_axi_rready) begin
                axi_rvalid_reg <= 1'b0;
            end
        end
    end
    
    //Xử lý RESET
    logic cache_sw_rst_reg;
    logic rst_n_core;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cache_sw_rst_reg <= 1'b0;  // system reset clears SW
        else        cache_sw_rst_reg <= slv_reg0[4]; // follow CPU write
    end
    
    assign rst_n_core = rst_n & ~cache_sw_rst_reg;

    always_comb begin
        case (s_axi_araddr[C_S_AXI_ADDR_WIDTH-1:2])
            4'h0: s_axi_rdata = slv_reg0;
            4'h1: s_axi_rdata = slv_reg1;
            4'h2: s_axi_rdata = slv_reg2;
            4'h3: s_axi_rdata = slv_reg3;
            4'h4: s_axi_rdata = slv_reg4;
            4'h5: s_axi_rdata = slv_reg5;
            4'h6: s_axi_rdata = slv_reg6;
            4'h7: s_axi_rdata = slv_reg7;
            4'h8: s_axi_rdata = slv_reg8;
            default: s_axi_rdata = '0;
        endcase
    end

    // Gắn kết Thanh ghi với Lõi Cache
    assign op_valid     = slv_reg0[0];
    assign op_is_write  = slv_reg0[1];
    assign op_layer_id  = slv_reg1[31:16];
    assign op_head_id   = slv_reg1[15:0];
    assign op_token_idx = slv_reg2[$clog2(MAX_TOKENS)-1:0];
    assign op_k         = {slv_reg4, slv_reg3};
    assign op_v         = {slv_reg6, slv_reg5};
    
    // =========================================================
    // KHỐI 2: KHỞI TẠO LÕI KV CACHE 
    // =========================================================
    logic immune_enable;
    logic locked_zone_enable;
    logic [31:0] locked_sets_bound;
    logic [31:0] local_window_size;
    logic [31:0] active_set_mask;
    logic [N_WAY-1:0] active_way_mask;

    assign immune_enable = slv_reg7[31];
    assign locked_zone_enable = slv_reg7[30];
    assign local_window_size  = {18'd0, slv_reg7[29:16]}; 
    assign locked_sets_bound  = {16'd0, slv_reg7[15:0]};
    
    always_comb begin
        case (slv_reg8[29:28])
            2'b00: active_set_mask = 32'h0000_007F; // 128 Set (Index 0-127)
            2'b01: active_set_mask = 32'h0000_00FF; // 256 Set (Index 0-255)
            2'b10: active_set_mask = 32'h0000_01FF; // 512 Set (Index 0-511)
            default: active_set_mask = 32'h0000_01FF;
        endcase
    end
    
    assign active_way_mask = (slv_reg8[27] == 1'b1) ? 8'b1111_1111 : 8'b0000_1111;
    
    logic [1:0]  algo_sel; //00:PLRU, 01:FIFO, 10:RANDOM
    logic [15:0] runtime_num_head;
    assign algo_sel = slv_reg8[31:30];
    assign runtime_num_head = slv_reg8[15:0];
    
    kv_cache_top #(
        .NUM_SET(NUM_SET), .N_WAY(N_WAY),
        .MAX_LAYER(NUM_LAYER), .MAX_HEAD(NUM_HEAD), .MAX_TOKENS(MAX_TOKENS)
    ) u_kv_core (
        .clk(clk), .rst_n(rst_n_core),
        
        .algo_sel(algo_sel),
        .runtime_num_head(runtime_num_head),
        
        .locked_sets_bound(locked_sets_bound),
        .locked_zone_enable(locked_zone_enable),
        .immune_enable(immune_enable),
        .local_window_size(local_window_size),
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

    // =========================================================
    // KHỐI 3: AXI4-FULL MASTER (Giao tiếp với DDR)
    // =========================================================
    // GÁN CÁC TÍN HIỆU AXI QUAN TRỌNG ĐỂ DDR NHẬN DIỆN
    assign m_axi_wstrb   = 8'hFF;       // Luôn ghi full 8 byte (64-bit)
    assign m_axi_awburst = 2'b01;       // INCR burst mode (Bắt buộc để chạy DMA)
    assign m_axi_arburst = 2'b01;       // INCR burst mode
    
    // Khai báo các cờ bảo vệ để Vivado không báo Warning
    assign m_axi_awprot  = 3'b000;
    assign m_axi_arprot  = 3'b000;
    assign m_axi_awcache = 4'b0011;     // Normal Non-cacheable Bufferable
    assign m_axi_arcache = 4'b0011;
    
    localparam logic [C_M_AXI_ADDR_WIDTH-1:0] DDR_BASE_ADDR = 32'h1100_0000;

    function automatic logic [C_M_AXI_ADDR_WIDTH-1:0] calc_ddr_addr(
        input logic [$clog2(NUM_LAYER)-1:0] layer,
        input logic [$clog2(NUM_HEAD)-1:0]  head,
        input logic [$clog2(MAX_TOKENS)-1:0] token
    );
        logic [31:0] offset;
        offset = 32'({layer, head, token}); 
        calc_ddr_addr = DDR_BASE_ADDR + (offset << 3);
    endfunction

    logic ddr_wr_ready_pulse;
    logic ddr_rd_ready_pulse;
    
    assign ddr_ready = ddr_wr_ready_pulse | ddr_rd_ready_pulse;

    assign m_axi_awlen  = 8'd0;       
    assign m_axi_awsize = 3'b011;     
    assign m_axi_wlast  = 1'b1;
    
    assign m_axi_arlen  = 8'd0;
    assign m_axi_arsize = 3'b011;

    typedef enum logic [1:0] {
        M_WR_IDLE  = 2'd0,
        M_WR_ADDR  = 2'd1,
        M_WR_DATA  = 2'd2,
        M_WR_RESP  = 2'd3
    } m_wr_state_t;
    m_wr_state_t m_wr_state;

    // --- MÁY TRẠNG THÁI GHI ---
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_wr_state         <= M_WR_IDLE;
            m_axi_awvalid      <= 1'b0;
            m_axi_wvalid       <= 1'b0;
            m_axi_bready       <= 1'b0;
            ddr_wr_ready_pulse <= 1'b0;
        end else begin
            ddr_wr_ready_pulse <= 1'b0;
            
            case (m_wr_state)
                M_WR_IDLE: begin
                    if (ddr_wr_en) begin
                        m_axi_awaddr  <= calc_ddr_addr(ddr_wr_layer_id, ddr_wr_head_id, ddr_wr_token_idx);
                        m_axi_wdata   <= {ddr_wr_v, ddr_wr_k}; 
                        m_axi_awvalid <= 1'b1;
                        m_wr_state    <= M_WR_ADDR;
                    end
                end
                
                M_WR_ADDR: begin
                    if (m_axi_awready && m_axi_awvalid) begin
                        m_axi_awvalid <= 1'b0;
                        m_axi_wvalid  <= 1'b1;
                        m_wr_state    <= M_WR_DATA;
                    end
                end
                
                M_WR_DATA: begin
                    if (m_axi_wready && m_axi_wvalid) begin
                        m_axi_wvalid <= 1'b0;
                        m_axi_bready <= 1'b1; 
                        m_wr_state   <= M_WR_RESP;
                    end
                end
                
                M_WR_RESP: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        m_axi_bready       <= 1'b0;
                        ddr_wr_ready_pulse <= 1'b1; // BÁO LÕI LÀ ĐÃ GHI XONG
                        m_wr_state         <= M_WR_IDLE;
                    end
                end
            endcase
        end
    end

    typedef enum logic [1:0] {
        M_RD_IDLE  = 2'd0,
        M_RD_ADDR  = 2'd1,
        M_RD_DATA  = 2'd2
    } m_rd_state_t;
    m_rd_state_t m_rd_state;

    // --- MÁY TRẠNG THÁI ĐỌC ---
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_rd_state         <= M_RD_IDLE;
            m_axi_arvalid      <= 1'b0;
            m_axi_rready       <= 1'b0;
            ddr_rd_valid       <= 1'b0;
            ddr_rd_ready_pulse <= 1'b0;
        end else begin
            ddr_rd_valid       <= 1'b0;
            ddr_rd_ready_pulse <= 1'b0;

            case (m_rd_state)
                M_RD_IDLE: begin
                    if (ddr_rd_en && !ddr_wr_en) begin 
                        m_axi_araddr  <= calc_ddr_addr(ddr_addr_layer, ddr_addr_head, ddr_addr_token);
                        m_axi_arvalid <= 1'b1;
                        m_rd_state    <= M_RD_ADDR;
                    end
                end
                
                M_RD_ADDR: begin
                    if (m_axi_arready && m_axi_arvalid) begin
                        m_axi_arvalid      <= 1'b0;
                        m_axi_rready       <= 1'b1; 
                        ddr_rd_ready_pulse <= 1'b1; // BÁO LÕI LÀ ĐÃ NHẬN ĐỊA CHỈ
                        m_rd_state         <= M_RD_DATA;
                    end
                end
                
                M_RD_DATA: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        m_axi_rready <= 1'b0;
                        ddr_rd_k     <= m_axi_rdata[31:0];
                        ddr_rd_v     <= m_axi_rdata[63:32];
                        ddr_rd_valid <= 1'b1; // BÁO LÕI LÀ DỮ LIỆU ĐÃ VỀ
                        m_rd_state   <= M_RD_IDLE;
                    end
                end
            endcase
        end
    end

endmodule