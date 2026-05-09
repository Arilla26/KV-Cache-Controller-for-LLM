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
//==========================================================
// kv_delta_codec.sv  —  BF16 Truncation Codec
// Revision: 2.0  (replaces integer delta codec)
//
// Compression scheme: Float32 → BF16 (Brain Float 16)
//   Encode: keep the 16 MSBs of each float32
//           (sign[1] + exponent[8] + mantissa_high[7])
//           Discard lower 16 mantissa bits
//   Decode: restore float32 by padding 16 zero bits
//
// 64-bit input layout:  { float_B[31:0], float_A[31:0] }
// 32-bit encoded layout:{ bf16_B[15:0],  bf16_A[15:0]  }
//
// Properties:
//   Compression ratio : 2:1  (64-bit → 32-bit)
//   Max relative error: 2^-7 ≈ 0.78%  (7 mantissa bits kept)
//   Exponent preserved: YES  (dynamic range identical to FP32)
//   Pipeline latency  : 2 clock cycles  (both encoder and decoder)
//
// Reference:
//   BF16 format — Google Brain (TPU v2+), PyTorch AMP
//   "FP8 Formats for Deep Learning", Micikevicius et al., 2022
//     arXiv:2209.05433
//==========================================================

module kv_delta_codec (
    input  logic        clk,
    input  logic        rst_n,

    // ---------------- ENCODER (64-bit → 32-bit) ----------------
    input  logic        enc_valid_in,
    input  logic [63:0] raw_in,

    output logic        enc_valid_out,
    output logic [31:0] encoded_out,

    // ---------------- DECODER (32-bit → 64-bit) ----------------
    input  logic        dec_valid_in,
    input  logic [31:0] encoded_in,

    output logic        dec_valid_out,
    output logic [63:0] decoded_out
);

    // ============================================================
    // ENCODER PIPELINE (float32 × 2  →  BF16 × 2)
    //
    // Stage 1: extract BF16 from each float32
    //   bf16_A = raw_in[31:16]   (MSBs of float_A)
    //   bf16_B = raw_in[63:48]   (MSBs of float_B)
    //
    // Stage 2: register output (keeps 2-cycle latency)
    // ============================================================

    // Stage 1 wires
    logic [15:0] s1_bf16_a, s1_bf16_b;
    logic        s1_enc_valid;

    assign s1_bf16_a = raw_in[31:16];
    assign s1_bf16_b = raw_in[63:48];

    // Stage 1 → Stage 2 register
    logic [15:0] p1_bf16_a, p1_bf16_b;
    logic        p1_enc_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1_bf16_a    <= 16'h0;
            p1_bf16_b    <= 16'h0;
            p1_enc_valid <= 1'b0;
        end else begin
            p1_bf16_a    <= s1_bf16_a;
            p1_bf16_b    <= s1_bf16_b;
            p1_enc_valid <= enc_valid_in;
        end
    end

    // Stage 2: pack output register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            encoded_out   <= 32'h0;
            enc_valid_out <= 1'b0;
        end else begin
            // Layout: { bf16_B[15:0], bf16_A[15:0] }
            encoded_out   <= { p1_bf16_b, p1_bf16_a };
            enc_valid_out <= p1_enc_valid;
        end
    end

    // ============================================================
    // DECODER PIPELINE (BF16 × 2  →  float32 × 2)
    //
    // Stage 1: unpack BF16 values from encoded word
    //   bf16_A = encoded_in[15:0]
    //   bf16_B = encoded_in[31:16]
    //
    // Stage 2: restore float32 by padding 16 zero bits
    //   float_A = { bf16_A, 16'b0 }
    //   float_B = { bf16_B, 16'b0 }
    //
    // Zeros fill the discarded lower mantissa bits — this is
    // equivalent to round-toward-zero (truncation) and gives
    // the same result as hardware BF16→FP32 promotion.
    // ============================================================

    // Stage 1 wires
    logic [15:0] s1_dec_bf16_a, s1_dec_bf16_b;

    assign s1_dec_bf16_a = encoded_in[15:0];
    assign s1_dec_bf16_b = encoded_in[31:16];

    // Stage 1 → Stage 2 register
    logic [15:0] p1_dec_bf16_a, p1_dec_bf16_b;
    logic        p1_dec_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1_dec_bf16_a <= 16'h0;
            p1_dec_bf16_b <= 16'h0;
            p1_dec_valid  <= 1'b0;
        end else begin
            p1_dec_bf16_a <= s1_dec_bf16_a;
            p1_dec_bf16_b <= s1_dec_bf16_b;
            p1_dec_valid  <= dec_valid_in;
        end
    end

    // Stage 2: restore and pack output register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            decoded_out   <= 64'h0;
            dec_valid_out <= 1'b0;
        end else begin
            // float_A = { bf16_A, 16'b0 } → decoded_out[31:0]
            // float_B = { bf16_B, 16'b0 } → decoded_out[63:32]
            decoded_out   <= { p1_dec_bf16_b, 16'h0,
                               p1_dec_bf16_a, 16'h0 };
            dec_valid_out <= p1_dec_valid;
        end
    end

endmodule