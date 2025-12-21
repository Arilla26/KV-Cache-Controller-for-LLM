`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 12/08/2025 08:34:29 AM
// Design Name: 
// Module Name: kv_delta_codec
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


module kv_delta_codec (
    // ---------------- ENCODER (64-bit -> 32-bit) ----------------
    // Dùng cho đường ghi: Controller -> DDR
    input  logic [63:0] raw_in,
    output logic [31:0] encoded_out,

    // ---------------- DECODER (32-bit -> 64-bit) ----------------
    // Dùng cho đường đọc: DDR -> Controller
    input  logic [31:0] encoded_in,
    output logic [63:0] decoded_out
);

    // ============================================================
    // PHẦN 1: ENCODER LOGIC (Mã hóa Delta)
    // ============================================================
    
    // 1. Tách vector 64-bit thành 4 phần tử 16-bit
    logic signed [15:0] e0, e1, e2, e3;
    assign e0 = raw_in[15:0];   // Base value
    assign e1 = raw_in[31:16];
    assign e2 = raw_in[47:32];
    assign e3 = raw_in[63:48];

    // 2. Tính Delta (Sự chênh lệch so với Base e0)
    // Dùng 17-bit có dấu để tính toán trung gian tránh tràn số
    logic signed [16:0] diff_1, diff_2, diff_3;
    assign diff_1 = e1 - e0;
    assign diff_2 = e2 - e0;
    assign diff_3 = e3 - e0;

    // 3. Hàm Saturation (Bão hòa về 5-bit: range -16 đến +15)
    function automatic logic [4:0] saturate_5bit(input logic signed [16:0] val);
        if (val > 17'sd15)       return 5'd15;   // Max dương (01111)
        else if (val < -17'sd16) return 5'd16;   // Max âm (-16 = 10000)
        else                     return val[4:0]; // Cắt lấy 5 bit cuối
    endfunction

    logic [4:0] d1_sat, d2_sat, d3_sat;

    always_comb begin
        d1_sat = saturate_5bit(diff_1);
        d2_sat = saturate_5bit(diff_2);
        d3_sat = saturate_5bit(diff_3);
        
        // Đóng gói (Packing): 
        // [Padding 1-bit] [Delta3 5-bit] [Delta2 5-bit] [Delta1 5-bit] [Base 16-bit]
        encoded_out = {1'b1, d3_sat, d2_sat, d1_sat, e0}; 
    end

    // ============================================================
    // PHẦN 2: DECODER LOGIC (Giải mã Delta)
    // ============================================================
    
    // 1. Tháo gói (Unpack)
    logic signed [15:0] base_val;
    logic signed [4:0]  dec_d1, dec_d2, dec_d3;
    
    assign base_val = encoded_in[15:0];
    assign dec_d1   = encoded_in[20:16];
    assign dec_d2   = encoded_in[25:21];
    assign dec_d3   = encoded_in[30:26];

    // 2. Tái tạo lại giá trị (Cộng Delta vào Base)
    // Verilog tự động sign-extend 5-bit lên 16-bit khi cộng
    logic signed [15:0] rec_e0, rec_e1, rec_e2, rec_e3;

    always_comb begin
        rec_e0 = base_val;
        rec_e1 = base_val + dec_d1;
        rec_e2 = base_val + dec_d2;
        rec_e3 = base_val + dec_d3;
    end

    // 3. Ghép lại thành vector 64-bit gốc
    assign decoded_out = {rec_e3, rec_e2, rec_e1, rec_e0};

endmodule
