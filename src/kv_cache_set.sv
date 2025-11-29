`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/16/2025 08:04:24 PM
// Design Name: 
// Module Name: kv_cache_set
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
// kv_cache_set.sv
//  - 1 set trong KV cache, N_WAY-way set-associative
//  - Lưu tag + valid + data (K+V)
//  - Dùng PLRU để chọn victim khi hết chỗ
//==========================================================
module kv_cache_set #(
    parameter int N_WAY      = 4,
    parameter int TAG_WIDTH  = 16,
    parameter int DATA_WIDTH = 128
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // ---------- LOOKUP ----------
    input  logic                     lookup_en,
    input  logic [TAG_WIDTH-1:0]     lookup_tag,

    output logic                     resp_valid,
    output logic                     hit,
    output logic [$clog2(N_WAY)-1:0] hit_way,
    output logic [$clog2(N_WAY)-1:0] alloc_way,
    output logic [DATA_WIDTH-1:0]    data_out,

    // ---------- FILL ----------
    input  logic                     fill_en,
    input  logic [$clog2(N_WAY)-1:0] fill_way,
    input  logic [TAG_WIDTH-1:0]     fill_tag,
    input  logic [DATA_WIDTH-1:0]    fill_data
);

    localparam int WAY_BITS = $clog2(N_WAY);

    // Tag + valid
    logic [TAG_WIDTH-1:0] tag_array [0:N_WAY-1];
    logic [N_WAY-1:0]     valid_bits;

    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_bits <= '0;
            for (i = 0; i < N_WAY; i++) begin
                tag_array[i] <= '0;
            end
        end else if (fill_en) begin
            tag_array[fill_way]  <= fill_tag;
            valid_bits[fill_way] <= 1'b1;
        end
    end

    // ---------------- HIT logic ----------------
    logic [N_WAY-1:0] hit_vec;

    always_comb begin
        for (int w = 0; w < N_WAY; w++) begin
            hit_vec[w] = valid_bits[w] && (tag_array[w] == lookup_tag);
        end
    end

    logic               hit_c;
    logic [WAY_BITS-1:0] hit_way_c;

    always_comb begin
        hit_c     = 1'b0;
        hit_way_c = '0;
        for (int w = 0; w < N_WAY; w++) begin
            if (hit_vec[w] && !hit_c) begin
                hit_c     = 1'b1;
                hit_way_c = w[WAY_BITS-1:0];
            end
        end
    end

    // ---------------- INVALID way ----------------
    logic [N_WAY-1:0] invalid_vec;
    assign invalid_vec = ~valid_bits;

    logic               has_invalid;
    logic [WAY_BITS-1:0] invalid_way;

    always_comb begin
        has_invalid = 1'b0;
        invalid_way = '0;
        for (int w = 0; w < N_WAY; w++) begin
            if (invalid_vec[w] && !has_invalid) begin
                has_invalid = 1'b1;
                invalid_way = w[WAY_BITS-1:0];
            end
        end
    end

    // ---------------- PLRU ----------------
    logic [WAY_BITS-1:0] plru_victim_way;
    logic                plru_access_en;
    logic [WAY_BITS-1:0] plru_access_way;

    assign plru_access_en  = (lookup_en && hit_c) || fill_en;
    assign plru_access_way = fill_en ? fill_way : hit_way_c;

    plru_tree #(
        .N_WAY(N_WAY)
    ) u_plru (
        .clk        (clk),
        .rst_n      (rst_n),
        .access_en  (plru_access_en),
        .access_way (plru_access_way),
        .victim_way (plru_victim_way)
    );

    // ---------------- alloc_way ----------------
    logic [WAY_BITS-1:0] alloc_way_c;

    always_comb begin
        if (has_invalid)
            alloc_way_c = invalid_way;
        else
            alloc_way_c = plru_victim_way;
    end

    // ---------------- Data RAM ----------------
    reg [DATA_WIDTH-1:0] data_mem [0:N_WAY-1];
    reg [DATA_WIDTH-1:0] data_q;

    logic [WAY_BITS-1:0] rd_addr_c;

    always_comb begin
        if (hit_c)
            rd_addr_c = hit_way_c;
        else
            rd_addr_c = alloc_way_c;
    end

    always_ff @(posedge clk) begin
        if (fill_en) begin
            data_mem[fill_way] <= fill_data;
        end
        if (lookup_en) begin
            data_q <= data_mem[rd_addr_c];
        end
    end

    // ---------------- Pipeline outputs ----------------
    logic lookup_en_q;
    logic hit_q;
    logic [WAY_BITS-1:0] hit_way_q;
    logic [WAY_BITS-1:0] alloc_way_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lookup_en_q <= 1'b0;
            hit_q       <= 1'b0;
            hit_way_q   <= '0;
            alloc_way_q <= '0;
        end else begin
            lookup_en_q <= lookup_en;
            hit_q       <= hit_c;
            hit_way_q   <= hit_way_c;
            alloc_way_q <= alloc_way_c;
        end
    end

    assign resp_valid = lookup_en_q;
    assign hit        = hit_q;
    assign hit_way    = hit_way_q;
    assign alloc_way  = alloc_way_q;
    assign data_out   = data_q;

endmodule
