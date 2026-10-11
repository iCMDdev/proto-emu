/*
 * Copyright (c) 2026 Cristian Dinca
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// Module containing the BootROM, ROM Program Counter, and
// the `boot_from_rom` signal - indicating whether we're
// currently using ROMor not.
//
// The switch to SRAMland is done by the EXEC core, which
// sends us a signal `switch_to_sramland`.
module bootrom (
    input  wire        clk,
    input  wire        rst,
    input  wire        branch_taken,
    input  wire        hold_pipeline,
    input  wire        switch_to_sramland,

    output reg         boot_from_rom,
    output wire [15:0] instruction,
    output reg  [8:0]  pc
);
    // MARK: Boot mode
    // Register indicating whether we're exec from ROM or SRAM
    // (i.e. BootROM vs SRAMland)
    always @(posedge clk or posedge rst) begin
        if (rst)
            boot_from_rom <= 1'b1;
        else if (switch_to_sramland)
            boot_from_rom <= 1'b0;
    end

    // MARK: Boot ROM
    function [15:0] boot_rom;
        input [8:0] addr;
        begin
            case (addr)
                9'h000: boot_rom  = 16'h9000; // SET X, 0
                9'h001: boot_rom  = 16'h9190; // SET Y, 0x90
                9'h002: boot_rom  = 16'h9E05; // SHIFT_IN Y, 0x05
                9'h003: boot_rom  = 16'h9C01; // SRAM_WRITE
                9'h004: boot_rom  = 16'h9C00; // ENTER SRAMLAND
                default: boot_rom = 16'h0000; // JMP 0
            endcase
        end
    endfunction

    assign instruction = boot_rom(pc);

    // MARK: BootROM Program Counter
    // Advance once per executed BootROM instruction.
    // During a delay, hold the PC. Stop advancing when entering SRAMland.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pc <= 9'd0;
        end else if (boot_from_rom &&
                     !hold_pipeline &&
                     !switch_to_sramland) begin
            if (branch_taken)
                pc <= instruction[8:0];
            else
                pc <= pc + 1'b1;
        end
    end

endmodule

`default_nettype wire