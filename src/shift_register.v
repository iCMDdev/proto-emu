/*
 * Copyright (c) 2026 Cristian Dinca
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module shift_register #(
    parameter WIDTH = 16,
    parameter USE_NEGEDGE = 1
)(
    input  wire                         clk,
    input  wire                         rst,

    input  wire                         load,
    input  wire                         shift,

    input  wire                         shift_right,
    input  wire [$clog2(WIDTH)-1:0]     shift_count,

    // Used for a full register load
    input  wire [WIDTH-1:0]             data_in,

    // Bits shifted into the register.
    // The low shift_count bits are used.
    input  wire [WIDTH-1:0]             shift_in,

    output wire [WIDTH-1:0]             data_out
);

    localparam COUNT_WIDTH = $clog2(WIDTH);
    localparam [COUNT_WIDTH:0] FULL_WIDTH = WIDTH;

    reg [WIDTH-1:0] value;

    wire [COUNT_WIDTH:0] actual_shift_count;

    // shift_count == 0 represents WIDTH, not "don't shift"
    assign actual_shift_count = (shift_count == {COUNT_WIDTH{1'b0}})
                                ? FULL_WIDTH
                                : {1'b0, shift_count};

    assign data_out = value;

    generate
        if (USE_NEGEDGE) begin : gen_negedge
            always @(negedge clk) begin
                if (rst) begin
                    value <= {WIDTH{1'b0}};
                end else if (load) begin
                    value <= data_in;
                end else if (shift) begin
                    if (shift_right) begin
                        value <= (value >> actual_shift_count) | // shifted out bits
                                 (shift_in << // shifted in btis
                                 (FULL_WIDTH - actual_shift_count));
                    end else begin
                        value <= (value << actual_shift_count) | // shifted out bits
                                 (shift_in & // shifted in bits
                                 ({WIDTH{1'b1}} >> (FULL_WIDTH - actual_shift_count)));
                    end
                end
            end
        end else begin : gen_posedge
            always @(negedge clk) begin
                if (rst) begin
                    value <= {WIDTH{1'b0}};
                end else if (load) begin
                    value <= data_in;
                end else if (shift) begin
                    if (shift_right) begin
                        value <= (value >> actual_shift_count) | // shifted out bits
                                 (shift_in << // shifted in btis
                                 (FULL_WIDTH - actual_shift_count));
                    end else begin
                        value <= (value << actual_shift_count) | // shifted out bits
                                 (shift_in & // shifted in bits
                                 ({WIDTH{1'b1}} >> (FULL_WIDTH - actual_shift_count)));
                    end
                end
            end 
        end
    endgenerate

endmodule
