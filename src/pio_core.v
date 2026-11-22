/*
 * Copyright (c) 2026 Cristian Dinca
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module pio_core #(
    parameter USE_NEGEDGE = 0,
    parameter REGISTER_WIDTH = 32
)(
    input  wire         clk,
    input  wire         rst,

    input  wire [15:0]  instr,
    output reg          branch_taken,
    output wire         hold_pipeline,
    output reg          switch_to_sramland,

    output reg          program_write_enable,
    output wire [8:0]   program_write_address,
    output wire [15:0]  program_write_data,

    output wire         gpio_side_set_en,
    output wire         gpio_side_set_value,
    output reg  [3:0]   gpio_side_set_pin,
    
    output reg          gpio_en,
    output reg  [2:0]   gpio_op,
    output reg          gpio_pindir,
    output reg  [3:0]   gpio_pin,
    output reg          gpio_value_out,
    output reg  [15:0]  gpio_multi_mask,
    output reg  [15:0]  gpio_multi_value_out,
    output reg  [15:0]  gpio_sync_bypass,
    input  wire         gpio_value_in,
    input  wire [15:0]  gpio_pins_in,

    input  wire [REGISTER_WIDTH-1:0] rx_fifo_data,
    input  wire        rx_fifo_can_pull,
    output reg         rx_fifo_pull,
    output reg  [2:0]  rx_fifo_bytes_cnt,

    output reg  [REGISTER_WIDTH-1:0] tx_fifo_data,
    input  wire        tx_fifo_can_push,
    output reg         tx_fifo_push,
    output reg  [2:0]  tx_fifo_bytes_cnt
);
    // MARK: Side-set
    assign gpio_side_set_en = instr[14] && !hold_pipeline && !rst;
    assign gpio_side_set_value = instr[13];
    reg side_pin_we;

    // Side set pin register
    generate
        if (USE_NEGEDGE) begin: sideset_negedge
            always @(negedge clk) begin
                if (rst)
                    gpio_side_set_pin <= 4'd0;
                else if (side_pin_we)
                    gpio_side_set_pin <= instr[3:0];
            end
        end else begin: sideset_posedge
            always @(posedge clk) begin
                if (rst)
                    gpio_side_set_pin <= 4'd0;
                else if (side_pin_we)
                    gpio_side_set_pin <= instr[3:0];
            end
        end
    endgenerate


    // MARK: Shared shift control
    reg       shift_en;
    reg       shift_right;
    reg [1:0] shift_dst;

    wire x_shift = shift_en && (shift_dst == 2'b00);
    wire y_shift = shift_en && (shift_dst == 2'b01);
    wire a_shift = shift_en && (shift_dst == 2'b10);
    wire b_shift = shift_en && (shift_dst == 2'b11);


    // MARK: X register
    reg                                 x_we;
    reg  [REGISTER_WIDTH-1:0]           x_data_in;
    wire [REGISTER_WIDTH-1:0]           x;
    reg  [$clog2(REGISTER_WIDTH)-1:0]   shift_count;
    reg  [REGISTER_WIDTH-1:0]           shift_data;

    shift_register #(
        .WIDTH(REGISTER_WIDTH),
        .USE_NEGEDGE(USE_NEGEDGE)
    ) x_reg (
        .clk(clk),
        .rst(rst),
        .load(x_we),
        .shift(x_shift),
        .shift_right(shift_right),
        .shift_count(shift_count),
        .data_in(x_data_in),
        .shift_in(shift_data),
        .data_out(x)
    );

    // MARK: Y register
    reg                                 y_we;
    reg  [REGISTER_WIDTH-1:0]           y_data_in;
    wire [REGISTER_WIDTH-1:0]           y;

    shift_register #(
        .WIDTH(REGISTER_WIDTH),
        .USE_NEGEDGE(USE_NEGEDGE)
    ) y_reg (
        .clk(clk),
        .rst(rst),
        .load(y_we),
        .shift(y_shift),
        .shift_right(shift_right),
        .shift_count(shift_count),
        .data_in(y_data_in),
        .shift_in(shift_data),
        .data_out(y)
    );


    // MARK: A register
    reg                       a_we;
    reg  [REGISTER_WIDTH-1:0] a_data_in;
    wire [REGISTER_WIDTH-1:0] a;

    shift_register #(
        .WIDTH(REGISTER_WIDTH),
        .USE_NEGEDGE(USE_NEGEDGE)
    ) a_reg (
        .clk(clk),
        .rst(rst),
        .load(a_we),
        .shift(a_shift),
        .shift_right(shift_right),
        .shift_count(shift_count),
        .data_in(a_data_in),
        .shift_in(shift_data),
        .data_out(a)
    );

    // MARK: B register
    reg                       b_we;
    reg  [REGISTER_WIDTH-1:0] b_data_in;
    wire [REGISTER_WIDTH-1:0] b;

    shift_register #(
        .WIDTH(REGISTER_WIDTH),
        .USE_NEGEDGE(USE_NEGEDGE)
    ) b_reg (
        .clk(clk),
        .rst(rst),
        .load(b_we),
        .shift(b_shift),
        .shift_right(shift_right),
        .shift_count(shift_count),
        .data_in(b_data_in),
        .shift_in(shift_data),
        .data_out(b)
    );


    // MARK: Shared register read interface
    // X=0, Y=1, A=2, B=3
    wire [REGISTER_WIDTH-1:0] reg_value [0:3];
    assign reg_value[0] = x;
    assign reg_value[1] = y;
    assign reg_value[2] = a;
    assign reg_value[3] = b;

    // Register used by SHR_OUT / SHL_OUT
    wire [REGISTER_WIDTH-1:0] expanded_shift_source = reg_value[instr[5:4]];

    // Mask register for OUT PINS / OUT DIRS
    // Uses register selector bits [3:2]
    wire [REGISTER_WIDTH-1:0] gpio_mask_source = reg_value[instr[3:2]];

    // Source register for SHR_OUT / SHL_OUT to DIR
    // These instructions encode the register in bits [6:5]
    wire [REGISTER_WIDTH-1:0] gpio_dir_shift_source = reg_value[instr[6:5]];


    // MARK: Clocked event interface
    reg  edge_clock_we;
    reg  sync_mask_we;
    wire event_stall;

    // Debug-visible mirrors for existing testbenches (no additional flops)
    wire [3:0] edge_clock_pin;
    wire       event_armed;

    // The WAIT/edge-shift state machine and EDGECLK register module
    clocked_event_engine #(
        .USE_NEGEDGE(USE_NEGEDGE)
    ) event_engine (
        .clk(clk),
        .rst(rst),
        .instr(instr),
        .sampled_pins(gpio_pins_in),
        .edge_clock_we(edge_clock_we),
        .other_stall((delay_out != 0) || fifo_stall),
        .event_stall(event_stall),
        .edge_clock_pin(edge_clock_pin),
        .event_armed(event_armed)
    );

    // The synchronizer selector configures GPIO input sampling, not edge
    // detection, so its register remains owned by the PIO core.
    wire [REGISTER_WIDTH-1:0] sync_mask_value = reg_value[instr[1:0]];
    generate
        if (USE_NEGEDGE) begin : gpio_sync_negedge
            always @(negedge clk) begin
                if (rst)
                    gpio_sync_bypass <= 16'h0000;
                else if (sync_mask_we)
                    gpio_sync_bypass <= sync_mask_value[15:0];
            end
        end else begin : gpio_sync_posedge
            always @(posedge clk) begin
                if (rst)
                    gpio_sync_bypass <= 16'h0000;
                else if (sync_mask_we)
                    gpio_sync_bypass <= sync_mask_value[15:0];
            end
        end
    endgenerate


    // MARK: JMP fields
    wire [3:0] jmp_cond;
    wire [8:0] jmp_addr;

    assign jmp_cond = instr[12:9];
    assign jmp_addr = instr[8:0];

    // Pin used in JMP PIN (set using SET JMPPIN pin_no)
    reg jmp_set_pin;
    reg [3:0] jmp_pin;
    always @(posedge clk) begin
        if (rst)
            jmp_pin <= 4'b0;
        else if (jmp_set_pin)
            jmp_pin <= instr[3:0];
    end

    // MARK: Non-JMP fields
    wire [2:0] op;
    assign op = instr[12:10];

    // MARK: SET fields
    wire [1:0]  set_dst;
    wire [7:0]  set_imm;
    wire [REGISTER_WIDTH-1:0] set_reg_res;
    wire [3:0]  setpin_num;
    wire        setpin_val;
    wire        setpin_type;

    assign set_dst = instr[9:8];
    assign set_imm = instr[7:0];

    assign setpin_type = instr[1]; // pin or pindir
    assign setpin_num = instr[7:4];
    assign setpin_val = instr[0];

    // MARK: FIFO PUSH / PULL Fields
    wire [1:0] fifo_opmode = instr[9:8];    // 00=PUSH, 01=PULL, 10=PUSH_IMM
    wire [2:0] fifo_register = instr[7:5];  
    wire [1:0] fifo_byte_cnt = instr[3:2];
    wire [7:0] fifo_imm8 = instr[7:0];

    wire is_fifo = instr[15] && (op == 3'b000);
    // Only X/Y/A/B are valid FIFO register operands.
    // Bits 4 and 1:0 are reserved and must be zero.
    wire fifo_reg_valid =
        (fifo_register <= 3'd3) &&
        (instr[4] == 1'b0) &&
        (instr[1:0] == 2'b00);


    wire fifo_stall = is_fifo &&
                    (
                        // PUSH X/Y
                        ((fifo_opmode == 2'b00) &&
                        fifo_reg_valid &&
                        !tx_fifo_can_push) ||

                        // PULL X/Y
                        ((fifo_opmode == 2'b01) &&
                        fifo_reg_valid &&
                        !rx_fifo_can_pull) ||

                        // PUSH immediate
                        ((fifo_opmode == 2'b10) &&
                        !tx_fifo_can_push)
                    );

    // byte count is encoded -1.
    wire [2:0] fifo_num_bytes = {1'b0, fifo_byte_cnt} + 3'd1;

    // MARK: FIFO pull byte masking
    wire [31:0] fifo_pull_mask =
        (fifo_num_bytes == 3'd1) ? 32'h000000FF :
        (fifo_num_bytes == 3'd2) ? 32'h0000FFFF :
        (fifo_num_bytes == 3'd3) ? 32'h00FFFFFF :
                                   32'hFFFFFFFF;
    wire [REGISTER_WIDTH-1:0] fifo_pull_data = rx_fifo_data & fifo_pull_mask;


    // MARK: MOV fields
    wire [1:0] mov_dst = instr[9:8];
    wire [1:0] mov_src = instr[7:6];

    reg [REGISTER_WIDTH-1:0] mov_data;

    // MARK: NOP Delay
    wire [9:0] instr_delay;
    wire [9:0] delay_out;
    wire delay_load;
    // is this a delay instruction?
    wire is_delay = instr[15] == 1'b1 && (op == 3'b110);

    assign instr_delay = instr[9:0];
    // if this is a delay instruction, load the counter,
    // but only if it isn't already loaded
    assign delay_load = is_delay && (delay_out == 0);
    assign hold_pipeline = (delay_out != 0) || fifo_stall || event_stall;

    delay_counter #(
        .USE_NEGEDGE(USE_NEGEDGE)
    ) delay_cnt (
        .clk(clk),
        .rst(rst),
        .load(delay_load),
        .dec(1'b1),
        .data_in(instr_delay),
        .data_out(delay_out)
    );


    // MARK: DATAPATH
    wire [REGISTER_WIDTH-1:0] x_minus_1 = x - 1;
    wire [REGISTER_WIDTH-1:0] y_minus_1 = y - 1;
    wire [REGISTER_WIDTH-1:0] a_minus_1 = a - 1'b1;
    wire [REGISTER_WIDTH-1:0] b_minus_1 = b - 1'b1;
    assign set_reg_res = {{(REGISTER_WIDTH-8){1'b0}}, set_imm};



    // MARK: SRAM programming

    // SRAM_WRITE ADDRREG, DATAREG
    // Encoding: 0x9C30 | (addr_reg << 2) | data_reg
    // Address uses bits [8:0] of ADDRREG
    // Data uses bits [15:0] of DATAREG
    wire [1:0] sram_addr_sel = instr[3:2];
    wire [1:0] sram_data_sel = instr[1:0];
    wire [REGISTER_WIDTH-1:0] sram_addr_value = reg_value[sram_addr_sel];
    wire [REGISTER_WIDTH-1:0] sram_data_value = reg_value[sram_data_sel];

    assign program_write_address = sram_addr_value[8:0];
    assign program_write_data = sram_data_value[15:0];


    // MARK: Instruction decode & control logic
    always @(*) begin
        // Register defaults
        
        // X register
        x_we          = 1'b0;
        x_data_in     = {REGISTER_WIDTH{1'b0}};

        // Y register
        y_we          = 1'b0;
        y_data_in     = {REGISTER_WIDTH{1'b0}};

        // A register
        a_we          = 1'b0;
        a_data_in     = {REGISTER_WIDTH{1'b0}};

        // B register
        b_we          = 1'b0;
        b_data_in     = {REGISTER_WIDTH{1'b0}};

        branch_taken = 0;
        switch_to_sramland = 0;
        program_write_enable = 0;
        side_pin_we = 0;
        gpio_en        = 0;
        gpio_op        = 0;
        gpio_pindir    = 0;
        gpio_pin       = 0;
        gpio_value_out = 0;

        // Default mask must be all ones.
        // gpio.v also uses this mask for MOV R, PINS input snapshots.
        gpio_multi_mask = 16'hFFFF;
        gpio_multi_value_out = 16'h0000;

        jmp_set_pin    = 0;
        edge_clock_we = 1'b0;
        sync_mask_we  = 1'b0;
        shift_count = 8;
        shift_data = {{(REGISTER_WIDTH-8){1'b0}}, instr[7:0]};
        mov_data = 0;

        // Shared shift defaults
        shift_en    = 1'b0;
        shift_right = 1'b0;
        shift_dst   = 2'b00;

        // Fifo
        tx_fifo_push  = 1'b0;
        tx_fifo_data = {REGISTER_WIDTH{1'b0}};
        tx_fifo_bytes_cnt = (fifo_opmode == 2'b10) ? 3'd1 : fifo_num_bytes;
        rx_fifo_pull  = 1'b0;
        rx_fifo_bytes_cnt = fifo_num_bytes;

        if (!hold_pipeline && !rst) begin
            // instr[15] == 0 means JMP
            if (instr[15] == 1'b0) begin
                case (jmp_cond)
                    4'd0: begin // ALWAYS
                        branch_taken = 1'b1;
                    end

                    4'd1: begin // X == 0
                        if (x == 0) begin
                            branch_taken = 1'b1;
                        end
                    end

                    4'd2: begin // X != 0
                        if (x != 0) begin
                            branch_taken = 1'b1;
                        end
                    end

                    4'd3: begin // X-- != 0
                        if (x != 0) begin
                            branch_taken = 1'b1;
                            x_we         = 1'b1;
                            x_data_in    = x_minus_1;
                        end
                    end

                    4'd4: begin // Y == 0
                        if (y == 0) begin
                            branch_taken = 1'b1;
                        end
                    end

                    4'd5: begin // Y != 0
                        if (y != 0) begin
                            branch_taken = 1'b1;
                        end
                    end

                    4'd6: begin // Y-- != 0
                        if (y != 0) begin
                            branch_taken = 1'b1;
                            y_we         = 1'b1;
                            y_data_in    = y_minus_1;
                        end
                    end

                    4'd7: begin // PIN == 1
                        gpio_pin = jmp_pin;
                        if (gpio_value_in) begin
                            branch_taken = 1'b1;
                        end
                    end

                    4'd8: begin // PIN == 0
                        gpio_pin = jmp_pin;
                        if (!gpio_value_in) begin
                            branch_taken = 1'b1;
                        end
                    end

                    4'd9: begin //  A == 0
                        if (a == 0)
                            branch_taken = 1'b1;
                    end

                    4'd10: begin // A != 0
                        if (a != 0)
                            branch_taken = 1'b1;
                    end

                    4'd11: begin // A-- != 0
                        if (a != 0) begin
                            branch_taken = 1'b1;
                            a_we = 1'b1;
                            a_data_in = a_minus_1;
                        end
                    end

                    4'd12: begin // B == 0
                        if (b == 0)
                            branch_taken = 1'b1;
                    end

                    4'd13: begin // B != 0
                        if (b != 0)
                            branch_taken = 1'b1;
                    end

                    4'd14: begin // B-- != 0
                        if (b != 0) begin
                            branch_taken = 1'b1;
                            b_we = 1'b1;
                            b_data_in = b_minus_1;
                        end
                    end

                    default: begin
                    end
                endcase
            end else begin
                // Non-JMP
                case (op)

                    3'b000: begin // FIFO operations
                        case (fifo_opmode)
                            2'b00: begin // PUSH R, n
                                if (fifo_reg_valid) begin
                                    tx_fifo_data = reg_value[fifo_register[1:0]];
                                    tx_fifo_push = 1'b1;
                                end
                            end

                            2'b01: begin // PULL R, n
                                if (fifo_reg_valid) begin
                                    rx_fifo_pull = 1'b1;

                                    case (fifo_register[1:0])
                                        2'b00: begin // X
                                            x_we = 1'b1;
                                            x_data_in = fifo_pull_data;
                                        end

                                        2'b01: begin // Y
                                            y_we = 1'b1;
                                            y_data_in = fifo_pull_data;
                                        end

                                        2'b10: begin // A
                                            a_we = 1'b1;
                                            a_data_in = fifo_pull_data;
                                        end

                                        2'b11: begin // B
                                            b_we = 1'b1;
                                            b_data_in = fifo_pull_data;
                                        end
                                    endcase
                                end
                            end

                            2'b10: begin // PUSH_IMM imm8
                                tx_fifo_data = {
                                    {(REGISTER_WIDTH-8){1'b0}},
                                    fifo_imm8
                                };
                                tx_fifo_push = 1'b1;
                            end

                            // Reserved
                            default: begin
                            end
                        endcase
                    end

                    3'b001: begin // A / B register operations
                        if (instr[9]) begin // SET A / SET B
                            if (instr[8] == 1'b0) begin
                                a_we = 1'b1;
                                a_data_in = {
                                    {(REGISTER_WIDTH-8){1'b0}},
                                    instr[7:0]
                                };
                            end else begin
                                b_we = 1'b1;
                                b_data_in = {
                                    {(REGISTER_WIDTH-8){1'b0}},
                                    instr[7:0]
                                };
                            end
                        end else begin
                            case (instr[8:6])

                                3'b000: begin // MOV / parallel GPIO
                                    case (instr[1:0])
                                        2'b00: begin // MOV rd, rs
                                            mov_data = gpio_mask_source;

                                            case (instr[5:4])
                                                2'b00: begin // X
                                                    x_we = 1'b1;
                                                    x_data_in = mov_data;
                                                end

                                                2'b01: begin // Y
                                                    y_we = 1'b1;
                                                    y_data_in = mov_data;
                                                end

                                                2'b10: begin // A
                                                    a_we = 1'b1;
                                                    a_data_in = mov_data;
                                                end

                                                2'b11: begin // B
                                                    b_we = 1'b1;
                                                    b_data_in = mov_data;
                                                end
                                            endcase
                                        end

                                        2'b01: begin // OUT PINS, VALUE_REG, MASK_REG
                                            gpio_en = 1'b1;
                                            gpio_op = 3'd3; // SETMULTI

                                            gpio_multi_value_out = expanded_shift_source[15:0];
                                            gpio_multi_mask = gpio_mask_source[15:0];
                                        end

                                        2'b10: begin // OUT DIRS, VALUE_REG, MASK_REG
                                            gpio_en = 1'b1;
                                            gpio_op = 3'd4; // SETDIRMULTI

                                            gpio_multi_value_out = expanded_shift_source[15:0];
                                            gpio_multi_mask = gpio_mask_source[15:0];
                                        end

                                        default: begin
                                        end
                                    endcase
                                end


                                // INC / DEC
                                3'b001: begin
                                    // Bits 2:0 must be zero.
                                    // Bit 3 selects INC or DEC.
                                    if (instr[2:0] == 3'b000) begin // INC or DEC
                                        case (instr[5:4]) // target register
                                            2'b00: begin  // X
                                                x_we = 1'b1;
                                                x_data_in = instr[3]
                                                          ? x - 1'b1 : x + 1'b1;
                                            end

                                            2'b01: begin // Y
                                                y_we = 1'b1;
                                                y_data_in = instr[3]
                                                          ? y - 1'b1 : y + 1'b1;
                                            end

                                            2'b10: begin // A
                                                a_we = 1'b1;
                                                a_data_in = instr[3]
                                                          ? a - 1'b1 : a + 1'b1;
                                            end

                                            2'b11: begin // B
                                                b_we = 1'b1;
                                                b_data_in = instr[3]
                                                          ? b - 1'b1 : b + 1'b1;
                                            end
                                        endcase
                                    end
                                end


                                3'b010: begin // SHL_IN R, PIN n
                                    // R = (R << 1) | sampled_pin
                                    shift_en = 1'b1;
                                    shift_dst = instr[5:4];

                                    gpio_pin = instr[3:0];

                                    shift_count = 5'd1;
                                    shift_data = {
                                        {(REGISTER_WIDTH-1){1'b0}},
                                        gpio_value_in
                                    };
                                end

                                3'b011: begin // SHR_IN R, PIN n
                                    // Shift right and insert pin at bit 31
                                    shift_en = 1'b1;
                                    shift_right = 1'b1;
                                    shift_dst = instr[5:4];

                                    gpio_pin = instr[3:0];

                                    shift_count = 5'd1;
                                    shift_data = {
                                        {(REGISTER_WIDTH-1){1'b0}},
                                        gpio_value_in
                                    };
                                end

                                3'b100: begin // SHR_OUT R, PIN n
                                    // Output OLD bit 0, then shift right
                                    shift_en = 1'b1;
                                    shift_right = 1'b1;
                                    shift_dst = instr[5:4];

                                    gpio_en = 1'b1;
                                    gpio_op = 3'd2; // SET PIN
                                    gpio_pin = instr[3:0];
                                    gpio_value_out = expanded_shift_source[0];

                                    shift_count = 5'd1;
                                    shift_data = {REGISTER_WIDTH{1'b0}};
                                end

                                3'b101: begin // SHL_OUT R, PIN n
                                    // Output OLD bit 31, then shift left
                                    shift_en = 1'b1;
                                    shift_dst = instr[5:4];

                                    gpio_en = 1'b1;
                                    gpio_op = 3'd2; // SET PIN
                                    gpio_pin = instr[3:0];
                                    gpio_value_out = expanded_shift_source[REGISTER_WIDTH-1];

                                    shift_count = 5'd1;
                                    shift_data = {REGISTER_WIDTH{1'b0}};
                                end

                                3'b110: begin // SHL R, n
                                    // n = 1..16; logical zero-fill
                                    shift_en = 1'b1;
                                    shift_dst = instr[5:4];

                                    shift_count = {1'b0, instr[3:0]} + 5'd1;
                                    shift_data = {REGISTER_WIDTH{1'b0}};
                                end

                                3'b111: begin // SHR R, n
                                    // n = 1..16; logical zero-fill
                                    shift_en = 1'b1;
                                    shift_right = 1'b1;
                                    shift_dst = instr[5:4];

                                    shift_count =
                                        {1'b0, instr[3:0]} + 5'd1;

                                    shift_data = {REGISTER_WIDTH{1'b0}};
                                end

                            endcase
                        end
                    end


                    3'b010: begin // SHL_IN R, imm8
                        // Shift left by 8 and insert imm8 at bits 7:0
                        shift_en = 1'b1;
                        shift_dst = instr[9:8];

                        shift_count = 5'd8;
                        shift_data = {
                            {(REGISTER_WIDTH-8){1'b0}},
                            instr[7:0]
                        };
                    end

                    3'b011: begin // SHR_IN R, imm8
                        // Shift right by 8 and insert imm8 at bits 31:24
                        shift_en = 1'b1;
                        shift_right = 1'b1;
                        shift_dst = instr[9:8];

                        shift_count = 5'd8;
                        shift_data = {
                            {(REGISTER_WIDTH-8){1'b0}},
                            instr[7:0]
                        };
                    end

                    3'b100: begin // SET
                        case (set_dst)
                            2'b00: begin // X
                                x_we      = 1'b1;
                                x_data_in = set_reg_res;
                            end

                            2'b01: begin // Y
                                y_we      = 1'b1;
                                y_data_in = set_reg_res;
                            end

                            2'b10: begin // PIN
                                case (setpin_type)
                                    1'b1: begin
                                        gpio_op = 3'd1; // SETDIR
                                        gpio_pindir = setpin_val;
                                    end
                                    1'b0: begin
                                        gpio_op = 3'd2; // SET
                                        gpio_value_out = setpin_val;
                                    end
                                endcase
                                gpio_pin = setpin_num;
                                gpio_en = 1'b1;
                            end

                            2'b11: begin // JMP_PIN
                                jmp_set_pin = 1'b1;
                            end

                            default: begin
                            end
                        endcase
                    end

                    3'b101: begin // MOV from GPIO only
                        // Register-to-register MOV uses opcode 001.
                        // Only PIN and PINS are valid sources here.

                        if (mov_src == 2'b10 ||
                            mov_src == 2'b11) begin

                            case (mov_src)
                                2'b10: begin // PIN n
                                    gpio_pin = instr[3:0];
                                    mov_data = {
                                        {(REGISTER_WIDTH-1){1'b0}},
                                        gpio_value_in
                                    };
                                end

                                2'b11: begin // PINS
                                    mov_data = {
                                        {(REGISTER_WIDTH-16){1'b0}},
                                        gpio_pins_in
                                    };
                                end

                                default: begin
                                end
                            endcase

                            // Destination: X, Y, A or B
                            case (mov_dst)
                                2'b00: begin // X
                                    x_we = 1'b1;
                                    x_data_in = mov_data;
                                end

                                2'b01: begin // Y
                                    y_we = 1'b1;
                                    y_data_in = mov_data;
                                end

                                2'b10: begin // A
                                    a_we = 1'b1;
                                    a_data_in = mov_data;
                                end

                                2'b11: begin // A
                                    b_we = 1'b1;
                                    b_data_in = mov_data;
                                end
                            endcase
                        end
                    end

                    3'b110: begin // NOP
                        // Wait for 1 instruction, plus an additional
                        // number of encoded instructions called "delay".
                    end

                    3'b111: begin // EXT
                        case (instr[9:8])
                            2'b00: begin // Control operations
                                casez (instr[7:0])
                                    8'h00: begin // ENTER_SRAM
                                        switch_to_sramland = 1'b1;
                                    end

                                    // SRAM_WRITE ADDRREG, DATAREG
                                    8'b0011_????: begin
                                        program_write_enable = 1'b1;
                                    end

                                    // SET EDGECLK, pin
                                    8'b0100_????: begin
                                        edge_clock_we = 1'b1;
                                    end

                                    // SYNC_BYPASS X/Y/A/B
                                    8'b0101_00??: begin
                                        sync_mask_we = 1'b1;
                                    end

                                    default: begin
                                    end
                                endcase
                            end

                            2'b01: begin // WAIT
                                // WAIT fot pin level or fresh edge.
                                // event_stall is outside this decoder, so the
                                // instruction advances only on satisfaction
                             end

                             // 0x9E00..0x9EFF: edge capture + shift on same
                             // accepting clock edge
                             2'b10: begin // SHIFT_IN_EDGE / SHR_IN_EDGE
                                 shift_en = 1'b1;
                                 shift_right = instr[7];
                                 shift_dst = instr[5:4];
                                 shift_count = 5'd1;
                                 shift_data = {
                                     {(REGISTER_WIDTH-1){1'b0}},
                                     gpio_pins_in[instr[3:0]]
                                 };
                             end

                             2'b11: begin // SIDEPIN / direction shifts
                                // 0x9F80 - 0x9FFF
                                // SHR_OUT / SHL_OUT R, DIR n [, INV]
                                if (instr[7]) begin
                                    // Write GPIO output enable
                                    gpio_en = 1'b1;
                                    gpio_op = 3'd1; // SETDIR

                                    // Direction pins are only 0..7
                                    gpio_pin = {1'b0, instr[2:0]};

                                    // Bit 4: 0 = SHR, 1 = SHL
                                    // Bit 3: invert the outgoing bit
                                    gpio_pindir = (
                                        instr[4]
                                            ? gpio_dir_shift_source[REGISTER_WIDTH-1]
                                            : gpio_dir_shift_source[0]
                                    ) ^ instr[3];

                                    // Shift the selected source register
                                    // at the same clock edge
                                    shift_en = 1'b1;
                                    shift_dst = instr[6:5];
                                    shift_right = ~instr[4];

                                    shift_count = 5'd1;
                                    shift_data = {REGISTER_WIDTH{1'b0}};

                                end else if (instr[7:4] == 4'b0000) begin
                                    // 0x9F00 - 0x9F0F: SET SIDEPIN
                                    side_pin_we = 1'b1;
                                end
                            end


                            default: begin
                            end
                        endcase
                    end

                    default: begin
                    end
                endcase
            end
        end
    end

endmodule

`default_nettype wire
