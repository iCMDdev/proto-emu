/*
 * Copyright (c) 2026 Cristian Dinca
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

module tb #(
    parameter WIDTH = 8,
    parameter USE_NEGEDGE = 1
);

    localparam COUNT_WIDTH = $clog2(WIDTH);

    reg                      clk;
    reg                      rst;
    reg                      load;
    reg                      shift;
    reg                      shift_right;

    reg  [COUNT_WIDTH-1:0]   shift_count;
    reg  [WIDTH-1:0]         data_in;
    reg  [WIDTH-1:0]         shift_in;

    wire [WIDTH-1:0]         data_out;

    shift_register #(
        .WIDTH(WIDTH),
        .USE_NEGEDGE(USE_NEGEDGE)
    ) dut (
        .clk(clk),
        .rst(rst),
        .load(load),
        .shift(shift),
        .shift_right(shift_right),
        .shift_count(shift_count),
        .data_in(data_in),
        .shift_in(shift_in),
        .data_out(data_out)
    );

    initial begin
        clk         = 1'b0;
        rst         = 1'b0;
        load        = 1'b0;
        shift       = 1'b0;
        shift_right = 1'b0;

        shift_count = {COUNT_WIDTH{1'b0}};
        data_in     = {WIDTH{1'b0}};
        shift_in    = {WIDTH{1'b0}};
    end

endmodule

`default_nettype wire
