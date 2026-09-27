/*
 * Copyright (c) 2026 Cristian Dinca 
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none
`timescale 1ns / 1ps

/* This testbench tests the pio core.
*/
module tb_pio_core ();
    
    reg         clk;
    reg         rst;
    reg  [15:0] instr;

    wire [8:0]  pc;

    pio_core dut (
        .clk(clk),
        .rst(rst),
        .instr(instr),
        .pc(pc)
    );

    // Dump the signals to a FST file. You can view it with gtkwave or surfer.
    initial begin
        clk   = 0;
        rst   = 0;
        instr = 0;

        $dumpfile("pio_core.fst");
        $dumpvars(0, tb_pio_core);
    end

endmodule
