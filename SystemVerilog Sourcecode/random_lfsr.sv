`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/05/2026 09:59:42 AM
// Design Name: 
// Module Name: random_lfsr
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
// kv_random_lfsr.sv
// - Thuật toán thay thế Ngẫu nhiên (Random)
// - Sử dụng LFSR 8-bit (Đa thức: x^8 + x^6 + x^5 + x^4 + 1)
//==========================================================

module random_lfsr #(
    parameter int N_WAY = 4
) (
    input  logic                     clk,
    input  logic                     rst_n,
    
    // LFSR chạy tự do mỗi chu kỳ clock để đảm bảo tính ngẫu nhiên
    // so với thời điểm xảy ra Cache Miss
    output logic [$clog2(N_WAY)-1:0] victim_way
);

    localparam int WAY_BITS = $clog2(N_WAY);
    
    // Thanh ghi 8-bit, không được phép bằng 0 (Seed ban đầu là 8'hFF)
    logic [7:0] lfsr_reg;
    logic feedback;

    // Đa thức phản hồi cho LFSR 8-bit: taps tại 8, 6, 5, 4
    assign feedback = lfsr_reg[7] ^ lfsr_reg[5] ^ lfsr_reg[4] ^ lfsr_reg[3];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr_reg <= 8'hFF; // Seed
        end else begin
            // Dịch trái và đẩy bit phản hồi vào LSB
            lfsr_reg <= {lfsr_reg[6:0], feedback};
        end
    end

    // Trích xuất n bit cuối cùng để làm chỉ số Way nạn nhân
    assign victim_way = lfsr_reg[WAY_BITS-1:0];

endmodule
