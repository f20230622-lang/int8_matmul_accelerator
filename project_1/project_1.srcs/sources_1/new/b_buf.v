`timescale 1ns/1ps

// B buffer: 16 column banks, each 16 x 8 bit (one column = 16 bytes).
// Write: 64-bit beat wr_addr (0..31) = words 2*wr_addr and 2*wr_addr+1.
//        row k = wr_addr[4:1]; byte n of the beat goes to column bank
//        j = 8*wr_addr[0] + n (halves enabled by wr_we).
// Read : column j is given row index k_j (rd_k nibble j); B[k_j][j] appears
//        on rd_data byte j ONE CYCLE LATER.
module b_buf (
    input  wire         clk,
    input  wire [1:0]   wr_we,
    input  wire [4:0]   wr_addr,
    input  wire [63:0]  wr_data,
    input  wire [63:0]  rd_k,
    output wire [127:0] rd_data
);

    genvar j;
    generate
        for (j = 0; j < 16; j = j + 1) begin : g_col
            sram_buf #(.DATA_W(8), .ADDR_W(4)) u_ram (
                .clk   (clk),
                .we    (wr_we[(j%8)/4] && (wr_addr[0] == (j/8))),
                .waddr (wr_addr[4:1]),
                .wdata (wr_data[8*(j%8) +: 8]),
                .raddr (rd_k[4*j +: 4]),
                .rdata (rd_data[8*j +: 8])
            );
        end
    endgenerate

endmodule