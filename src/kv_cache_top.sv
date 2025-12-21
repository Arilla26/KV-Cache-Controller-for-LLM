`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/18/2025 08:57:32 AM
// Design Name: 
// Module Name: kv_cache_top
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
// kv_cache_top.sv
//  - Hệ thống KV cache (PLRU + BRAM) + DDR full KV
//  - Giao diện:
//      + op_valid/op_ready
//      + op_is_write = 0: đọc KV
//      + op_is_write = 1: ghi KV mới (write-through + write-allocate)
//==========================================================
`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: kv_cache_top
// Description: 
//  - Hệ thống KV cache (PLRU + BRAM) + DDR Model
//  - TÍCH HỢP: Compression Codec (Delta Encoding) tại giao tiếp DDR
//      + BRAM lưu 64-bit (Fast access)
//      + DDR lưu 32-bit (Compressed - Save bandwidth)
//////////////////////////////////////////////////////////////////////////////////

module kv_cache_top #(
    parameter int NUM_SET     = 64,
    parameter int N_WAY       = 4,    // phải là 2^k
    parameter int NUM_LAYER   = 12,
    parameter int NUM_HEAD    = 8,
    parameter int MAX_TOKENS  = 1024,
    
    // Giao tiếp User và BRAM vẫn giữ nguyên độ rộng gốc (Raw)
    parameter int DK_WIDTH    = 64, 
    parameter int DV_WIDTH    = 64,
    
    parameter int READ_LATENCY= 8
) (
    input  logic clk,
    input  logic rst_n,

    // -------- REQUEST (User Interface) ----------
    input  logic                      op_valid,
    output logic                      op_ready,
    input  logic                      op_is_write,   // 0=read, 1=write

    input  logic [$clog2(NUM_LAYER)-1:0]   op_layer_id,
    input  logic [$clog2(NUM_HEAD)-1:0]    op_head_id,
    input  logic [$clog2(MAX_TOKENS)-1:0]  op_token_idx,
    input  logic [DK_WIDTH-1:0]            op_k,      // Raw input
    input  logic [DV_WIDTH-1:0]            op_v,      // Raw input

    // -------- RESPONSE (User Interface) ----------
    output logic                      resp_valid,
    output logic                      resp_is_write,
    output logic                      resp_hit,      
    output logic [DK_WIDTH-1:0]       resp_k,     // Raw output
    output logic [DV_WIDTH-1:0]       resp_v      // Raw output
);

    localparam int LAYER_BITS = $clog2(NUM_LAYER);
    localparam int HEAD_BITS  = $clog2(NUM_HEAD);
    localparam int TOKEN_BITS = $clog2(MAX_TOKENS);
    localparam int SET_BITS   = $clog2(NUM_SET);
    localparam int WAY_BITS   = $clog2(N_WAY);
    localparam int TAG_WIDTH  = LAYER_BITS + HEAD_BITS + TOKEN_BITS;
    localparam int DATA_WIDTH = DK_WIDTH + DV_WIDTH;

    // ---------------- Hàm mapping set & tag ----------------
    function automatic [SET_BITS-1:0] calc_set_idx(
        input logic [LAYER_BITS-1:0] layer_id,
        input logic [HEAD_BITS-1:0]  head_id,
        input logic [TOKEN_BITS-1:0] token_idx
    );
        logic [SET_BITS-1:0] token_part, head_part, layer_part;
        begin
            token_part = token_idx[SET_BITS-1:0];

            if (HEAD_BITS >= SET_BITS) head_part = head_id[SET_BITS-1:0];
            else begin
                head_part = '0;
                head_part[HEAD_BITS-1:0] = head_id;
            end

            if (LAYER_BITS >= SET_BITS) layer_part = layer_id[SET_BITS-1:0];
            else begin
                layer_part = '0;
                layer_part[LAYER_BITS-1:0] = layer_id;
            end

            calc_set_idx = token_part ^ head_part ^ layer_part;
        end
    endfunction

    function automatic [TAG_WIDTH-1:0] calc_tag(
        input logic [LAYER_BITS-1:0] layer_id,
        input logic [HEAD_BITS-1:0]  head_id,
        input logic [TOKEN_BITS-1:0] token_idx
    );
        calc_tag = {layer_id, head_id, token_idx};
    endfunction

    // ---------------- Trạng thái op hiện tại ----------------
    typedef enum logic [2:0] {
        S_IDLE      = 3'd0,
        S_RD_LOOKUP = 3'd1,
        S_RD_RESP   = 3'd2,
        S_RD_WAIT   = 3'd3,
        S_WR_LOOKUP = 3'd4,
        S_WR_RESP   = 3'd5
    } state_t;

    state_t state, next_state;

    logic              cur_is_write;
    logic [LAYER_BITS-1:0] cur_layer_id;
    logic [HEAD_BITS-1:0]  cur_head_id;
    logic [TOKEN_BITS-1:0] cur_token_idx;
    logic [SET_BITS-1:0]   cur_set_idx;
    logic [TAG_WIDTH-1:0]  cur_tag;
    logic [DK_WIDTH-1:0]   cur_k;
    logic [DV_WIDTH-1:0]   cur_v;
    
    // Lưu alloc_way khi read miss
    logic [WAY_BITS-1:0]   miss_alloc_way;
    // Lưu way_to_fill cho write
    logic [WAY_BITS-1:0]   way_to_fill;

    // ---------------- kv_cache_set per set ----------------
    logic [NUM_SET-1:0]              set_lookup_en;
    logic [TAG_WIDTH-1:0]            set_lookup_tag [NUM_SET];
    logic [NUM_SET-1:0]              set_resp_valid;
    logic [NUM_SET-1:0]              set_hit;
    logic [WAY_BITS-1:0]             set_hit_way   [NUM_SET];
    logic [WAY_BITS-1:0]             set_alloc_way [NUM_SET];
    logic [DATA_WIDTH-1:0]           set_data_out  [NUM_SET];
    logic [NUM_SET-1:0]              set_fill_en;
    logic [WAY_BITS-1:0]             set_fill_way  [NUM_SET];
    logic [TAG_WIDTH-1:0]            set_fill_tag  [NUM_SET];
    logic [DATA_WIDTH-1:0]           set_fill_data [NUM_SET];

    genvar s;
    generate
        for (s = 0; s < NUM_SET; s++) begin : gen_set
            kv_cache_set #(
                .N_WAY     (N_WAY),
                .TAG_WIDTH (TAG_WIDTH),
                .DATA_WIDTH(DATA_WIDTH) // Cache lưu FULL WIDTH (128 bit)
            ) u_set (
                .clk        (clk),
                .rst_n      (rst_n),
                .lookup_en  (set_lookup_en[s]),
                .lookup_tag (set_lookup_tag[s]),
                .resp_valid (set_resp_valid[s]),
                .hit        (set_hit[s]),
                .hit_way    (set_hit_way[s]),
                .alloc_way  (set_alloc_way[s]),
                .data_out   (set_data_out[s]),
                .fill_en    (set_fill_en[s]),
                .fill_way   (set_fill_way[s]),
                .fill_tag   (set_fill_tag[s]),
                .fill_data  (set_fill_data[s])
            );
        end
    endgenerate

    // ============================================================
    // COMPRESSION LOGIC (CODEC) INTEGRATION
    // ============================================================
    
    // 1. Dây tín hiệu nén/giải nén
    // DDR Interface width = 32 bit (Compressed)
    localparam int COMP_WIDTH = 32; 

    // Tín hiệu đi XUỐNG DDR (Encode)
    logic [COMP_WIDTH-1:0] ddr_wr_k_enc;
    logic [COMP_WIDTH-1:0] ddr_wr_v_enc;

    // Tín hiệu đi LÊN từ DDR (Raw compressed data)
    logic [COMP_WIDTH-1:0] ddr_rd_k_raw; 
    logic [COMP_WIDTH-1:0] ddr_rd_v_raw;

    // Tín hiệu đã giải mã (Decode) để đưa vào Cache/User
    logic [DK_WIDTH-1:0]   ddr_rd_k_dec;
    logic [DV_WIDTH-1:0]   ddr_rd_v_dec;

    // 2. Instance Encoder/Decoder
    kv_delta_codec u_codec_k (
        .raw_in      (cur_k),           // Input từ Controller (S_WR_RESP)
        .encoded_out (ddr_wr_k_enc),    // Output nén -> DDR Write
        .encoded_in  (ddr_rd_k_raw),    // Input từ DDR Read
        .decoded_out (ddr_rd_k_dec)     // Output giải nén -> Fill BRAM
    );

    kv_delta_codec u_codec_v (
        .raw_in      (cur_v),
        .encoded_out (ddr_wr_v_enc),
        .encoded_in  (ddr_rd_v_raw),
        .decoded_out (ddr_rd_v_dec)
    );

    // ============================================================
    // DDR INTERFACE (COMPRESSED WIDTH)
    // ============================================================
    logic ddr_wr_en;
    logic [LAYER_BITS-1:0] ddr_wr_layer_id;
    logic [HEAD_BITS-1:0]  ddr_wr_head_id;
    logic [TOKEN_BITS-1:0] ddr_wr_token_idx;
    // Chú ý: input của DDR module bây giờ là 32-bit encoded
    // logic [COMP_WIDTH-1:0] ddr_wr_k -> nối thẳng ddr_wr_k_enc
    // logic [COMP_WIDTH-1:0] ddr_wr_v -> nối thẳng ddr_wr_v_enc

    logic ddr_rd_en;
    logic ddr_rd_valid;
    
    kv_ddr_model #(
        .NUM_LAYER    (NUM_LAYER),
        .NUM_HEAD     (NUM_HEAD),
        .MAX_TOKENS   (MAX_TOKENS),
        .DK_WIDTH     (COMP_WIDTH), // <--- SỬA: DDR lưu 32 bit
        .DV_WIDTH     (COMP_WIDTH), // <--- SỬA: DDR lưu 32 bit
        .READ_LATENCY (READ_LATENCY)
    ) u_ddr (
        .clk          (clk),
        .rst_n        (rst_n),

        // Write Path (Data Nén)
        .wr_en        (ddr_wr_en),
        .wr_layer_id  (ddr_wr_layer_id),
        .wr_head_id   (ddr_wr_head_id),
        .wr_token_idx (ddr_wr_token_idx),
        .wr_k         (ddr_wr_k_enc),   // <--- Ghi data Encoded
        .wr_v         (ddr_wr_v_enc),   // <--- Ghi data Encoded

        // Read Path
        .rd_en        (ddr_rd_en),
        .rd_layer_id  (cur_layer_id),
        .rd_head_id   (cur_head_id),
        .rd_token_idx (cur_token_idx),

        .rd_valid     (ddr_rd_valid),
        .rd_k         (ddr_rd_k_raw),   // <--- Đọc data Encoded
        .rd_v         (ddr_rd_v_raw)    // <--- Đọc data Encoded
    );

    // ---------------- State register ----------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            cur_is_write <= 1'b0;
            cur_layer_id <= '0;
            cur_head_id  <= '0;
            cur_token_idx<= '0;
            cur_set_idx  <= '0;
            cur_tag      <= '0;
            cur_k        <= '0;
            cur_v        <= '0;
            miss_alloc_way <= '0;
        end else begin
            state <= next_state;

            if (state == S_IDLE && op_valid && op_ready) begin
                cur_is_write  <= op_is_write;
                cur_layer_id  <= op_layer_id;
                cur_head_id   <= op_head_id;
                cur_token_idx <= op_token_idx;
                cur_set_idx   <= calc_set_idx(op_layer_id, op_head_id, op_token_idx);
                cur_tag       <= calc_tag(op_layer_id, op_head_id, op_token_idx);
                cur_k         <= op_k;
                cur_v         <= op_v;
            end

            if (state == S_RD_RESP &&
                set_resp_valid[cur_set_idx] &&
               !set_hit[cur_set_idx]) begin
                miss_alloc_way <= set_alloc_way[cur_set_idx];
            end
        end
    end

    // ---------------- Control & outputs ----------------
    integer i;
    always_comb begin
        next_state      = state;
        op_ready        = 1'b0;

        resp_valid      = 1'b0;
        resp_is_write   = 1'b0;
        resp_hit        = 1'b0;
        resp_k          = '0;
        resp_v          = '0;

        ddr_wr_en        = 1'b0;
        ddr_wr_layer_id  = '0;
        ddr_wr_head_id   = '0;
        ddr_wr_token_idx = '0;
        
        ddr_rd_en        = 1'b0;

        for (i = 0; i < NUM_SET; i++) begin
            set_lookup_en[i]  = 1'b0;
            set_lookup_tag[i] = '0;
            set_fill_en[i]    = 1'b0;
            set_fill_way[i]   = '0;
            set_fill_tag[i]   = '0;
            set_fill_data[i]  = '0;
        end

        case (state)
            // ---------------- IDLE ----------------
            S_IDLE: begin
                op_ready = 1'b1;
                if (op_valid && op_ready) begin
                    if (op_is_write)
                        next_state = S_WR_LOOKUP;
                    else
                        next_state = S_RD_LOOKUP;
                end
            end

            // ---------------- READ ----------------
            S_RD_LOOKUP: begin
                set_lookup_en[cur_set_idx]  = 1'b1;
                set_lookup_tag[cur_set_idx] = cur_tag;
                next_state = S_RD_RESP;
            end

            S_RD_RESP: begin
                if (set_resp_valid[cur_set_idx]) begin
                    if (set_hit[cur_set_idx]) begin
                        // HIT: Trả về data trực tiếp từ BRAM (64-bit)
                        resp_valid    = 1'b1;
                        resp_is_write = 1'b0;
                        resp_hit      = 1'b1;
                        {resp_k, resp_v} = set_data_out[cur_set_idx];
                        next_state    = S_IDLE;
                    end else begin
                        // MISS: Đọc từ DDR
                        ddr_rd_en  = 1'b1;
                        next_state = S_RD_WAIT;
                    end
                end
            end

            S_RD_WAIT: begin
                if (ddr_rd_valid) begin
                    set_fill_en[cur_set_idx]   = 1'b1;
                    set_fill_way[cur_set_idx]  = miss_alloc_way;
                    set_fill_tag[cur_set_idx]  = cur_tag;
                    
                    // [TÍCH HỢP GIẢI MÃ]
                    // Data từ DDR về là dạng nén (raw), đã qua module u_codec_* giải mã thành dec
                    // Ta fill vào Cache dữ liệu ĐẦY ĐỦ (64-bit)
                    set_fill_data[cur_set_idx] = {ddr_rd_k_dec, ddr_rd_v_dec};

                    resp_valid    = 1'b1;
                    resp_is_write = 1'b0;
                    resp_hit      = 1'b0;
                    
                    // Trả về dữ liệu đã giải mã cho user
                    resp_k        = ddr_rd_k_dec;
                    resp_v        = ddr_rd_v_dec;
                    
                    next_state    = S_IDLE;
                end
            end

            // ---------------- WRITE ----------------
            S_WR_LOOKUP: begin
                set_lookup_en[cur_set_idx]  = 1'b1;
                set_lookup_tag[cur_set_idx] = cur_tag;
                next_state = S_WR_RESP;
            end

            S_WR_RESP: begin
                if (set_resp_valid[cur_set_idx]) begin
                    // [TÍCH HỢP MÃ HÓA]
                    // Write-through xuống DDR: Ghi dữ liệu đã nén
                    // cur_k/cur_v đi vào u_codec_*, ra ddr_wr_*_enc
                    ddr_wr_en        = 1'b1;
                    ddr_wr_layer_id  = cur_layer_id;
                    ddr_wr_head_id   = cur_head_id;
                    ddr_wr_token_idx = cur_token_idx;
                    // DDR module tự lấy tín hiệu từ wires ddr_wr_*_enc

                    // Write-allocate vào cache: Ghi dữ liệu gốc (Full 64-bit)
                    if (set_hit[cur_set_idx])
                        way_to_fill = set_hit_way[cur_set_idx];
                    else
                        way_to_fill = set_alloc_way[cur_set_idx];

                    set_fill_en[cur_set_idx]   = 1'b1;
                    set_fill_way[cur_set_idx]  = way_to_fill;
                    set_fill_tag[cur_set_idx]  = cur_tag;
                    set_fill_data[cur_set_idx] = {cur_k, cur_v}; // Cache luôn lưu Full
                    
                    resp_valid    = 1'b1;
                    resp_is_write = 1'b1;
                    resp_hit      = 1'b0;
                    next_state    = S_IDLE;
                end
            end

            default: begin
                next_state = S_IDLE;
            end
        endcase
    end

endmodule