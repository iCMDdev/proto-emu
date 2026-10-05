/*
 * Copyright (c) 2026 Cristian Dinca
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module shift_register_formal #(
    parameter WIDTH = 16,
    parameter USE_NEGEDGE = 1
)(
    input wire                         clk,
    input wire                         rst,

    input wire                         load,
    input wire                         shift,

    input wire                         shift_right,
    input wire [$clog2(WIDTH)-1:0]     shift_count,

    input wire [WIDTH-1:0]             data_in,
    input wire [WIDTH-1:0]             shift_in
);

    localparam COUNT_WIDTH = $clog2(WIDTH);
    localparam [COUNT_WIDTH:0] FULL_WIDTH = WIDTH;

    wire [WIDTH-1:0] data_out;

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

    // $past() has no valid value on the first clock edge,
    // so don't check temporal properties until one edge has occurred.
    reg past_valid;

    wire [COUNT_WIDTH:0] actual_shift_count;
    assign actual_shift_count = (shift_count == {COUNT_WIDTH{1'b0}})
                                ? FULL_WIDTH : {1'b0, shift_count};

    initial begin
        past_valid = 1'b0;
    end

    generate
        if (USE_NEGEDGE) begin : gen_negedge
            always @(negedge clk) begin
                past_valid <= 1'b1;

                if (past_valid) begin
                    // Reset has highest priority
                    if ($past(rst)) begin
                        assert(data_out == {WIDTH{1'b0}});
                    end

                    // Load has priority over shift
                    else if ($past(load)) begin
                        assert(data_out == $past(data_in));
                    end

                    // Shift
                    else if ($past(shift)) begin
                        // Shift right
                        if ($past(shift_right)) begin
                            assert(data_out ==
                                (
                                    // data shifted out of the register
                                    ($past(data_out) >> $past(actual_shift_count)) |
                                    // new bits shifted into the register
                                    ($past(shift_in) <<
                                     (FULL_WIDTH - $past(actual_shift_count)))
                                )
                            );
                        end

                        // Shift left
                        else begin
                            assert(data_out ==
                                (
                                    // data shifted out of the register 
                                    ($past(data_out) << $past(actual_shift_count)) |
                                    // new bits shifted into the register
                                    ($past(shift_in) &
                                     ({WIDTH{1'b1}} >>
                                      (FULL_WIDTH - $past(actual_shift_count))))
                                )
                            );
                        end
                    end

                    // Otherwise hold
                    else begin
                        assert(data_out == $past(data_out));
                    end
                end
            end
        end else begin : gen_posedge
            always @(posedge clk) begin
                past_valid <= 1'b1;

                if (past_valid) begin
                    // Reset has highest priority
                    if ($past(rst)) begin
                        assert(data_out == {WIDTH{1'b0}});
                    end

                    // Load has priority over shift
                    else if ($past(load)) begin
                        assert(data_out == $past(data_in));
                    end

                    // Shift
                    else if ($past(shift)) begin
                        // Shift right
                        if ($past(shift_right)) begin
                            assert(data_out ==
                                (
                                    // data shifted out of the register
                                    ($past(data_out) >> $past(actual_shift_count)) |
                                    // new bits shifted into the register
                                    ($past(shift_in) <<
                                     (FULL_WIDTH - $past(actual_shift_count)))
                                )
                            );
                        end

                        // Shift left
                        else begin
                            assert(data_out ==
                                (
                                    // data shifted out of the register 
                                    ($past(data_out) << $past(actual_shift_count)) |
                                    // new bits shifted into the register
                                    ($past(shift_in) &
                                     ({WIDTH{1'b1}} >>
                                      (FULL_WIDTH - $past(actual_shift_count))))
                                )
                            );
                        end
                    end

                    // Otherwise hold
                    else begin
                        assert(data_out == $past(data_out));
                    end
                end
            end
        end
    endgenerate

endmodule

`default_nettype wire