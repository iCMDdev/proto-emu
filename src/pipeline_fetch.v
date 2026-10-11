/*
 * Copyright (c) 2026 Cristian Dinca
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// Pipeline FETCH & predecode stage, used in SRAMland.
//
// This pipeline stage fetches SRAM instructions in parallel with
// the core's execution (which is referred to as the EXEC stage).
// This parallelization allows for higher frequencies, since the
// core does not need to wait for SRAM.
//
// The SRAM instruction may take anywhere between 3ns up to 6-7ns
// in the worst cases, according to IHP.
//
// Because we support JUMP instructions, and we don't know whether
// the branch was taken or not till late in the clock cycle,
// we fetch both possible cases (addr+1 or the encoded instruction),
// using a 2-port SRAM. The correct one is chosen at the next
// posedge: the selected instruction is just a MUX between the 2
// options.
// 
// This uses branch_taken, a signal coming from EXEC, that should
// be set late in the clock cycle, although not right before the
// posedge - keep in mind the potential setup times).
module pipeline_fetch #(
    parameter WIDTH = 9
)(
    input wire clk,
    input wire rst,
    input wire branch_taken,                // coming from core - indicates whether branch will be taken or not.
    input wire hold_pipeline,               // halt the pipeline (usually during NOPs)
    input wire switch_to_sramland,          // 1 if currently exiting BootROM
    input wire boot_from_rom,               // 1 if currently booting from ROM

    output wire [WIDTH-1:0] sram_address_a,
    output wire [WIDTH-1:0] sram_address_b,
    input  wire [15:0] sram_instr_a,
    input  wire [15:0] sram_instr_b,

    output reg [15:0] instruction           // SRAM instruction to be executed, updated on posedge
);
    // current PC addresses
    reg [WIDTH-1:0] fetched_pc_a;
    reg [WIDTH-1:0] fetched_pc_b;

    // possible next addresses
    wire [WIDTH-1:0] a_not_taken;
    wire [WIDTH-1:0] b_not_taken;
    wire [WIDTH-1:0] a_taken;
    wire [WIDTH-1:0] b_taken;

    // decode instructions from both addresses
    assign a_not_taken = fetched_pc_a + 1'b1;
    assign b_not_taken = fetched_pc_b + 1'b1;
    assign a_taken = sram_instr_a[WIDTH-1:0];
    assign b_taken = sram_instr_b[WIDTH-1:0];

    // future SRAM addresses A and B
    // A is the future "branch not taken", B is the future "branch taken"
    assign sram_address_a = rst ? {WIDTH{1'b0}}                     // if reset, start from 0
                                : boot_from_rom                     // if currently booting from ROM:
                                    ? (switch_to_sramland           //      if currently switching to SRAMland:
                                        ? {{(WIDTH-1){1'b0}}, 1'b1} //      then next address is 0x0001
                                        : {WIDTH{1'b0}})            //      otherwise next address is 0x0000
                                : hold_pipeline ? fetched_pc_a      // else, if pipeline is halted, keep the same PC
                                : branch_taken ? b_not_taken        // else, just use the correct predicted address,
                                               : a_not_taken;       //       based on branch_taken (input, from core)

    assign sram_address_b = rst ? {WIDTH{1'b0}}                     // if reset, start from 0
                                : boot_from_rom                     // if currently booting from ROM:
                                    ? (switch_to_sramland           //      if currently switching to SRAMland:
                                        ? a_taken                   //      then next address is INSTR[8:0]
                                        : {WIDTH{1'b0}})            //      otherwise next address is 0x000
                                : hold_pipeline ? fetched_pc_b      // else, if pipeline is halted, keep the same PC
                                : branch_taken ? b_taken            // else, just use the correct predicted address,
                                               : a_taken;           //       bassed on branch_taken (input, from core)

    // future instruction to be fetched.
    wire [15:0] selected_instruction;

    // instruction to be passed to the EXEC stage
    assign selected_instruction = branch_taken ? sram_instr_b
                                               : sram_instr_a;

    // Save the current PC addresses - i.e. the ones
    // we have before computing the next PCs after instr decode.
    // Also do the same for instruction - but only if the pipeline
    // isn't halted via hold_pipeline.
    always @(posedge clk) begin
        if (rst) begin
            // start from address 0
            fetched_pc_a <= {WIDTH{1'b0}};
            fetched_pc_b <= {WIDTH{1'b0}};
            instruction  <= 16'b0;
        end else if (boot_from_rom) begin
            // If currently booting from ROM, but switching to
            // SRAMland, initialize the SRAM pipeline.
            // SRAM[0] is already available on port A.
            if (switch_to_sramland) begin
                fetched_pc_a <= sram_address_a; // should be 0x0001
                fetched_pc_b <= sram_address_b; // shoulo be INSTR[8:0]
                instruction  <= sram_instr_a;   // should be SRAM[0]
            end
        end else if (!hold_pipeline) begin
            // Normal SRAM pipeline execution.
            fetched_pc_a <= sram_address_a;
            fetched_pc_b <= sram_address_b;
            instruction  <= selected_instruction;
        end
    end

endmodule

`default_nettype wire