`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/05/2026 09:58:53 AM
// Design Name: 
// Module Name: fifo_tracker
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
// kv_fifo_tracker.sv
// - Thuật toán thay thế First-In-First-Out
// - Sử dụng bộ đếm vòng (Circular Counter)
//==========================================================

module fifo_tracker #(
    parameter int N_WAY = 4
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // Khác với PLRU, FIFO chỉ dịch chuyển con trỏ khi có dữ liệu MỚI được nạp vào
    input  logic                     fill_en,
    
    output logic [$clog2(N_WAY)-1:0] victim_way
);

    localparam int WAY_BITS = $clog2(N_WAY);
    logic [WAY_BITS-1:0] fifo_ptr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_ptr <= '0;
        end else if (fill_en) begin
            // Tự động tràn (overflow) và quay vòng về 0 nhờ giới hạn số bit
            fifo_ptr <= fifo_ptr + 1'b1;
        end
    end

    // Ngõ ra luôn chỉ thẳng vào vị trí cũ nhất
    assign victim_way = fifo_ptr;

endmodule
