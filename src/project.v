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
  
  // just some values for preventing optimizations, for now. TOOD: replace later.
//   assign uo_out = pc[7:0];
//   assign uio_out = {7'b0, pc[8]};
//   assign uio_oe  = 8'b0000_0001;

  // List all unused inputs to prevent warnings
//   wire _unused = &{ena, ui_in, uio_in, 1'b0};

  wire [8:0] pc = sram_address_a;
  wire [15:0] instr;


  // MARK: Reset & restart
  wire rst = !rst_n; // rst is HIGH to reset internally

  // MARK: Boot ROM
  wire boot_from_rom;       // are we currently booting from ROM?
  wire switch_to_sramland;  // are we switching to SRAMland?
  wire start_sram = boot_from_rom && !rst && switch_to_sramland;

  wire [8:0] rom_pc;
  wire [15:0] rom_instr;

  bootrom bootrom_inst (
      .clk(clk),
      .rst(rst),

      .branch_taken(branch_taken),
      .hold_pipeline(hold_pipeline),
      .switch_to_sramland(switch_to_sramland),

      .boot_from_rom(boot_from_rom),
      .instruction(rom_instr),
      .pc(rom_pc)
  );


  // MARK: Pipeline fetch
  wire [8:0] sram_address_a;
  wire [8:0] sram_address_b;

  wire [15:0] sram_instr_a;
  wire [15:0] sram_instr_b;
  wire [15:0] sram_instruction;

  wire branch_taken;
  wire hold_pipeline;

  // SRAN FETCH signals are helpful only outside BootROM!
  wire fetch_branch_taken = !boot_from_rom && !rst && branch_taken;
  wire fetch_hold_pipeline = !boot_from_rom && !rst && hold_pipeline;

  // Fetch + predecode
  pipeline_fetch #(
      .WIDTH(9)
  ) fetch_and_predecode_inst (
      .clk(clk),
      .rst(rst),

      .branch_taken(fetch_branch_taken),
      .hold_pipeline(fetch_hold_pipeline),
      .boot_from_rom(boot_from_rom),
      .switch_to_sramland(start_sram),

      .sram_address_a(sram_address_a),
      .sram_address_b(sram_address_b),

      .sram_instr_a(sram_instr_a),
      .sram_instr_b(sram_instr_b),

      .instruction(sram_instruction)
  );


  // MARK: SRAM programming
  // TODO: Connect these signals to the BootROM programming loader.
  wire program_write_enable;
  wire [8:0] program_write_address;
  wire [15:0] program_write_data;

  // During BootROM, port B is available for writing.
  // During SRAMland, port B performs speculative instruction fetches.
  wire program_mode = boot_from_rom && !start_sram;

  wire [8:0] sram_b_address = program_mode
                            ? program_write_address
                            : sram_address_b;

  wire sram_b_write = program_mode && !rst && program_write_enable;
  wire sram_b_read  = !program_mode;


  // MARK: SRAM
  RM_IHPSG13_2P_512x16_c2_bm_bist sram (
      // Port A: instruction fetch
      .A_CLK(clk),
      .A_MEN(1'b1),
      .A_WEN(1'b0),
      .A_REN(1'b1),
      .A_ADDR(sram_address_a),
      .A_DIN(16'b0),
      .A_DLY(1'b1),
      .A_DOUT(sram_instr_a),
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

      // Port B: program writing / speculative instruction fetch
      .B_CLK(clk),
      .B_MEN(1'b1),
      .B_WEN(sram_b_write),
      .B_REN(sram_b_read),
      .B_ADDR(sram_b_address),
      .B_DIN(program_write_data),
      .B_DLY(1'b1),
      .B_DOUT(sram_instr_b),
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

  // MARK: GPIO
  wire        gpio_en;
  wire [2:0]  gpio_op;
  wire [3:0]  gpio_pin;
  wire        gpio_dir;
  wire        gpio_value_in;
  wire        gpio_value_out;
  wire [15:0] gpio_multi_mask = 16'hffff;
  wire [15:0] gpio_multi_value_out = 16'h0000;
  wire [15:0] gpio_multi_value_in;
  wire        gpio_side_set_en;
  wire        gpio_side_set_value;
  wire  [3:0]  gpio_side_set_pin;

  gpio gpio_iface (
    .clk(clk),
    .rst(rst),
    .enable(gpio_en | gpio_side_set_en),

    .ui_in(ui_in),
    .uo_out(uo_out),
    .uio_in(uio_in),
    .uio_out(uio_out),
    .uio_oe(uio_oe),

    .op_setting(gpio_op),
    .pin_number(gpio_pin),
    .pin_direction(gpio_dir),
    .pin_value_out(gpio_value_out),
    .pin_value_in(gpio_value_in),

    .multi_mask(gpio_multi_mask),
    .multi_value_out(gpio_multi_value_out),
    .multi_value_in(gpio_multi_value_in),

    .side_set_enable(gpio_side_set_en),
    .side_set_value(gpio_side_set_value),
    .side_set_pin(gpio_side_set_pin)
  );

  // MARK: RX / TX FIFOs
  wire        host_rx_push;
  wire [7:0]  host_rx_data;
  wire        host_rx_ready;

  wire        host_tx_pull;
  wire [7:0]  host_tx_data;
  wire        host_tx_valid;

  wire        pio_rx_pull;
  wire [3:0]  pio_rx_bytes_cnt;
  wire [63:0] pio_rx_data;
  wire        pio_rx_valid;

  wire        pio_tx_push;
  wire [3:0]  pio_tx_bytes_cnt;
  wire [63:0] pio_tx_data;
  wire        pio_tx_ready;

  wire [63:0] tx_fifo_out;
  wire [5:0] rx_count, tx_count;

  assign host_tx_data = tx_fifo_out[7:0];

  // HOST -> RX FIFO -> Protocol Emulator Engine
  ringbuffer_fifo #(
      .DEPTH(32),
      .DATA_WIDTH(8)
  ) rx_fifo (
      .clk(clk),
      .rst(rst),

      .push(host_rx_push),
      .pull(pio_rx_pull),

      .push_byte_count(4'd1),
      .pull_byte_count(pio_rx_bytes_cnt),

      .data_in({56'b0, host_rx_data}),
      .data_out(pio_rx_data),

      .count(rx_count),
      .can_push(host_rx_ready),
      .can_pull(pio_rx_valid)
  );

  // Proto Emu Engine -> TX FIFO -> HOST
  ringbuffer_fifo #(
      .DEPTH(32),
      .DATA_WIDTH(8)
  ) tx_fifo (
      .clk(clk),
      .rst(rst),

      .push(pio_tx_push),
      .pull(host_tx_pull),

      .push_byte_count(pio_tx_bytes_cnt),
      .pull_byte_count(4'd1),

      .data_in(pio_tx_data),
      .data_out(tx_fifo_out),

      .count(tx_count),
      .can_push(pio_tx_ready),
      .can_pull(host_tx_valid)
  );

  // MARK: Execute
  assign instr = boot_from_rom ? rom_instr : sram_instruction;

  pio_core #(
      .USE_NEGEDGE(0)
  ) main_pio (
      .clk(clk),
      .rst(rst),

      .instr(instr),

      .branch_taken(branch_taken),
      .hold_pipeline(hold_pipeline),
      .switch_to_sramland(switch_to_sramland),
      
      .program_write_enable(program_write_enable),
      .program_write_address(program_write_address),
      .program_write_data(program_write_data),

      .gpio_side_set_en(gpio_side_set_en),
      .gpio_side_set_value(gpio_side_set_value),
      .gpio_side_set_pin(gpio_side_set_pin),

      .gpio_en(gpio_en),
      .gpio_op(gpio_op),
      .gpio_pindir(gpio_dir),
      .gpio_pin(gpio_pin),
      .gpio_value_out(gpio_value_out),
      .gpio_value_in(gpio_value_in),
      .gpio_pins_in(gpio_multi_value_in),

      .rx_fifo_data(pio_rx_data),
      .rx_fifo_can_pull(pio_rx_valid),
      .rx_fifo_pull(pio_rx_pull),
      .rx_fifo_bytes_cnt(pio_rx_bytes_cnt),

      .tx_fifo_data(pio_tx_data),
      .tx_fifo_can_push(pio_tx_ready),
      .tx_fifo_push(pio_tx_push),
      .tx_fifo_bytes_cnt(pio_tx_bytes_cnt)
  );

  // Temporary host stub until communication is implemented
  // TODO: Implement host communication.
  assign host_rx_push = 1'b0;
  assign host_rx_data = 8'b0;
  assign host_tx_pull = 1'b0;

//   (* keep *)
//   proto_logo logo();

endmodule

`default_nettype wire