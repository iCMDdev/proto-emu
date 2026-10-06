/*
 * Copyright (c) 2026 Cristian Dinca 
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module pio_core #(
    parameter USE_NEGEDGE = 1
)(
    input  wire         clk,
    input  wire         rst,

    input  wire [15:0]  instr,
    output wire [8:0]   pc
);
    // MARK: Side-set flags
    wire side_en;
    wire side_val;
    
    assign side_en = instr[14];
    assign side_val = instr[13];

    // MARK: Program Counter
    reg halt;
    reg pc_load;
    wire pc_inc;
    reg [8:0] pc_load_addr;    

    assign pc_inc = !pc_load & !halt;

    pc_register #(
        .USE_NEGEDGE(USE_NEGEDGE)
    ) pc_reg (
        .clk(clk),
        .rst(rst),
        .load(pc_load),
        .inc(pc_inc),
        .data_in(pc_load_addr),
        .data_out(pc)
    );

    // MARK: X register
    reg         x_we;
    reg  [15:0] x_data_in;
    wire [15:0] x;

    register #(
        .WIDTH(16),
        .USE_NEGEDGE(USE_NEGEDGE)
    ) x_reg (
        .clk(clk),
        .rst(rst),
        .we(x_we),
        .data_in(x_data_in),
        .data_out(x)
    );

    // MARK: Y register
    reg         y_we;
    reg  [15:0] y_data_in;
    wire [15:0] y;

    register #(
        .WIDTH(16),
        .USE_NEGEDGE(USE_NEGEDGE)
    ) y_reg (
        .clk(clk),
        .rst(rst),
        .we(y_we),
        .data_in(y_data_in),
        .data_out(y)
    );

    // MARK: JMP fields
    wire [3:0] jmp_cond;
    wire [8:0] jmp_addr;

    assign jmp_cond = instr[12:9];
    assign jmp_addr = instr[8:0];

    // MARK: Non-JMP fields
    wire [2:0] op;
    assign op = instr[12:10];

    // MARK: SET fields
    wire [1:0] set_dst;
    wire [7:0] set_imm;
    wire [15:0] set_reg_res;

    assign set_dst = instr[9:8];
    assign set_imm = instr[7:0];

    // MARK: NOP Delay
    wire[9:0] instr_delay;
    wire[9:0] delay_out;
    wire delay_load;
    // is this a delay instruction?
    wire is_delay = instr[15] == 1'b1 && (op == 3'b110);
    
    assign instr_delay = instr[9:0];
    // if this is a delay instruction, load the counter,
    // but only if it isn't already loaded
    assign delay_load = is_delay && (delay_out == 0);

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
    wire [15:0] x_minus_1 = x - 16'd1;
    wire [15:0] y_minus_1 = y - 16'd1;
    assign set_reg_res = {8'b0, set_imm};

    // MARK: Instruction decode & control logic
    always @(*) begin
        // PC defaults: execute normally and increment
        pc_load      = 1'b0;
        halt         = 1'b0;
        pc_load_addr = 9'b0;

        // Register defaults: don't write
        x_we      = 1'b0;
        x_data_in = 16'b0;
        y_we      = 1'b0;
        y_data_in = 16'b0;

        // instr[15] == 0 means JMP
        if (instr[15] == 1'b0) begin
            case (jmp_cond)
                4'd0: begin // ALWAYS
                    pc_load      = 1'b1;
                    pc_load_addr = jmp_addr;
                end

                4'd1: begin // X == 0
                    if (x == 16'b0) begin
                        pc_load      = 1'b1;
                        pc_load_addr = jmp_addr;
                    end
                end

                4'd2: begin // X != 0
                    if (x != 16'b0) begin
                        pc_load      = 1'b1;
                        pc_load_addr = jmp_addr;
                    end
                end

                4'd3: begin // X-- != 0
                    if (x != 16'b0) begin
                        x_we         = 1'b1;
                        x_data_in    = x_minus_1;
                        pc_load      = 1'b1;
                        pc_load_addr = jmp_addr;
                    end
                end

                4'd4: begin // Y == 0
                    if (y == 16'b0) begin
                        pc_load      = 1'b1;
                        pc_load_addr = jmp_addr;
                    end
                end

                4'd5: begin // Y != 0
                    if (y != 16'b0) begin
                        pc_load      = 1'b1;
                        pc_load_addr = jmp_addr;
                    end
                end

                4'd6: begin // Y-- != 0
                    if (y != 16'b0) begin
                        y_we         = 1'b1;
                        y_data_in    = y_minus_1;
                        pc_load      = 1'b1;
                        pc_load_addr = jmp_addr;
                    end
                end

                default: begin
                end
            endcase
        end else begin
            // Non-JMP
            case (op)
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

                        default: begin
                        end
                    endcase
                end

                3'b110: begin // NOP
                    // Wait for 1 instruction, plus an additional
                    // number of encoded instructions called "delay".
                    if (delay_out != 0) begin
                        halt = 1'b1;
                    end
                end

                default: begin
                end
            endcase
        end
    end

endmodule
