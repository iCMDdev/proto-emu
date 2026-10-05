/*
 * Copyright (c) 2026 Cristian Dinca
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module register_formal #(
    parameter WIDTH = 9,
    parameter USE_NEGEDGE = 1
)(
    input wire                 clk,
    input wire                 rst,
    input wire                 we,
    input wire [WIDTH-1:0]     data_in
);
    wire [WIDTH-1:0] data_out;

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


    // $past() has no valid value on the first clock edge,
    // so don't check temporal properties until one edge has occurred.
    reg past_valid;

    initial begin
        past_valid = 1'b0;
    end

    generate
        if (USE_NEGEDGE) begin : gen_negedge
            always @(negedge clk) begin
                past_valid <= 1'b1;
                if (past_valid) begin
                    if ($past(rst)) begin
                        assert(data_out == {WIDTH{1'b0}});
                    end else if ($past(we) && !$past(rst)) begin
                        assert(data_out == $past(data_in));
                    end else if (!$past(we) && !$past(rst)) begin
                        assert(data_out == $past(data_out));
                    end
                end
            end
        end else begin : gen_posedge
            always @(posedge clk) begin
                past_valid <= 1'b1;
                if (past_valid) begin
                    if ($past(rst)) begin
                        assert(data_out == {WIDTH{1'b0}});
                    end else if ($past(we) && !$past(rst)) begin
                        assert(data_out == $past(data_in));
                    end else if (!$past(we) && !$past(rst)) begin
                        assert(data_out == $past(data_out));
                    end
                end
            end 
        end
    endgenerate
 
 endmodule

`default_nettype wire