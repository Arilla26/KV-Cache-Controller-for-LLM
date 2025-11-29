`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/16/2025 08:31:53 PM
// Design Name: 
// Module Name: plru_tree
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
// plru_tree.sv
// Tree-PLRU cho 1 set N_WAY-way (N_WAY = 2^k)
//==========================================================
module plru_tree #(
    parameter int N_WAY = 4  // phải là 2,4,8,16,...
) (
    input  logic                     clk,
    input  logic                     rst_n,

    input  logic                     access_en,
    input  logic [$clog2(N_WAY)-1:0] access_way,

    output logic [$clog2(N_WAY)-1:0] victim_way
);

    localparam int DEPTH    = $clog2(N_WAY);
    localparam int N_INT    = N_WAY - 1;
    localparam int WAY_BITS = DEPTH;

    // heap-style: node 0 = root, left = 2*i+1, right = 2*i+2
    logic [N_INT-1:0] tree_bits;

    // ---------------- COMB: tính victim_way ----------------
    always_comb begin
        int node;
        int level;
        int idx;

        node = 0;
        idx  = 0;

        for (level = 0; level < DEPTH; level++) begin
            if (tree_bits[node] == 1'b0) begin
                // 0 -> nhánh trái LRU hơn
                node = 2*node + 1;
                idx  = (idx << 1);      // +0
            end else begin
                // 1 -> nhánh phải LRU hơn
                node = 2*node + 2;
                idx  = (idx << 1) | 1;  // +1
            end
        end

        victim_way = idx[WAY_BITS-1:0];
    end

    // ---------------- SEQ: update theo access_way ----------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tree_bits <= '0; // khởi tạo
        end else if (access_en) begin
            int node;
            int level;

            node = 0;
            for (level = 0; level < DEPTH; level++) begin
                logic dir;
                // MSB -> LSB của access_way
                dir = access_way[DEPTH-1-level];

                if (dir == 1'b0) begin
                    // đi trái -> đánh dấu phải LRU (bit = 1)
                    tree_bits[node] <= 1'b1;
                    node = 2*node + 1;
                end else begin
                    // đi phải -> đánh dấu trái LRU (bit = 0)
                    tree_bits[node] <= 1'b0;
                    node = 2*node + 2;
                end
            end
        end
    end

endmodule
