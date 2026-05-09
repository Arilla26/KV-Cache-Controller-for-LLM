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
//  - Quản lý Valid bits, Dirty bits
//  - Chỉ sinh cờ Nạn nhân thô (Raw Victim) từ các bộ PLRU/FIFO/Random
//  - Không tự tính toán cờ miễn nhiễm hay tìm khe hở an toàn nữa
//==========================================================

module kv_cache_set #(
    parameter int N_WAY = 8
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // Tín hiệu cập nhật từ FSM điều khiển
    input  logic                     hit_en,
    input  logic [$clog2(N_WAY)-1:0] hit_way,

    input  logic                     fill_en,
    input  logic [$clog2(N_WAY)-1:0] fill_way,
    
    input  logic [1:0]               algo_sel,

    // Tín hiệu ngõ ra
    output logic [N_WAY-1:0]         valid_bits,
    output logic [$clog2(N_WAY)-1:0] raw_victim, // Chỉ xuất cờ thuật toán thô

    // Quản lý Dirty bits
    input  logic                     set_dirty_en,
    input  logic                     clear_dirty_en,
    input  logic [$clog2(N_WAY)-1:0] dirty_way,
    output logic [N_WAY-1:0]         dirty_bits
);

    localparam int WAY_BITS = $clog2(N_WAY);

    // ----------------Logic tuần tự quản lý Valid bit--------------
    logic [N_WAY-1:0] valid_reg;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_reg <= '0;
        end else if (fill_en) begin
            valid_reg[fill_way] <= 1'b1;
        end
    end
    
    assign valid_bits = valid_reg;

    // ---------------- THUẬT TOÁN THAY THẾ (REPLACEMENT ALGORITHMS) ----------------
    logic [WAY_BITS-1:0] victim_plru;
    logic [WAY_BITS-1:0] victim_fifo;
    logic [WAY_BITS-1:0] victim_random;

    plru_tree #(
        .N_WAY (N_WAY)
    ) u_plru (
        .clk        (clk),
        .rst_n      (rst_n),
        .access_en  (hit_en | fill_en),
        .access_way (hit_en ? hit_way : fill_way),
        .victim_way (victim_plru)
    );

    fifo_tracker #(
        .N_WAY (N_WAY)
    ) u_fifo (
        .clk        (clk),
        .rst_n      (rst_n),
        .fill_en    (fill_en),
        .victim_way (victim_fifo)
    );

    random_lfsr #(
        .N_WAY (N_WAY)
    ) u_random (
        .clk        (clk),
        .rst_n      (rst_n),
        .victim_way (victim_random)
    );

    // Mux chọn thuật toán sinh cờ thô
    always_comb begin
        case (algo_sel)
            2'b00: raw_victim = victim_plru;
            2'b01: raw_victim = victim_fifo;
            2'b10: raw_victim = victim_random;
            default: raw_victim = victim_plru;
        endcase
    end

    // ----------------Logic tuần tự quản lý Dirty bit--------------
    logic [N_WAY-1:0] dirty_reg;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dirty_reg <= '0;
        end else begin
            if (set_dirty_en) begin
                dirty_reg[dirty_way] <= 1'b1;
            end else if (clear_dirty_en) begin
                dirty_reg[dirty_way] <= 1'b0;
            end
        end
    end
    
    assign dirty_bits = dirty_reg;

endmodule