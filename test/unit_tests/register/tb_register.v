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

    reg                  clk;
    reg                  rst;
    reg                  we;
    
    reg  [WIDTH-1:0]     data_in;
    wire [WIDTH-1:0]     data_out;

    register #(
        .WIDTH(WIDTH),
        .USE_NEGEDGE(USE_NEGEDGE)
    ) dut (
        .clk(clk),
        .rst(rst),
        .we(we),
        .data_in(data_in),
        .data_out(data_out)
    );

    initial begin
        clk     = 1'b0;
        rst     = 1'b0;
        we    = 1'b0;
        data_in = {WIDTH{1'b0}};
    end

endmodule

`default_nettype wire