/*
 * Copyright (c) 2026 Cristian Dinca
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module pio_core #(
    parameter USE_NEGEDGE = 0,
    parameter REGISTER_WIDTH = 64
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
    input  wire         gpio_value_in,
    input  wire [15:0]  gpio_pins_in
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

    // MARK: X register
    reg                                 x_we;
    reg  [REGISTER_WIDTH-1:0]           x_data_in;
    reg                                 x_shift;
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
        .shift_right(1'b0),
        .shift_count(shift_count),
        .data_in(x_data_in),
        .shift_in(shift_data),
        .data_out(x)
    );

    // MARK: Y register
    reg                                 y_we;
    reg  [REGISTER_WIDTH-1:0]           y_data_in;
    reg                                 y_shift;
    wire [REGISTER_WIDTH-1:0]           y;

    shift_register #(
        .WIDTH(REGISTER_WIDTH),
        .USE_NEGEDGE(USE_NEGEDGE)
    ) y_reg (
        .clk(clk),
        .rst(rst),
        .load(y_we),
        .shift(y_shift),
        .shift_right(1'b0),
        .shift_count(shift_count),
        .data_in(y_data_in),
        .shift_in(shift_data),
        .data_out(y)
    );

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

    // MARK: FIFO PUSH / PULL  Fields
    wire [1:0] fifo_opmode = instr[9:8]; // 00=PUSH, 01=PULL, 10=PUSH_IMM
    wire [2:0] fifo_register = instr[7:5];
    wire [2:0] fifo_byte_cnt = instr[4:2];
    wire [7:0] fifo_imm8 = instr[7:0];

    // byte count is encoded -1.
    wire [3:0] fifo_num_bytes = {1'b0, fifo_byte_cnt} + 4'd1;

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
    assign hold_pipeline = (delay_out != 0);

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
    assign set_reg_res = {{(REGISTER_WIDTH-8){1'b0}}, set_imm};

    // MARK: SRAM programming
    assign program_write_address = x[8:0];
    assign program_write_data = y[15:0];


    // MARK: Instruction decode & control logic
    always @(*) begin
        // Register defaults
        x_we      = 0;
        x_data_in = 0;
        x_shift   = 0;
        y_we      = 0;
        y_data_in = 0;
        y_shift   = 0;
        branch_taken = 0;
        switch_to_sramland = 0;
        program_write_enable = 0;
        side_pin_we = 0;
        gpio_en        = 0;
        gpio_op        = 0;
        gpio_pindir    = 0;
        gpio_pin       = 0;
        gpio_value_out = 0;
        jmp_set_pin    = 0;
        shift_count = 8;
        shift_data = {{(REGISTER_WIDTH-8){1'b0}}, instr[7:0]};
        mov_data = 0;

        if (!hold_pipeline) begin
            // instr[15] == 0 means JMP
            if (instr[15] == 1'b0) begin
                case (jmp_cond)
                    4'd0: begin // ALWAYS
                        branch_taken = 1'b1;
                        // pc_load      = 1'b1;
                        // pc_load_addr = jmp_addr;
                    end

                    4'd1: begin // X == 0
                        if (x == 0) begin
                            branch_taken = 1'b1;
                            // pc_load      = 1'b1;
                            // pc_load_addr = jmp_addr;
                        end
                    end

                    4'd2: begin // X != 0
                        if (x != 0) begin
                            branch_taken = 1'b1;
                            // pc_load      = 1'b1;
                            // pc_load_addr = jmp_addr;
                        end
                    end

                    4'd3: begin // X-- != 0
                        if (x != 0) begin
                            branch_taken = 1'b1;
                            x_we         = 1'b1;
                            x_data_in    = x_minus_1;
                            // pc_load      = 1'b1;
                            // pc_load_addr = jmp_addr;
                        end
                    end

                    4'd4: begin // Y == 0
                        if (y == 0) begin
                            branch_taken = 1'b1;
                            // pc_load      = 1'b1;
                            // pc_load_addr = jmp_addr;
                        end
                    end

                    4'd5: begin // Y != 0
                        if (y != 0) begin
                            branch_taken = 1'b1;
                            // pc_load      = 1'b1;
                            // pc_load_addr = jmp_addr;
                        end
                    end

                    4'd6: begin // Y-- != 0
                        if (y != 0) begin
                            branch_taken = 1'b1;
                            y_we         = 1'b1;
                            y_data_in    = y_minus_1;
                            // pc_load      = 1'b1;
                            // pc_load_addr = jmp_addr;
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

                    default: begin
                    end
                endcase
            end else begin
                // Non-JMP
                case (op)
                    3'b000: begin  // FIFO operations (PUSH/PULL)
                        case (fifo_opmode)
                            2'b00: begin
                                // push
                            end

                            2'b01: begin
                                // pull
                            end

                            2'b10: begin
                                // push 1-byte immediate
                            end

                            2'b11: begin
                                // N/A
                            end
                        endcase
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

                    3'b101: begin // MOV
                        case (mov_src)
                            2'b00: begin // X
                                mov_data = x;
                            end

                            2'b01: begin // Y
                                mov_data = y;
                            end

                            2'b10: begin // PIN n
                                gpio_pin = instr[3:0];
                                mov_data = {{(REGISTER_WIDTH-1){1'b0}}, gpio_value_in};
                            end

                            2'b11: begin // PINS (all)
                                mov_data = {{(REGISTER_WIDTH-16){1'b0}}, gpio_pins_in};
                            end
                        endcase

                        case (mov_dst)
                            2'b00: begin
                                x_data_in = mov_data;
                                x_we = 1'b1;
                            end

                            2'b01: begin
                                y_data_in = mov_data;
                                y_we = 1'b1;
                            end

                            default: begin
                                // nothing for now
                            end
                        endcase
                    end

                    3'b110: begin // NOP
                        // Wait for 1 instruction, plus an additional
                        // number of encoded instructions called "delay".
                    end

                    3'b111: begin // EXT
                        case (instr[9:8])
                            2'b00: begin // Control operations
                                casez (instr[7:0])
                                    8'd0: begin // Exit BootROM
                                        switch_to_sramland = 1'b1;
                                    end

                                    8'd1: begin // SRAM_WRITE
                                        program_write_enable = 1'b1;
                                    end

                                    8'b0001_????: begin // SHIFT_IN X, PIN
                                        gpio_pin = instr[3:0];
                                        shift_count = 1;
                                        shift_data = {{(REGISTER_WIDTH-1){1'b0}}, gpio_value_in};
                                        x_shift = 1'b1;
                                    end

                                    8'b0010_????: begin // SHIFT_IN Y, PIN
                                        gpio_pin = instr[3:0];
                                        shift_count = 1;
                                        shift_data = {{(REGISTER_WIDTH-1){1'b0}}, gpio_value_in};
                                        y_shift = 1'b1;
                                    end

                                    default: begin
                                    end
                                endcase
                            end

                            2'b01: begin // SHIFT_IN X
                                x_shift = 1'b1;
                            end

                            2'b10: begin // SHIFT_IN Y
                                y_shift = 1'b1;
                            end

                            2'b11: begin // SET SIDESET pin_no
                                side_pin_we = 1'b1;
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
