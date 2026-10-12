`timescale 1ns/1ps

// C result buffer: 16 column banks x 16 rows x 32 bit.
// Drain: copies the 256 accumulator values from c_in in 16 cycles (one row per cycle).
// Read : 64-bit beat e (rd_addr, 0..127) = words 2e and 2e+1 (row-major, word = i*16+j):
//        row i = e[6:3], columns 2*e[2:0] and 2*e[2:0]+1 -> {high word, low word}.
//        rd_data is valid ONE CYCLE after rd_addr.
module c_buf (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              drain_start,   // pulse; ignored while draining
    output wire              drain_busy,
    output reg               drain_done,    // 1-cycle pulse after last row written
    input  wire [32*256-1:0] c_in,          // C[i][j] at [32*(i*16+j) +: 32]
    input  wire [6:0]        rd_addr,
    output wire [63:0]       rd_data
);

    reg       draining;
    reg [3:0] row;

    assign drain_busy = draining;

    always @(posedge clk) begin
        if (!rst_n) begin
            draining   <= 1'b0;
            row        <= 4'd0;
            drain_done <= 1'b0;
        end else begin
            drain_done <= 1'b0;
            if (!draining) begin
                if (drain_start) begin
                    draining <= 1'b1;
                    row      <= 4'd0;
                end
            end else begin
                if (row == 4'd15) begin
                    draining   <= 1'b0;
                    drain_done <= 1'b1;
                end else begin
                    row <= row + 4'd1;
                end
            end
        end
    end

    wire [32*16-1:0] bank_q;
    reg  [2:0]       sel_q;

    always @(posedge clk)
        sel_q <= rd_addr[2:0];

    genvar j;
    generate
        for (j = 0; j < 16; j = j + 1) begin : g_bank
            sram_buf #(.DATA_W(32), .ADDR_W(4)) u_ram (
                .clk   (clk),
                .we    (draining),
                .waddr (row),
                .wdata (c_in[32*(row*16 + j) +: 32]),
                .raddr (rd_addr[6:3]),
                .rdata (bank_q[32*j +: 32])
            );
        end
    endgenerate

    assign rd_data[31:0]  = bank_q[32*{sel_q, 1'b0} +: 32];
    assign rd_data[63:32] = bank_q[32*{sel_q, 1'b1} +: 32];

endmodule