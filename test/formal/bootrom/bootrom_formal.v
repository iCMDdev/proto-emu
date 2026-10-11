/*
 * Copyright (c) 2026 Cristian Dinca
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module bootrom_formal (
    input wire clk,
    input wire rst,
    input wire branch_taken,
    input wire hold_pipeline,
    input wire switch_to_sramland
);
    wire boot_from_rom;
    wire [15:0] instruction;
    wire [8:0] pc;

    bootrom dut (
        .clk(clk),
        .rst(rst),
        .branch_taken(branch_taken),
        .hold_pipeline(hold_pipeline),
        .switch_to_sramland(switch_to_sramland),
        .boot_from_rom(boot_from_rom),
        .instruction(instruction),
        .pc(pc)
    );

    // Start in reset 
    reg past_valid;
    initial begin
        past_valid = 1'b0;
        assume(rst);
    end

    always @(posedge clk) begin
        past_valid <= 1'b1;

        if (past_valid) begin
            if ($past(rst)) begin
                // Reset dominates both PC and boot-mode state.
                assert(pc == 9'd0);
                assert(boot_from_rom == 1'b1);
            end else if (!rst) begin
                // One-way ROM -> SRAM transition until the next reset.
                assert(boot_from_rom ==
                    ($past(boot_from_rom) && !$past(switch_to_sramland)));

                if ($past(boot_from_rom) &&
                    !$past(hold_pipeline) &&
                    !$past(switch_to_sramland)) begin
                    if ($past(branch_taken))
                        // No fixed target: the CURRENT program determines it.
                        assert(pc == $past(instruction[8:0]));
                    else
                        assert(pc == ($past(pc) + 9'd1));
                end else begin
                    // Delay, handoff, and SRAM mode must all hold ROM PC.
                    assert(pc == $past(pc));
                end

                // Combinational ROM is stable for a stable PC.
                // This does NOT prescribe the data at any address.
                if (pc == $past(pc))
                    assert(instruction == $past(instruction));
            end
        end
    end
endmodule

`default_nettype wire
