/*
 * Copyright (c) 2026 Cristian Dinca 
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module delay_counter #(
    parameter WIDTH = 10,
    parameter USE_NEGEDGE = 1
)(
    input  wire       clk,
    input  wire       rst,

    input  wire       load,
    input  wire       dec,
    input  wire [WIDTH-1:0] data_in,

    output wire [WIDTH-1:0] data_out
) ;

    reg [WIDTH-1:0] value;

    wire dec_cond = dec & (|value);
    assign data_out = value;

    generate
    if (USE_NEGEDGE) begin : gen_negedge
        always @(negedge clk) begin
            if (rst) begin
                value <= {WIDTH{1'b0}};
            end else if (load) begin
                value <= data_in;
            end else if (dec_cond) begin
                value <= value - 1'b1;
            end
        end
    end else begin : gen_posedge
        always @(posedge clk) begin
            if (rst) begin
                value <= {WIDTH{1'b0}};
            end else if (load) begin
                value <= data_in;
            end else if (dec_cond) begin
                value <= value - 1'b1;
            end
        end
    end
    endgenerate

endmodule
