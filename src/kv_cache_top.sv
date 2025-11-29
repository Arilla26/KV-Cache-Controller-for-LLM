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
module kv_cache_top #(
    parameter int NUM_SET     = 64,
    parameter int N_WAY       = 4,    // phải là 2^k
    parameter int NUM_LAYER   = 12,
    parameter int NUM_HEAD    = 8,
    parameter int MAX_TOKENS  = 1024,
    parameter int DK_WIDTH    = 64,
    parameter int DV_WIDTH    = 64,
    parameter int READ_LATENCY= 8
) (
    input  logic clk,
    input  logic rst_n,

    // -------- REQUEST ----------
    input  logic                      op_valid,
    output logic                      op_ready,
    input  logic                      op_is_write,   // 0=read, 1=write

    input  logic [$clog2(NUM_LAYER)-1:0]   op_layer_id,
    input  logic [$clog2(NUM_HEAD)-1:0]    op_head_id,
    input  logic [$clog2(MAX_TOKENS)-1:0]  op_token_idx,
    input  logic [DK_WIDTH-1:0]            op_k,      // dùng khi write
    input  logic [DV_WIDTH-1:0]            op_v,      // dùng khi write

    // -------- RESPONSE ----------
    output logic                      resp_valid,
    output logic                      resp_is_write,
    output logic                      resp_hit,      // meaningful khi read
    output logic [DK_WIDTH-1:0]       resp_k,
    output logic [DV_WIDTH-1:0]       resp_v
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
            // token_part: lấy SET_BITS bit thấp (giả định TOKEN_BITS >= SET_BITS)
            token_part = token_idx[SET_BITS-1:0];

            // head_part: zero-extend hoặc truncate an toàn
            if (HEAD_BITS >= SET_BITS)
                head_part = head_id[SET_BITS-1:0];
            else begin
                head_part = '0;
                head_part[HEAD_BITS-1:0] = head_id;
            end

            // layer_part: tương tự
            if (LAYER_BITS >= SET_BITS)
                layer_part = layer_id[SET_BITS-1:0];
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
    // Lưu way_to_fill cho write (module-level, không khai báo trong always)
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
                .DATA_WIDTH(DATA_WIDTH)
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

    // ---------------- DDR ----------------
    logic ddr_wr_en;
    logic [LAYER_BITS-1:0] ddr_wr_layer_id;
    logic [HEAD_BITS-1:0]  ddr_wr_head_id;
    logic [TOKEN_BITS-1:0] ddr_wr_token_idx;
    logic [DK_WIDTH-1:0]   ddr_wr_k;
    logic [DV_WIDTH-1:0]   ddr_wr_v;

    logic ddr_rd_en;
    logic ddr_rd_valid;
    logic [DK_WIDTH-1:0] ddr_rd_k;
    logic [DV_WIDTH-1:0] ddr_rd_v;

    kv_ddr_model #(
        .NUM_LAYER    (NUM_LAYER),
        .NUM_HEAD     (NUM_HEAD),
        .MAX_TOKENS   (MAX_TOKENS),
        .DK_WIDTH     (DK_WIDTH),
        .DV_WIDTH     (DV_WIDTH),
        .READ_LATENCY (READ_LATENCY)
    ) u_ddr (
        .clk          (clk),
        .rst_n        (rst_n),

        .wr_en        (ddr_wr_en),
        .wr_layer_id  (ddr_wr_layer_id),
        .wr_head_id   (ddr_wr_head_id),
        .wr_token_idx (ddr_wr_token_idx),
        .wr_k         (ddr_wr_k),
        .wr_v         (ddr_wr_v),

        .rd_en        (ddr_rd_en),
        .rd_layer_id  (cur_layer_id),
        .rd_head_id   (cur_head_id),
        .rd_token_idx (cur_token_idx),

        .rd_valid     (ddr_rd_valid),
        .rd_k         (ddr_rd_k),
        .rd_v         (ddr_rd_v)
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
        ddr_wr_k         = '0;
        ddr_wr_v         = '0;

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
                        resp_valid    = 1'b1;
                        resp_is_write = 1'b0;
                        resp_hit      = 1'b1;
                        {resp_k, resp_v} = set_data_out[cur_set_idx];
                        next_state    = S_IDLE;
                    end else begin
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
                    set_fill_data[cur_set_idx] = {ddr_rd_k, ddr_rd_v};

                    resp_valid    = 1'b1;
                    resp_is_write = 1'b0;
                    resp_hit      = 1'b0;
                    resp_k        = ddr_rd_k;
                    resp_v        = ddr_rd_v;

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
                    // Write-through xuống DDR
                    ddr_wr_en        = 1'b1;
                    ddr_wr_layer_id  = cur_layer_id;
                    ddr_wr_head_id   = cur_head_id;
                    ddr_wr_token_idx = cur_token_idx;
                    ddr_wr_k         = cur_k;
                    ddr_wr_v         = cur_v;

                    // Write-allocate vào cache
                    if (set_hit[cur_set_idx])
                        way_to_fill = set_hit_way[cur_set_idx];
                    else
                        way_to_fill = set_alloc_way[cur_set_idx];

                    set_fill_en[cur_set_idx]   = 1'b1;
                    set_fill_way[cur_set_idx]  = way_to_fill;
                    set_fill_tag[cur_set_idx]  = cur_tag;
                    set_fill_data[cur_set_idx] = {cur_k, cur_v};

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
