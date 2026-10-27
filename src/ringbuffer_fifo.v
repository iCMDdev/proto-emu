/*
 * Copyright (c) 2024 Cristian Dinca
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// 32-byte FIFO, with variable bytes that can be PUSH / PULL-ed in a single command
// Max 8 bytes (64 bits) in a single PUSH/PULL command.
//
// If we conceptualize this as a 1-array continuous memory, we would say we need
// 8 ports for it. This can be quite a bit expensive, but they key observation is that
// we only need max 8 consecutive bytes - i.e. there are positions that will never be
// accessed concurrently.
//
// This is why we're introducing LANES: we're making this separation clear in our
// pre-synthesis architecture, instead of letting it figure it out on its own
// (not even sure if it's able to do so). We're taking advantage of the fact that
// we will never access bytes 0, 8, 16 and 24 simultaneously; same for 1, 9, 17, 25,
// and the list goes on. Each of these represents a separate memory called a LANE,
// with its own single read + single write port.
//
// You can view this as a matrix:
//
//                        LANES (independent memory banks)
//                     0    1    2    3    4    5    6    7
//                   +----+----+----+----+----+----+----+----+
//            Row 0  |  0 |  1 |  2 |  3 |  4 |  5 |  6 |  7 |
//                   +----+----+----+----+----+----+----+----+
//            Row 1  |  8 |  9 | 10 | 11 | 12 | 13 | 14 | 15 |
//                   +----+----+----+----+----+----+----+----+
//            Row 2  | 16 | 17 | 18 | 19 | 20 | 21 | 22 | 23 |
//                   +----+----+----+----+----+----+----+----+
//            Row 3  | 24 | 25 | 26 | 27 | 28 | 29 | 30 | 31 |
//                   +----+----+----+----+----+----+----+----+
//
// Each column is a separate memory (lane), containing 4 rows of 8 bits.
// The numbers represent byte addresses in our logical FIFO.
//
// For example, a 4-byte PUSH starting at address 6 accesses:
//
//       Byte address:   6    7    8    9
//       Lane:           6    7    0    1
//       Row:            0    0    1    1
//
// Notice that no lane is accessed twice during the same PUSH.
// This holds for any burst of up to 8 consecutive bytes, even
// when wrapping around the end of the FIFO.
module ringbuffer_fifo  #(
    parameter integer DEPTH = 32,    // total FIFO capacity
    parameter integer DATA_WIDTH = 8 // max bytes in a single PUSH / PULL command
) (
    input  wire clk,
    input  wire rst,

    // Operation (push / pull)
    input  wire push,
    input  wire pull,

    // How much to push / pull
    input  wire [$clog2(DATA_WIDTH+1)-1:0] push_byte_count,
    input  wire [$clog2(DATA_WIDTH+1)-1:0] pull_byte_count,

    // Data (in/out)
    input  wire [DATA_WIDTH*8-1:0] data_in,
    output wire [DATA_WIDTH*8-1:0] data_out,

    // Occupancy
    output wire [$clog2(DEPTH+1)-1:0] count,

    // Is the FIFO almost full / empty (for the given push / pull byte counts)
    output wire can_push,
    output wire can_pull
);
    // MARK: Constants and precalculations
    localparam integer PTR_BITS = $clog2(DEPTH);                    // bits for pointers
    localparam integer COUNT_BITS = $clog2(DEPTH + 1);              // bits for counting
                                                                    // i.e. from 0 to DEPTH (32)
                                                                    // including 0, so that'
                                                                    // why +1
    localparam integer BYTE_COUNT_BITS = $clog2(DATA_WIDTH + 1);    // bits for counting bytes
                                                                    // (similar reason for adding +1)

    // fifo ring buffer pointers
    reg [PTR_BITS-1:0] rd_ptr;
    reg [PTR_BITS-1:0] wr_ptr;

    // occupancy counter (how many elements are in FIFO right now?)
    reg [COUNT_BITS-1:0] occupancy;
    assign count = occupancy;

    // Lanes and rows constants (number of lanes, rows + bits required to store these).
    // A row = the byte's index in a lane (see matrix example at the beginning of this module)
    localparam integer LANES = DATA_WIDTH;
    localparam integer LANE_BITS = $clog2(LANES);
    localparam integer ROWS = DEPTH / LANES;
    localparam integer ROW_BITS = (ROWS <= 1) ? 1 : $clog2(ROWS);

    // Constants (sized to fit within constraints)
    localparam [BYTE_COUNT_BITS-1:0] MAX_TRANSFER = DATA_WIDTH[BYTE_COUNT_BITS-1:0];
    localparam [COUNT_BITS-1:0] CAPACITY = DEPTH[COUNT_BITS-1:0];

    // Extend push / pull byte count for later comparison with occupancy count
    wire [COUNT_BITS-1:0] push_bytes = {{(COUNT_BITS-BYTE_COUNT_BITS){1'b0}}, push_byte_count};
    wire [COUNT_BITS-1:0] pull_bytes = {{(COUNT_BITS-BYTE_COUNT_BITS){1'b0}}, pull_byte_count};

    // Push / Pull length sanity checks
    wire push_length_ok = (push_byte_count != {BYTE_COUNT_BITS{1'b0}}) &&
                          (push_byte_count <= MAX_TRANSFER);

    wire pull_length_ok = (pull_byte_count != {BYTE_COUNT_BITS{1'b0}}) &&
                          (pull_byte_count <= MAX_TRANSFER);

    // Do we have enough bytes to pull / enough space to push? (and are lengths valid)
    assign can_push = push_length_ok && (occupancy <= CAPACITY - push_bytes);
    assign can_pull = pull_length_ok && (occupancy >= pull_bytes);

    // Push / pull triggers
    wire push_fire = push && can_push && !rst;
    wire pull_fire = pull && can_pull && !rst;

    wire [DATA_WIDTH*8-1:0] lane_read_bytes;

    // MARK: LANES Logic
    // Logic for read & write
    genvar lane;
    generate
        // Generating the lanes
        for (lane = 0; lane < LANES; lane = lane + 1) begin: g_lane
            reg [7:0] mem [0:ROWS-1]; // this lane's actual memory

            // The current lane's index, sized to fit within LANE_BITS.
            localparam [LANE_BITS-1:0] LANE_INDEX = lane[LANE_BITS-1:0];

            // Lane read / write offsets (extended to the pointers' length)
            // Effectively (LANE_INDEX - wr_ptr) mod 8.
            // I.e. "which byte of the current operation does this lane correspond to?"
            wire [PTR_BITS-1:0] write_offset = {{(PTR_BITS-LANE_BITS){1'b0}},
                                                (LANE_INDEX - wr_ptr[LANE_BITS-1:0])};
            wire [PTR_BITS-1:0] read_offset  = {{(PTR_BITS-LANE_BITS){1'b0}},
                                                (LANE_INDEX - rd_ptr[LANE_BITS-1:0])};

            // Read / write positions
            wire [PTR_BITS-1:0] write_position = wr_ptr + write_offset;
            wire [PTR_BITS-1:0] read_position  = rd_ptr + read_offset;

            // Which row (i.e. element in the lane) are we operating on?
            wire [ROW_BITS-1:0] write_row = write_position[PTR_BITS-1:LANE_BITS];
            wire [ROW_BITS-1:0] read_row  = read_position[PTR_BITS-1:LANE_BITS];

            // write offset, extended to BYTE_COUNT_BITS for comparisons
            wire [BYTE_COUNT_BITS-1:0] wr_off_cnt = {{(BYTE_COUNT_BITS-LANE_BITS){1'b0}},
                                                     write_offset[LANE_BITS-1:0]};

            // Actually doing the write
            always @(posedge clk) begin
                if (push_fire && wr_off_cnt < push_byte_count)
                    mem[write_row] <= data_in[8*write_offset +: 8];
            end

            // Actually reading the element
            assign lane_read_bytes[8*lane +: 8] = mem[read_row];
        end
    endgenerate

    // MARK: data_out mapping
    // Mapping lane_read_bytes to data_out.
    // data_out is a reorder of lane_bytes -> because we might have lane output CD ... AB when
    // actual output is ABCD (i.e. fixing lane wrapping & ignoring unused lanes)
    genvar byte_index;
    generate
        for (byte_index = 0; byte_index < LANES; byte_index = byte_index + 1) begin : g_output
            // each iteration handles one byte of data_out.

            // current LANE (first / second / third lane etc)
            localparam [LANE_BITS-1:0] LANE_INDEX = byte_index[LANE_BITS-1:0];

            // how many bytes have we read
            localparam [BYTE_COUNT_BITS-1:0] COUNT_INDEX = byte_index[BYTE_COUNT_BITS-1:0];

            // the source for the current data_out byte @ byte_index
            wire [LANE_BITS-1:0] source_lane = rd_ptr[LANE_BITS-1:0] + LANE_INDEX;
            
            // set data_out (only if valid byte)
            assign data_out[8*byte_index +: 8] = (can_pull && COUNT_INDEX < pull_byte_count)
                                               ? lane_read_bytes[8*source_lane +: 8]
                                               : 8'b0;
        end
    endgenerate

    // MARK: Pointer step logic.
    wire [PTR_BITS-1:0] push_ptr_step = push_bytes[PTR_BITS-1:0]; // how much are we pushing
    wire [PTR_BITS-1:0] pull_ptr_step = pull_bytes[PTR_BITS-1:0]; // how much are we pulling

    always @(posedge clk) begin
        if (rst) begin
            rd_ptr <= {PTR_BITS{1'b0}};
            wr_ptr <= {PTR_BITS{1'b0}};
            occupancy <= {COUNT_BITS{1'b0}};
        end else begin
            if (push_fire) // if pushing, increment
                wr_ptr <= wr_ptr + push_ptr_step;

            if (pull_fire)  // if pulling, increment
                rd_ptr <= rd_ptr + pull_ptr_step;

            // adjust occupancy
            case ({push_fire, pull_fire})
                2'b10: occupancy <= occupancy + push_bytes;
                2'b01: occupancy <= occupancy - pull_bytes;
                2'b11: occupancy <= occupancy + push_bytes - pull_bytes;
                default: ;
            endcase
        end
    end
endmodule
