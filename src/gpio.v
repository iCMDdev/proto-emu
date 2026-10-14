/*
 * Copyright (c) 2026 Cristian Dinca 
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

/*
    Pin address space, subject to change when
    we implement host <-> core communication
    (the one used at runtime, after bootrom,
    for sending / receiving data asynchronously).

    Readable pins:
    Logical pin	    Physical pin
    0-7             uio_in[7:0]
    8-15            ui_in[7:0]

    Writable pins:
    Logical pin	    Physical pin
    0-7             uio_out[7:0]
    8–15            uo_out[7:0]

    Outputs are set on clock, but the logic is combinational.
*/
module gpio #(
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       enable,

    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
 
    input  wire [2:0] op_setting,    // 0=NOP, 1=SETDIR, 2=SET, 3=SETMULTI, 4=SETDIRMULTI
    input  wire [3:0] pin_number,    // Logical number according to the comments above
    input  wire       pin_direction, // only for I/O pins (i.e. addrs 0-7)
    input  wire       pin_value_out, // value (when set)
    output wire       pin_value_in,  // value (when read)

    // Multiple-pin operations
    input  wire [15:0] multi_mask,
    input  wire [15:0] multi_value_out,
    output wire [15:0] multi_value_in,

    // Side-set
    input  wire        side_set_enable,
    input  wire        side_set_value,
    input  wire [3:0]  side_set_pin
) ;
    // GPIO input synchronization
    // Double flip-flop sync
    wire [15:0] gpio_raw = {ui_in, uio_in};
    reg [15:0] gpio_sync_ff_1;
    reg [15:0] gpio_sync_ff_2;

    always @(posedge clk) begin
        if (rst) begin
            gpio_sync_ff_1 <= 16'b0;
            gpio_sync_ff_2 <= 16'b0;
        end else begin
            gpio_sync_ff_1 <= gpio_raw;
            gpio_sync_ff_2 <= gpio_sync_ff_1;
        end
    end

    // Pin number mapping for in / out / IO
    wire [15:0] gpio_in = gpio_sync_ff_2;
    reg [15:0] gpio_out;
    reg [7:0]  gpio_dir;

    assign uio_out = gpio_out[7:0];
    assign uo_out  = gpio_out[15:8];
    assign uio_oe  = gpio_dir;

    // Next values for GPIO, set on clock posedge
    reg [15:0] next_gpio_out;
    reg [7:0]  next_gpio_dir;

    assign multi_value_in = gpio_in & multi_mask;
    assign pin_value_in = gpio_in[pin_number];

    always @(posedge clk) begin
        if (rst) begin
            gpio_out <= 16'b0;
            gpio_dir <= 8'b0; // All IOs start as inputs
        end else if (enable) begin
            gpio_out <= next_gpio_out;
            gpio_dir <= next_gpio_dir;
        end
    end

    always @(*) begin
        // Start from current GPIO
        next_gpio_out = gpio_out;
        next_gpio_dir = gpio_dir;

        case (op_setting)
            3'd1: begin // SETDIR
                if (!pin_number[3]) // not for non-IO pins
                    next_gpio_dir[pin_number[2:0]] = pin_direction;
            end

            3'd2: begin // SET
                next_gpio_out[pin_number] = pin_value_out;
            end

            3'd3: begin // SETMULTI
                next_gpio_out = (gpio_out & ~multi_mask) |
                                (multi_value_out & multi_mask);
            end

            3'd4: begin // SETDIRMULTI
                next_gpio_dir = (gpio_dir & ~multi_mask[7:0]) |
                                (multi_value_out[7:0] & multi_mask[7:0]);
            end

            default: begin
                // 0: NOP/READ/READMULTI
            end
        endcase

        // Finally, apply side set
        if (side_set_enable)
            next_gpio_out[side_set_pin] = side_set_value;
    end
endmodule
