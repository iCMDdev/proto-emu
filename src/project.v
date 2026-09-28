/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_example (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // All output pins must be assigned. If not used, assign to 0.
  assign uo_out  = ui_in + uio_in;  // Example: ou_out is the sum of ui_in and uio_in
  assign uio_out = 0;
  assign uio_oe  = 0;

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, clk, rst_n, 1'b0};

  wire [8:0] pc;
  wire [15:0] instr;

  RM_IHPSG13_2P_512x16_c2_bm_bist sram (
    // Port A: instruction fetch
    .A_CLK(clk),
    .A_MEN(1'b1),
    .A_WEN(1'b0),
    .A_REN(1'b1),
    .A_ADDR(pc),
    .A_DIN(16'b0),
    .A_DLY(1'b1),
    .A_DOUT(instr),
    .A_BM(16'hFFFF),

    // Port A BIST unused
    .A_BIST_CLK(1'b0),
    .A_BIST_EN(1'b0),
    .A_BIST_MEN(1'b0),
    .A_BIST_WEN(1'b0),
    .A_BIST_REN(1'b0),
    .A_BIST_ADDR(9'b0),
    .A_BIST_DIN(16'b0),
    .A_BIST_BM(16'b0),

    // Port B: unused for now
    .B_CLK(clk),
    .B_MEN(1'b0),
    .B_WEN(1'b0),
    .B_REN(1'b0),
    .B_ADDR(9'b0),
    .B_DIN(16'b0),
    .B_DLY(1'b1),
    .B_DOUT(),
    .B_BM(16'hFFFF),

    // Port B BIST unused
    .B_BIST_CLK(1'b0),
    .B_BIST_EN(1'b0),
    .B_BIST_MEN(1'b0),
    .B_BIST_WEN(1'b0),
    .B_BIST_REN(1'b0),
    .B_BIST_ADDR(9'b0),
    .B_BIST_DIN(16'b0),
    .B_BIST_BM(16'b0)
);

endmodule
