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
//////////////////////////////////////////////////////////////////////////////////
// Module Name: plru_tree
// Description: Tree-PLRU for 1 set, N_WAY-way (N_WAY must be power of 2)
//
// Internal tree layout (heap-style, 0-indexed):
//   N_WAY=8, DEPTH=3, N_INT=7 internal nodes
//
//             [0]
//            /   \
//          [1]   [2]
//          / \   / \
//        [3][4] [5][6]
//        /\ /\  /\ /\
//       W0 W1 W2 W3 W4 W5 W6 W7  (leaves = ways, not stored)
//
// Bit convention:
//   tree_bits[node] = 0  -->  left  subtree is LRU (victim goes left)
//   tree_bits[node] = 1  -->  right subtree is LRU (victim goes right)
//
// On access_en: flip bits along the path TO access_way,
//   pointing away from the accessed way so it won't be evicted next.
//
// Revision: cleaned variable declarations for synthesis robustness
//////////////////////////////////////////////////////////////////////////////////

module plru_tree #(
    parameter int N_WAY = 4   // must be 4 or 8
) (
    input  logic                     clk,
    input  logic                     rst_n,

    input  logic                     access_en,
    input  logic [$clog2(N_WAY)-1:0] access_way,

    output logic [$clog2(N_WAY)-1:0] victim_way
);

    localparam int DEPTH    = $clog2(N_WAY);  // tree height
    localparam int N_INT    = N_WAY - 1;       // number of internal nodes
    localparam int WAY_BITS = DEPTH;

    // Internal nodes stored as a flat array (heap indexing)
    logic [N_INT-1:0] tree_bits;

    // =========================================================
    // Combinational variables — used ONLY in always_comb below
    // Declared at module level (not inside block) for Vivado compat
    // =========================================================
    integer c_node;   // current node pointer for victim search
    integer c_level;  // loop counter
    integer c_idx;    // accumulates victim way index bit by bit

    // =========================================================
    // Sequential variables — used ONLY in always_ff below
    // Different names to avoid any ambiguity with comb block
    // =========================================================
    integer s_node;   // current node pointer for tree update
    integer s_level;  // loop counter
    logic   s_dir;    // direction bit at each level (0=left, 1=right)

    // =========================================================
    // COMBINATIONAL: compute victim_way from current tree_bits
    //
    // Traverses from root toward the LRU leaf:
    //   tree_bits[node]=0 -> go left  (left subtree is older)
    //   tree_bits[node]=1 -> go right (right subtree is older)
    // =========================================================
    always_comb begin
        c_node = 0;
        c_idx  = 0;

        for (c_level = 0; c_level < DEPTH; c_level++) begin
            if (tree_bits[c_node] == 1'b0) begin
                // Left subtree is LRU -> victim is in left subtree
                c_node = 2 * c_node + 1;
                c_idx  = (c_idx << 1);          // append 0
            end else begin
                // Right subtree is LRU -> victim is in right subtree
                c_node = 2 * c_node + 2;
                c_idx  = (c_idx << 1) | 1;      // append 1
            end
        end

        victim_way = c_idx[WAY_BITS-1:0];
    end

    // =========================================================
    // SEQUENTIAL: update tree_bits when a way is accessed
    //
    // Traverses from root toward access_way (MSB-first),
    // flipping each bit to point AWAY from the accessed path
    // so that accessed way becomes the MRU (least likely victim).
    //
    //   going LEFT  (dir=0) -> mark this node's bit = 1
    //                          (now right subtree appears LRU)
    //   going RIGHT (dir=1) -> mark this node's bit = 0
    //                          (now left subtree appears LRU)
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tree_bits <= '0;
        end else if (access_en) begin
            s_node = 0;
            for (s_level = 0; s_level < DEPTH; s_level++) begin
                // Read direction bit: MSB of access_way first
                s_dir = access_way[DEPTH-1-s_level];

                if (s_dir == 1'b0) begin
                    // Went left -> mark right as LRU
                    tree_bits[s_node] <= 1'b1;
                    s_node = 2 * s_node + 1;   // descend left
                end else begin
                    // Went right -> mark left as LRU
                    tree_bits[s_node] <= 1'b0;
                    s_node = 2 * s_node + 2;   // descend right
                end
            end
        end
    end

endmodule