`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/18/2025 07:02:17 AM
// Design Name: 
// Module Name: kv_ddr_model
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

//////////////////////////////////////////////////////////////////////////////////
// Module Name: kv_ddr_model
// Description: 
//  - Mô hình hành vi (Behavioral Model) của DDR DRAM.
//  - FIX: Dùng 'initial' block để khởi tạo bộ nhớ, tránh lỗi Loop Limit khi Synthesis.
//  - Hỗ trợ tham số hóa độ rộng data (DK_WIDTH, DV_WIDTH) để tương thích với Codec.
//////////////////////////////////////////////////////////////////////////////////

module kv_ddr_model #(
    parameter int NUM_LAYER    = 12,
    parameter int NUM_HEAD     = 8,
    parameter int MAX_TOKENS   = 1024,
    parameter int DK_WIDTH     = 64, 
    parameter int DV_WIDTH     = 64, 
    parameter int READ_LATENCY = 8
) (
    input  logic clk,
    input  logic rst_n,

    // -------- WRITE PORT --------
    input  logic                     wr_en,
    input  logic [$clog2(NUM_LAYER)-1:0]  wr_layer_id,
    input  logic [$clog2(NUM_HEAD)-1:0]   wr_head_id,
    input  logic [$clog2(MAX_TOKENS)-1:0] wr_token_idx,
    input  logic [DK_WIDTH-1:0]      wr_k,
    input  logic [DV_WIDTH-1:0]      wr_v,

    // -------- READ PORT --------
    input  logic                     rd_en,
    input  logic [$clog2(NUM_LAYER)-1:0]  rd_layer_id,
    input  logic [$clog2(NUM_HEAD)-1:0]   rd_head_id,
    input  logic [$clog2(MAX_TOKENS)-1:0] rd_token_idx,

    output logic                     rd_valid,
    output logic [DK_WIDTH-1:0]      rd_k,
    output logic [DV_WIDTH-1:0]      rd_v
);

    localparam int LAYER_BITS = $clog2(NUM_LAYER);
    localparam int HEAD_BITS  = $clog2(NUM_HEAD);
    localparam int TOKEN_BITS = $clog2(MAX_TOKENS);
    localparam int ADDR_WIDTH = LAYER_BITS + HEAD_BITS + TOKEN_BITS;
    
    // Tính toán độ sâu bộ nhớ (Depth)
    localparam int DEPTH      = (1 << ADDR_WIDTH);

    // Khai báo mảng nhớ (Memory Array)
    logic [DK_WIDTH-1:0] mem_k     [0:DEPTH-1];
    logic [DV_WIDTH-1:0] mem_v     [0:DEPTH-1];
    logic                mem_valid [0:DEPTH-1];

    function automatic [ADDR_WIDTH-1:0] make_addr(
        input logic [LAYER_BITS-1:0] layer,
        input logic [HEAD_BITS-1:0]  head,
        input logic [TOKEN_BITS-1:0] token
    );
        make_addr = {layer, head, token};
    endfunction

    // =================================================================
    // FIX ERROR: [Synth 8-403] loop limit exceeded
    // Thay vì dùng reset đồng bộ (tốn logic), dùng initial block cho mô phỏng.
    // =================================================================
    initial begin
        // Vòng lặp này chỉ chạy 1 lần lúc bắt đầu mô phỏng (Time = 0)
        // Synthesis tool sẽ bỏ qua hoặc xử lý riêng, không tốn tài nguyên FPGA.
        for (int i = 0; i < DEPTH; i++) begin
            mem_valid[i] = 1'b0;
            mem_k[i]     = '0;
            mem_v[i]     = '0;
        end
    end

    // ---------------- WRITE LOGIC ----------------
    always_ff @(posedge clk) begin
        // Không cần if (!rst_n) ở đây nữa vì đã init bên trên.
        // Chỉ xử lý ghi khi có lệnh.
        if (wr_en) begin
            logic [ADDR_WIDTH-1:0] waddr;
            waddr = make_addr(wr_layer_id, wr_head_id, wr_token_idx);
            
            mem_k[waddr]     <= wr_k;
            mem_v[waddr]     <= wr_v;
            mem_valid[waddr] <= 1'b1;
        end
    end

    // ---------------- READ PIPELINE ----------------
    // Mô phỏng độ trễ đọc của DDR thật (READ_LATENCY cycles)
    logic [READ_LATENCY-1:0]      rd_pipe_valid;
    logic [ADDR_WIDTH-1:0]        rd_pipe_addr [0:READ_LATENCY-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_pipe_valid <= '0;
            for (int s = 0; s < READ_LATENCY; s++) begin
                rd_pipe_addr[s] <= '0;
            end
        end else begin
            // Shift register cho valid signal
            rd_pipe_valid[0] <= rd_en;
            rd_pipe_addr[0]  <= make_addr(rd_layer_id, rd_head_id, rd_token_idx);

            for (int s = 1; s < READ_LATENCY; s++) begin
                rd_pipe_valid[s] <= rd_pipe_valid[s-1];
                rd_pipe_addr[s]  <= rd_pipe_addr[s-1];
            end
        end
    end

    // ---------------- OUTPUT LOGIC ----------------
    logic                  valid_out;
    logic [ADDR_WIDTH-1:0] addr_out;

    always_comb begin
        valid_out = rd_pipe_valid[READ_LATENCY-1];
        addr_out  = rd_pipe_addr [READ_LATENCY-1];
    end

    always_comb begin
        if (valid_out && mem_valid[addr_out]) begin
            rd_k = mem_k[addr_out];
            rd_v = mem_v[addr_out];
        end else begin
            rd_k = '0;
            rd_v = '0;
        end
    end

    assign rd_valid = valid_out;

endmodule