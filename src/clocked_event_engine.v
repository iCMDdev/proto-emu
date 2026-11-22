/*
 * Copyright (c) 2026 Cristian Dinca
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// Native WAIT and SHIFT_IN_EDGE event tracking for a PIO core.
// An instruction can wait for a level or for a *new* pin transition.
//
// Instruction families:
//   9D00-9D3F  WAIT PIN n, LOW/HIGH/RISING/FALLING
//                instr[5:4] = 00/01/10/11, instr[3:0] = pin
//   9E00-9EFF  SHIFT_IN_EDGE / SHR_IN_EDGE
//                instr[7]   = shift direction (0=left,1=right)
//                instr[6]   = triggering edge (0=falling,1=rising)
//                instr[5:4] = destination register
//                instr[3:0] = data pin (clock pin is EDGECLK register)
//   9C40-9C4F  SET EDGECLK,n (configuration write decoded in pio_core)
module clocked_event_engine #(
    parameter USE_NEGEDGE = 0
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] instr,
    input  wire [15:0] sampled_pins,
    input  wire        edge_clock_we,
    input  wire        other_stall,  // FIFO / delay stall of this core
    output wire        event_stall,
    output reg  [3:0]  edge_clock_pin,
    output reg         event_armed
);
    wire is_wait       = (instr & 16'h9FC0) == 16'h9D00;
    wire is_edge_shift = (instr & 16'h9F00) == 16'h9E00;

    wire [1:0] wait_mode = instr[5:4]; // LOW/HIGH/RISING/FALLING
    wire is_edge_wait = is_wait && wait_mode[1];  // waiting for an edge
    wire is_event_edge = is_edge_wait || is_edge_shift; // edge event

    wire [3:0] event_pin = is_edge_shift ? edge_clock_pin : instr[3:0];
    // value passed directly from gpio
    wire event_pin_sample = sampled_pins[event_pin]; 
    wire event_target_high = is_edge_shift ? instr[6] : ~wait_mode[0];

    // Edge waits arm only after observing the opposite level while the
    // instruction is active; a pin already at the target does not count
    wire event_edge_done = event_armed &&
                           (event_pin_sample == event_target_high);
    wire event_level_done = (event_pin_sample == wait_mode[0]);

    assign event_stall = (is_event_edge && !event_edge_done) ||
                         (is_wait && !wait_mode[1] && !event_level_done);

    // On each clock edge, the engine resets its state if rst is active,
    // or updates edge_clock_pin if a new pin is configured. While waiting
    // for an edge, it sets event_armed = 1 once it observes the opposite
    // level (LOW before rising, HIGH before falling). When the desired
    // level arrives, the instruction completes and event_armed resets to 0,
    // ready for the next edge.
    generate
        if (USE_NEGEDGE) begin : event_negedge
            always @(negedge clk) begin
                if (rst) begin
                    edge_clock_pin <= 4'd0;
                    event_armed <= 1'b0;
                end else begin
                    if (edge_clock_we)
                        edge_clock_pin <= instr[3:0];

                    if (is_event_edge && !other_stall && event_stall) begin
                        if (event_pin_sample != event_target_high)
                            event_armed <= 1'b1;
                    end else begin
                        event_armed <= 1'b0;
                    end
                end
            end
        end else begin : event_posedge
            always @(posedge clk) begin
                if (rst) begin
                    edge_clock_pin <= 4'd0;
                    event_armed <= 1'b0;
                end else begin
                    if (edge_clock_we)
                        edge_clock_pin <= instr[3:0];

                    if (is_event_edge && !other_stall && event_stall) begin
                        if (event_pin_sample != event_target_high)
                            event_armed <= 1'b1;
                    end else begin
                        event_armed <= 1'b0;
                    end
                end
            end
        end
    endgenerate
endmodule

`default_nettype wire
