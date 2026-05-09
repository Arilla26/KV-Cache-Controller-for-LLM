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

//==========================================================
// kv_cache_top.sv 
// - Kiến trúc phẳng, Truy xuất song song N_WAY (Parameterized)
// - Hỗ trợ Dynamic Cache Resizing qua active_set_mask & active_way_mask
// - Tích hợp Locked Zone và Cờ miễn nhiễm (Immunity Logic)
// - BẢN TỐI ƯU TIMING: Rút lõi logic Allocation từ Set lên Top (Pipeline)
//==========================================================

module kv_cache_top #(
    parameter int NUM_SET     = 512,
    parameter int N_WAY       = 8,
    parameter int MAX_LAYER   = 32,
    parameter int MAX_HEAD    = 32,
    parameter int MAX_TOKENS  = 1024,
    parameter int DK_WIDTH    = 64, 
    parameter int DV_WIDTH    = 64
) (
    input  logic clk,
    input  logic rst_n,

    // Giao tiếp cấu hình
    input  logic [1:0]                    algo_sel,
    input  logic [15:0]                   runtime_num_head,
    input  logic [31:0]                   locked_sets_bound,
    input  logic [31:0]                   local_window_size,
    input  logic                          locked_zone_enable,
    input  logic                          immune_enable,
    input  logic [31:0]                   active_set_mask,
    input  logic [N_WAY-1:0]              active_way_mask,

    // -------- REQUEST ----------
    input  logic                          op_valid,
    output logic                          op_ready,
    input  logic                          op_is_write,

    input  logic [$clog2(MAX_LAYER)-1:0]  op_layer_id,
    input  logic [$clog2(MAX_HEAD)-1:0]   op_head_id,
    input  logic [$clog2(MAX_TOKENS)-1:0] op_token_idx,
    input  logic [DK_WIDTH-1:0]           op_k,
    input  logic [DV_WIDTH-1:0]           op_v,

    // -------- RESPONSE ----------
    output logic                          resp_valid,
    output logic                          resp_is_write,
    output logic                          resp_hit,      
    output logic [DK_WIDTH-1:0]           resp_k,
    output logic [DV_WIDTH-1:0]           resp_v,

    // -------- EXTERNAL DDR INTERFACE --------
    input  logic                          ddr_ready,

    output logic                          ddr_wr_en,
    output logic [$clog2(MAX_LAYER)-1:0]  ddr_wr_layer_id,
    output logic [$clog2(MAX_HEAD)-1:0]   ddr_wr_head_id,
    output logic [$clog2(MAX_TOKENS)-1:0] ddr_wr_token_idx,
    output logic [31:0]                   ddr_wr_k,
    output logic [31:0]                   ddr_wr_v,

    output logic                          ddr_rd_en,
    output logic [$clog2(MAX_LAYER)-1:0]  ddr_rd_layer_id,
    output logic [$clog2(MAX_HEAD)-1:0]   ddr_rd_head_id,
    output logic [$clog2(MAX_TOKENS)-1:0] ddr_rd_token_idx,
    input  logic                          ddr_rd_valid,
    input  logic [31:0]                   ddr_rd_k,
    input  logic [31:0]                   ddr_rd_v
);
    localparam int LAYER_BITS = $clog2(MAX_LAYER);
    localparam int HEAD_BITS  = $clog2(MAX_HEAD);
    localparam int TOKEN_BITS = $clog2(MAX_TOKENS);
    localparam int SET_BITS   = $clog2(NUM_SET);
    localparam int WAY_BITS   = $clog2(N_WAY);
    localparam int TAG_WIDTH  = LAYER_BITS + HEAD_BITS + TOKEN_BITS;
    localparam int DATA_WIDTH = DK_WIDTH + DV_WIDTH;
    localparam int COMP_WIDTH = 32;
    
    // Thanh ghi nội bộ lưu trữ ngõ vào
    logic cur_is_write;
    logic [LAYER_BITS-1:0] cur_layer_id;
    logic [HEAD_BITS-1:0]  cur_head_id;
    logic [TOKEN_BITS-1:0] cur_token_idx;
    logic [SET_BITS-1:0]   cur_set_idx;
    logic [TAG_WIDTH-1:0]  cur_tag;
    logic [DK_WIDTH-1:0]   cur_k_reg;
    logic [DV_WIDTH-1:0]   cur_v_reg;
    logic [$clog2(N_WAY)-1:0] cur_token0_way;

    // Pipeline Registers cho Set Manager (Chỉ lưu trữ cờ thô)
    logic [N_WAY-1:0]    cur_set_valid;
    logic [N_WAY-1:0]    cur_set_dirty;
    logic [WAY_BITS-1:0] cur_raw_victim; // <-- THAY ĐỔI: Chốt cờ nạn nhân thô
    
    //Thanh ghi nội bộ hỗ trợ cờ Miễn Nhiễm
    logic [N_WAY-1:0] cur_immune_ways;
    logic [N_WAY-1:0] calculated_immunity;
    
    //Các biến hỗ trợ khối Codec
    logic [COMP_WIDTH-1:0] ddr_wr_k_enc, ddr_wr_v_enc;
    logic [COMP_WIDTH-1:0] ddr_rd_k_raw, ddr_rd_v_raw;
    logic [DK_WIDTH-1:0]   ddr_rd_k_dec;
    logic [DV_WIDTH-1:0]   ddr_rd_v_dec;
    
    logic enc_valid_in, enc_valid_out_k, enc_valid_out_v;
    logic dec_valid_in, dec_valid_out_k, dec_valid_out_v;
    logic [DK_WIDTH-1:0] evict_raw_k;
    logic [DV_WIDTH-1:0] evict_raw_v;
    
    // =========================================================
    // 1. MÁY TRẠNG THÁI VÀ MẠCH GHI BRAM
    // =========================================================
    typedef enum logic [3:0] {
        S_IDLE           = 4'd0,
        S_LOOKUP_READ    = 4'd1,
        S_LOOKUP_WAIT    = 4'd2,
        S_RD_RESP        = 4'd3,
        S_RD_REQ         = 4'd4,
        S_RD_WAIT        = 4'd5,
        S_RD_DEC_WAIT    = 4'd6,
        S_WR_UPDATE      = 4'd7,
        S_EVICT_READ     = 4'd8,
        S_EVICT_ENC_WAIT = 4'd9,
        S_EVICT_DDR_WAIT = 4'd10
    } state_t;
    state_t state, next_state;

    //Thanh ghi Max_Token
    logic [31:0] max_token_id;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            max_token_id <= '0;
        end else if (state == S_IDLE && op_valid) begin
            if (op_token_idx > max_token_id) begin
                max_token_id <= op_token_idx;
            end
        end
    end
    
    // =========================================================
    // 2. KHỞI TẠO BRAM VÀ ĐIỀU KHIỂN GHI (MẢNG 2 CHIỀU)
    // =========================================================
    logic [TAG_WIDTH-1:0]  rd_tag [0:N_WAY-1];
    logic [DATA_WIDTH-1:0] rd_data [0:N_WAY-1];
    logic [N_WAY-1:0]      wr_en_way;
    // Mux chọn dữ liệu ghi: từ DDR (sau khi giải mã) hoặc từ CPU (đã latch)
    logic [DATA_WIDTH-1:0] bram_wr_data;
    assign bram_wr_data = (state == S_RD_DEC_WAIT) ? {ddr_rd_k_dec, ddr_rd_v_dec} : {cur_k_reg, cur_v_reg};

    // Dùng generate để đúc 8 khối BRAM vật lý độc lập, lách luật 1.000.000 bit
    genvar w;
    generate
        for (w = 0; w < N_WAY; w++) begin : gen_bram_way
            (* ram_style = "block" *) logic [TAG_WIDTH-1:0]  tag_mem  [0:NUM_SET-1];
            (* ram_style = "block" *) logic [DATA_WIDTH-1:0] data_mem [0:NUM_SET-1];

            always_ff @(posedge clk) begin
                if (wr_en_way[w]) begin
                    tag_mem[cur_set_idx]  <= cur_tag;
                    data_mem[cur_set_idx] <= bram_wr_data;
                end
                rd_tag[w]  <= tag_mem[cur_set_idx];
                rd_data[w] <= data_mem[cur_set_idx];
            end
        end
    endgenerate

    // =========================================================
    // 3. KHỞI TẠO SET MANAGER (QUẢN LÝ PLRU & DIRTY BIT BÊN TRONG)
    // =========================================================
    logic [NUM_SET-1:0]  set_hit_en;
    logic [NUM_SET-1:0]  set_fill_en;
    logic [N_WAY-1:0]    set_valid_bits [NUM_SET];
    logic [WAY_BITS-1:0] set_raw_victim [NUM_SET]; // <-- THAY ĐỔI: Chứa cờ thô
    
    logic [NUM_SET-1:0]  set_dirty_en;
    logic [NUM_SET-1:0]  clear_dirty_en;
    logic [N_WAY-1:0]    set_dirty_bits [NUM_SET];
    
    logic [$clog2(N_WAY)-1:0] broadcast_hit_way;
    logic [$clog2(N_WAY)-1:0] broadcast_fill_way;
    logic [$clog2(N_WAY)-1:0] broadcast_dirty_way;

    genvar s;
    generate
        for (s = 0; s < NUM_SET; s++) begin : gen_set
            kv_cache_set #(
                .N_WAY(N_WAY)
            ) u_set (
                .clk           (clk),
                .rst_n         (rst_n),
                .algo_sel      (algo_sel),
                .hit_en        (set_hit_en[s]),
                .hit_way       (broadcast_hit_way),
                .fill_en       (set_fill_en[s]),
                .fill_way      (broadcast_fill_way),
                .valid_bits    (set_valid_bits[s]),
                .raw_victim    (set_raw_victim[s]), // <-- THAY ĐỔI: Kết nối MUX ra cờ thô
                .set_dirty_en  (set_dirty_en[s]),
                .clear_dirty_en(clear_dirty_en[s]),
                .dirty_way     (broadcast_dirty_way),
                .dirty_bits    (set_dirty_bits[s])
            );
        end
    endgenerate

    // =========================================================
    // 4. KHỞI TẠO CODEC PIPELINE BÊN TRONG
    // =========================================================
    kv_delta_codec u_codec_k (
        .clk           (clk),
        .rst_n         (rst_n),
        .enc_valid_in  (enc_valid_in),
        .raw_in        (evict_raw_k),
        .enc_valid_out (enc_valid_out_k),
        .encoded_out   (ddr_wr_k_enc),
        .dec_valid_in  (dec_valid_in),
        .encoded_in    (ddr_rd_k_raw),
        .dec_valid_out (dec_valid_out_k),
        .decoded_out   (ddr_rd_k_dec)
    );
    kv_delta_codec u_codec_v (
        .clk           (clk),
        .rst_n         (rst_n),
        .enc_valid_in  (enc_valid_in),
        .raw_in        (evict_raw_v),
        .enc_valid_out (enc_valid_out_v),
        .encoded_out   (ddr_wr_v_enc),
        .dec_valid_in  (dec_valid_in),
        .encoded_in    (ddr_rd_v_raw),
        .dec_valid_out (dec_valid_out_v),
        .decoded_out   (ddr_rd_v_dec)
    );
    assign ddr_wr_k = ddr_wr_k_enc;
    assign ddr_wr_v = ddr_wr_v_enc;
    assign ddr_rd_k_raw = ddr_rd_k;
    assign ddr_rd_v_raw = ddr_rd_v;

    // =========================================================
    // 5. MẠCH TỔ HỢP ĐỊNH TUYẾN ĐỊA CHỈ
    // =========================================================
    // === (Fibonacci hash) ===
    localparam logic [31:0] FIBO_CONST = 32'h9E3779B9;
    
    logic [31:0] linear_id;
    logic [31:0] linear_addr;
    logic [31:0] hash_product;
    logic [SET_BITS-1:0] hash_val;
    logic [$clog2(N_WAY)-1:0] token0_target_way;

    // linear_id: dùng riêng cho Locked Zone way routing
    assign linear_id = op_layer_id * runtime_num_head + op_head_id;
    assign token0_target_way = linear_id[$clog2(N_WAY)-1:0];
    
    // linear_addr: nối 3 trường thành 1 số tuyến tính làm input cho hash
    assign linear_addr  = {op_layer_id, op_head_id, op_token_idx};
    
    // Fibonacci hash: nhân với hằng số, lấy SET_BITS bit cao nhất
    assign hash_product = linear_addr * FIBO_CONST;
    assign hash_val     = hash_product[31 : 32-SET_BITS];

    // =========================================================
    // 6. MẠCH TỔ HỢP CỜ MIỄN NHIỄM VÀ HIT/MISS (BỘ NÃO MỚI)
    // =========================================================
    // 6A. Sinh cờ miễn nhiễm
    always_comb begin
        for (int w = 0; w < N_WAY; w++) begin
            logic [TOKEN_BITS-1:0] tag_token;
            tag_token = rd_tag[w][TOKEN_BITS-1:0];
            calculated_immunity[w] = cur_set_valid[w] && ((max_token_id - tag_token) <= local_window_size);
        end
        cur_immune_ways = immune_enable ? calculated_immunity : '0;
    end

    // 6B. Hit/Miss và Xác định Nạn nhân
    logic is_hit;
    logic [$clog2(N_WAY)-1:0] hit_way_idx;
    logic [DATA_WIDTH-1:0] hit_data, evict_data;
    logic [TAG_WIDTH-1:0]  evict_tag;

    // <-- THAY ĐỔI: Khai báo các biến phụ trợ tính toán Allocation tại đây
    logic [$clog2(N_WAY)-1:0] cur_set_alloc;
    logic [$clog2(N_WAY)-1:0] final_victim;
    logic [$clog2(N_WAY)-1:0] invalid_way;
    logic has_invalid;
    logic [N_WAY-1:0] masked_valid;
    
    always_comb begin
        // --- 1. TÌM INVALID WAY ---
        has_invalid = 1'b0;
        invalid_way = '0;
        masked_valid = cur_set_valid | ~active_way_mask;
        for (int i = 0; i < N_WAY; i++) begin
            if (!masked_valid[i]) begin 
                has_invalid = 1'b1;
                invalid_way = i[$clog2(N_WAY)-1:0];
                break;
            end
        end

        // --- 2. TÌM NẠN NHÂN (Bypass Immune & Mask) ---
        // Nếu tất cả Way đang mở đều bị khóa miễn nhiễm
        if (&(cur_immune_ways | ~active_way_mask)) begin
            final_victim = cur_raw_victim;
        end else begin
            final_victim = cur_raw_victim;
            for (int i = 0; i < N_WAY; i++) begin
                if (cur_immune_ways[final_victim] || !active_way_mask[final_victim]) begin
                    final_victim = final_victim + 1;
                end else begin
                    break;
                end
            end
        end

        // Chốt lại Way cấp phát (Biến tổ hợp này thay thế cho thanh ghi 28ns cũ)
        cur_set_alloc = has_invalid ? invalid_way : final_victim;

        // --- 3. KIỂM TRA HIT/MISS ---
        is_hit = 1'b0;
        hit_way_idx = '0;
        hit_data = rd_data[0];

        // Hit chỉ được công nhận nếu Way đó đang mở (active_way_mask)
        for (int w = 0; w < N_WAY; w++) begin
            if (cur_set_valid[w] && (rd_tag[w] == cur_tag) && active_way_mask[w]) begin
                is_hit = 1'b1;
                hit_way_idx = w[$clog2(N_WAY)-1:0];
                hit_data = rd_data[w];
            end
        end

        // Ưu tiên Token 0 (Locked Zone)
        if (cur_token_idx == 0 && locked_zone_enable) begin
            is_hit = 1'b1;
            hit_way_idx = cur_token0_way;
            hit_data = rd_data[cur_token0_way];
        end

        evict_data = rd_data[cur_set_alloc];
    end
    
    assign evict_raw_k = evict_data[DATA_WIDTH-1 : DV_WIDTH];
    assign evict_raw_v = evict_data[DV_WIDTH-1 : 0];
    assign evict_tag   = rd_tag[cur_set_alloc];

    // Truyền địa chỉ cho DDR
    assign ddr_rd_layer_id  = cur_layer_id;
    assign ddr_rd_head_id   = cur_head_id;
    assign ddr_rd_token_idx = cur_token_idx;

    // =========================================================
    // 7. CẬP NHẬT TRẠNG THÁI VÀ CHỐT DỮ LIỆU
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else state <= next_state;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_is_write  <= '0;
            cur_layer_id  <= '0; cur_head_id <= '0; cur_token_idx <= '0;
            cur_set_idx   <= '0; cur_tag <= '0;
            cur_k_reg     <= '0; cur_v_reg <= '0;
            cur_token0_way<= '0;
            cur_set_valid <= '0;
            cur_set_dirty <= '0;
            cur_raw_victim<= '0;
        end else if (state == S_IDLE && op_valid) begin
            cur_is_write   <= op_is_write;
            cur_layer_id   <= op_layer_id;
            cur_head_id    <= op_head_id;
            cur_token_idx  <= op_token_idx;
            cur_tag        <= {op_layer_id, op_head_id, op_token_idx};
            cur_k_reg      <= op_k;
            cur_v_reg      <= op_v;
            cur_token0_way <= token0_target_way;

            if (op_token_idx == 0 && locked_zone_enable) begin
                cur_set_idx <= linear_id[SET_BITS-1:0] >> $clog2(N_WAY);
            end else begin
                logic [SET_BITS-1:0] effective_bound;
                logic [SET_BITS-1:0] masked_hash;

                // Thu hẹp không gian bộ nhớ bằng mask
                masked_hash = hash_val & active_set_mask[SET_BITS-1:0];
                // Tịnh tiến Locked Zone trên không gian đã thu hẹp
                effective_bound = locked_zone_enable ? locked_sets_bound[SET_BITS-1:0] : '0;
                cur_set_idx <= (masked_hash < effective_bound) ? (masked_hash + effective_bound) : masked_hash;
            end
        end else if (state == S_LOOKUP_READ) begin
            // <-- THAY ĐỔI: Chốt dữ liệu cờ thô siêu tốc tại nhịp 1
            cur_set_valid  <= set_valid_bits[cur_set_idx];
            cur_set_dirty  <= set_dirty_bits[cur_set_idx];
            cur_raw_victim <= set_raw_victim[cur_set_idx]; 
        end
    end

    // =========================================================
    // 8. KHỐI ĐIỀU KHIỂN TỔ HỢP CHO FSM
    // =========================================================
    integer i;
    logic [$clog2(N_WAY)-1:0] final_wr_way;
    logic [$clog2(N_WAY)-1:0] target_way;

    always_comb begin
        next_state = state;
        op_ready   = 1'b0;
        resp_valid = 1'b0;
        resp_is_write = 1'b0;
        resp_hit   = 1'b0;
        resp_k     = cur_k_reg;
        resp_v     = cur_v_reg;
        
        ddr_rd_en = 1'b0;
        ddr_wr_en = 1'b0;
        ddr_wr_layer_id  = '0;
        ddr_wr_head_id   = '0;
        ddr_wr_token_idx = '0;

        wr_en_way = '0;
        enc_valid_in = 1'b0;
        dec_valid_in = 1'b0;

        final_wr_way = (cur_token_idx == 0 && locked_zone_enable) ? cur_token0_way : cur_set_alloc;

        // 1. Reset các cờ Enable (Vivado sinh logic cực nhẹ cho phép gán này)
        set_hit_en     = '0;
        set_fill_en    = '0;
        set_dirty_en   = '0;
        clear_dirty_en = '0;

        // 2. Cập nhật tín hiệu Broadcast
        broadcast_hit_way   = hit_way_idx;
        broadcast_fill_way  = final_wr_way;
        broadcast_dirty_way = '0; // Mặc định

        case (state)
            S_IDLE: begin
                op_ready = 1'b1;
                if (op_valid) next_state = S_LOOKUP_READ;
            end

            S_LOOKUP_READ: begin
                next_state = S_LOOKUP_WAIT;
            end

            S_LOOKUP_WAIT: begin
                if (is_hit) begin
                    next_state = cur_is_write ? S_WR_UPDATE : S_RD_RESP;
                end else begin
                    if (cur_set_dirty[cur_set_alloc]) begin
                        next_state = S_EVICT_READ;
                    end else begin
                        next_state = cur_is_write ? S_WR_UPDATE : S_RD_REQ;
                    end
                end
            end

            S_RD_RESP: begin
                set_hit_en[cur_set_idx]  = 1'b1;
                resp_valid    = 1'b1;
                resp_is_write = 1'b0;
                resp_hit      = 1'b1;
                resp_k        = hit_data[DATA_WIDTH-1 : DV_WIDTH];
                resp_v        = hit_data[DV_WIDTH-1 : 0];
                next_state    = S_IDLE;
            end

            S_WR_UPDATE: begin
                target_way = is_hit ? hit_way_idx : final_wr_way;
                
                wr_en_way[target_way] = 1'b1;

                set_dirty_en[cur_set_idx] = 1'b1;
                broadcast_dirty_way = target_way;

                if (is_hit) begin
                    set_hit_en[cur_set_idx]  = 1'b1;
                end else begin
                    set_fill_en[cur_set_idx]  = 1'b1;
                end
                
                resp_valid    = 1'b1;
                resp_is_write = 1'b1;
                resp_hit      = is_hit;
                next_state    = S_IDLE;
            end

            S_EVICT_READ: begin
                enc_valid_in = 1'b1;
                // Tạo xung kích hoạt 1 chu kỳ duy nhất
                next_state = S_EVICT_ENC_WAIT;
            end

            S_EVICT_ENC_WAIT: begin
                if (enc_valid_out_k) begin
                    ddr_wr_en = 1'b1;
                    ddr_wr_layer_id  = evict_tag[TAG_WIDTH-1 : HEAD_BITS+TOKEN_BITS];
                    ddr_wr_head_id   = evict_tag[HEAD_BITS+TOKEN_BITS-1 : TOKEN_BITS];
                    ddr_wr_token_idx = evict_tag[TOKEN_BITS-1 : 0];
                    next_state = S_EVICT_DDR_WAIT;
                end
            end
            
            S_EVICT_DDR_WAIT: begin
                if (ddr_ready) begin
                    if (cur_is_write) next_state = S_WR_UPDATE;
                    else next_state = S_RD_REQ;
                end
            end

            S_RD_REQ: begin
                ddr_rd_en = 1'b1;
                if (ddr_ready) begin
                    next_state = S_RD_WAIT;
                end
            end

            S_RD_WAIT: begin
                if (ddr_rd_valid) begin
                    dec_valid_in = 1'b1;
                    next_state = S_RD_DEC_WAIT;
                end
            end

            S_RD_DEC_WAIT: begin
                if (dec_valid_out_k) begin
                    wr_en_way[final_wr_way] = 1'b1;
                    set_fill_en[cur_set_idx]  = 1'b1;
                    broadcast_dirty_way = final_wr_way;
                    clear_dirty_en[cur_set_idx] = 1'b1;

                    resp_valid    = 1'b1;
                    resp_is_write = 1'b0;
                    resp_hit      = 1'b0;
                    resp_k        = ddr_rd_k_dec;
                    resp_v        = ddr_rd_v_dec;
                    
                    next_state    = S_IDLE;
                end
            end

            default: next_state = S_IDLE;
        endcase
    end

endmodule