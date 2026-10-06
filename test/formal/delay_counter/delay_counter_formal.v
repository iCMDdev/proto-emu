/*
 * Copyright (c) 2026 Cristian Dinca
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module delay_counter_formal #(
    parameter WIDTH = 9,
    parameter USE_NEGEDGE = 1
)(
    input wire                 clk,
    input wire                 rst,
    input wire                 load,
    input wire                 dec,
    input wire [WIDTH-1:0]     data_in
);

    wire [WIDTH-1:0] data_out;

    delay_counter #(
        .WIDTH(WIDTH),
        .USE_NEGEDGE(USE_NEGEDGE)
    ) dut (
        .clk(clk),
        .rst(rst),
        .load(load),
        .dec(dec),
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
        if (USE_NEGEDGE) begin
            always @(negedge clk) begin
                past_valid <= 1'b1;

                if (past_valid) begin

                    // Reset has highest priority.
                    if ($past(rst)) begin
                        assert(data_out == {WIDTH{1'b0}});
                    end

                    // Load has priority over decrement.
                    else if ($past(load)) begin
                        assert(data_out == $past(data_in));
                    end

                    // Decrement when requested, and value isn't 0.
                    else if ($past(dec) && $past(data_out) != 0) begin
                        assert(data_out == $past(data_out) - 1'b1);
                    end

                    // Otherwise the counter must hold its value.
                    else begin
                        assert(data_out == $past(data_out));
                    end

                end
            end
        end
        else begin
            always @(posedge clk) begin
                past_valid <= 1'b1;

                if (past_valid) begin

                    // Reset has highest priority.
                    if ($past(rst)) begin
                        assert(data_out == {WIDTH{1'b0}});
                    end

                    // Load has priority over decrement.
                    else if ($past(load)) begin
                        assert(data_out == $past(data_in));
                    end

                    // Decrement when requested.
                    else if ($past(dec) && $past(data_out) != 0) begin
                        assert(data_out == $past(data_out) - 1'b1);
                    end

                    // Otherwise the counter must hold its value.
                    else begin
                        assert(data_out == $past(data_out));
                    end

                end
            end
        end
    endgenerate

endmodule

`default_nettype wire