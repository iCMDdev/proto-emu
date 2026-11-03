
/*
 * Copyright (c) 2026 Cristian Dinca
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// SPI Host Interface, sending / receiving values via FIFOs.

module spi_host (
    input  wire        clk,
    input  wire        rst,

    // MARK: SPI interface (Mode 0)
    input  wire        spi_sclk,
    input  wire        spi_mosi,
    input  wire        spi_cs_n,
    output wire        spi_miso,

    // MARK: RX FIFO (Host -> PIO)
    output reg         host_rx_push,
    output reg  [7:0]  host_rx_data,
    input  wire        host_rx_ready,
    input  wire [5:0]  rx_count,

    // MARK: TX FIFO (PIO -> Host)
    output wire        host_tx_pull,
    input  wire [7:0]  host_tx_data,
    input  wire        host_tx_valid,
    input  wire [5:0]  tx_count
);
    // MARK: SPI Commands
    localparam [7:0]
        CMD_STATUS   = 8'h00,
        CMD_WRITE_RX = 8'h10,
        CMD_READ_TX  = 8'h20;

    // MARK: SPI States
    localparam [2:0]
        ST_COMMAND   = 3'd0, // Waiting for a command byte
        ST_STATUS_RX = 3'd1, // RX FIFO free-space count
        ST_STATUS_TX = 3'd2, // TX FIFO occupancy count
        ST_WRITE_RX  = 3'd3, // Receiving bytes into RX FIFO
        ST_READ_TX   = 3'd4, // Sending bytes from TX FIFO
        ST_DONE      = 3'd5; // Done

    reg [2:0] state;


    // MARK: Synchronize SPI inputs
    reg [1:0] sclk_sync;
    reg [1:0] mosi_sync;
    reg [1:0] cs_sync;

    reg sclk_prev;

    always @(posedge clk) begin
        if (rst) begin
            sclk_sync <= 2'b00;
            mosi_sync <= 2'b00;
            cs_sync   <= 2'b11;
            sclk_prev <= 1'b0;
        end else begin
            sclk_sync <= {sclk_sync[0], spi_sclk};
            mosi_sync <= {mosi_sync[0], spi_mosi};
            cs_sync   <= {cs_sync[0], spi_cs_n};
            sclk_prev <= sclk_sync[1];
        end
    end

    wire spi_sclk_rising = sclk_sync[1] && !sclk_prev;
    wire spi_sclk_falling = !sclk_sync[1] && sclk_prev;
    wire spi_selected = !cs_sync[1];


    // MARK: SPI receiver
    reg [7:0] rx_shift;
    reg [2:0] bit_count;

    reg [7:0] received_byte;  // the value received
    reg       received_valid; // every 8 bits received, this should go high.

    always @(posedge clk) begin
        if (rst) begin
            rx_shift       <= 8'b0;
            bit_count      <= 3'd0;
            received_byte  <= 8'b0;
            received_valid <= 1'b0;
        end else begin
            received_valid <= 1'b0;

            if (!spi_selected) begin
                bit_count <= 3'd0;
                rx_shift  <= 8'b0;
            end else if (spi_sclk_rising) begin
                rx_shift <= {rx_shift[6:0], mosi_sync[1]};

                if (bit_count == 3'd7) begin
                    received_byte  <= {rx_shift[6:0], mosi_sync[1]};
                    received_valid <= 1'b1;
                    bit_count      <= 3'd0;
                end else begin
                    bit_count <= bit_count + 3'd1;
                end
            end
        end
    end

    // MARK: SPI transmit byte interface
    reg [7:0] spi_tx_byte;
    reg       spi_tx_load;
    reg       spi_tx_from_fifo;

    // READ_TX bookkeeping
    reg       tx_byte_valid;

    // Pull the byte that has just finished transmitting.
    // The FIFO updates its read pointer on the next system-clock edge.
    // No refill countdown is necessary: the transmitter reads the new
    // FIFO head directly when spi_tx_load reaches it.
    assign host_tx_pull = !rst && spi_selected && received_valid &&
                          (state == ST_READ_TX) && tx_byte_valid;

    always @(posedge clk) begin
        if (rst || !spi_selected) begin
            state              <= ST_COMMAND;

            host_rx_push       <= 1'b0;
            host_rx_data       <= 8'b0;

            spi_tx_byte        <= 8'b0;
            spi_tx_load        <= 1'b0;
            spi_tx_from_fifo   <= 1'b0;

            tx_byte_valid      <= 1'b0;
        end else begin
            // One-clock pulses
            host_rx_push <= 1'b0;
            spi_tx_load  <= 1'b0;
            spi_tx_from_fifo <= 1'b0;

            // Remember whether the FIFO byte actually loaded into
            // the transmitter was valid (so we only pull real bytes).
            if (spi_tx_load && spi_tx_from_fifo)
                tx_byte_valid <= host_tx_valid;

            if (received_valid) begin
                case (state)

                    // First received byte is the command
                    ST_COMMAND: begin
                        case (received_byte)
                            CMD_STATUS: begin
                                // Prepare to send RX FIFO byte count
                                spi_tx_byte <= 8'd32 - {2'b00, rx_count};
                                spi_tx_load <= 1'b1;
                                state <= ST_STATUS_RX;
                            end

                            CMD_WRITE_RX: begin
                                state <= ST_WRITE_RX;
                            end

                            CMD_READ_TX: begin
                                // Load the current FIFO directly.
                                spi_tx_load      <= 1'b1;
                                spi_tx_from_fifo <= 1'b1;
                                state <= ST_READ_TX;
                            end

                            default: begin
                                state <= ST_DONE;
                            end
                        endcase
                    end

                    // RX Byte was sent!
                    // now prepare TX occupancy
                    ST_STATUS_RX: begin
                        // Prepare to send TX FIFO byte count
                        spi_tx_byte <= {2'b00, tx_count};
                        spi_tx_load <= 1'b1;
                        state <= ST_STATUS_TX;
                    end

                    // We sent the TX byte!
                    ST_STATUS_TX: begin
                        state <= ST_DONE;
                    end

                    // Every subsequent byte goes into RX FIFO
                    ST_WRITE_RX: begin
                        if (host_rx_ready) begin
                            host_rx_data <= received_byte;
                            host_rx_push <= 1'b1;
                        end
                        // If not ready (e.g. full FIFO), discard the byte
                        // Best effort - Host should check FIFO status
                    end

                    // A complete TX byte has just been clocked out
                    ST_READ_TX: begin
                        // host_tx_pull is asserted combinationally here
                        // if the byte was valid. The FIFO pointer advances
                        // at this edge; the transmitter sees its new head
                        // at the following system-clock edge.
                        spi_tx_load      <= 1'b1;
                        spi_tx_from_fifo <= 1'b1;
                    end

                    ST_DONE: begin
                        // Ignore remaining bytes until CS_N rises
                    end

                    default: begin
                        state <= ST_DONE;
                    end

                endcase
            end
        end
    end


    // MARK: SPI transmitter
    reg [7:0] tx_shift; // shift register containing the value sent on MISO.
    // MISO output is the MSB of our shift reg
    assign spi_miso = spi_selected ? tx_shift[7] : 1'b0;

    // SPI Mode 0.
    // 2 signals are used:
    //  - spi_tx_load loads a new value in the MISO shift register
    //  - on each `spi_sclk_falling` falling edge, the register is shifted,
    //    switching the MISO bit that should be read on every posedge
    always @(posedge clk) begin
        if (rst || !spi_selected) begin
            tx_shift <= 8'b0;
        end else begin
            // Load the next byte into the transmitter.
            // FIFO data is combinational, so we can take the new
            // FIFO head directly after its read pointer advances.
            if (spi_tx_load) begin
                if (spi_tx_from_fifo)
                    tx_shift <= host_tx_valid ? host_tx_data : 8'h00;
                else
                    tx_shift <= spi_tx_byte;
            end
            // Advance the data on falling SCLK edges.
            // Do not shift after the 8th bit of a byte.
            else if (spi_sclk_falling && (bit_count != 3'd0)) begin
                tx_shift <= {tx_shift[6:0], 1'b0};
            end
        end
    end

endmodule

`default_nettype wire
