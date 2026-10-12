`timescale 1ns/1ps

// A buffer: 16 row banks. Each row (16 bytes) is two 32-bit RAMs of 2 words:
//   ram[h][b0] holds word group {b0,h}, i.e. bytes 8*b0+4*h .. 8*b0+4*h+3.
// Write: 64-bit beat wr_addr (0..31) carries words 2*wr_addr (low half) and
//        2*wr_addr+1 (high half); row = wr_addr[4:1]; per-half enables wr_we.
// Read : row i is given column index k_i (rd_k nibble i); A[i][k_i] appears on
//        rd_data byte i ONE CYCLE LATER.
module a_buf (
    input  wire         clk,
    input  wire [1:0]   wr_we,
    input  wire [4:0]   wr_addr,
    input  wire [63:0]  wr_data,
    input  wire [63:0]  rd_k,
    output wire [127:0] rd_data
);

    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : g_row
            wire [31:0] word0, word1;
            reg  [2:0]  sel_q;                 // k[2] = word half, k[1:0] = byte

            sram_buf #(.DATA_W(32), .ADDR_W(1)) u_ram0 (
                .clk   (clk),
                .we    (wr_we[0] && (wr_addr[4:1] == i)),
                .waddr (wr_addr[0]),
                .wdata (wr_data[31:0]),
                .raddr (rd_k[4*i+3]),          // k[3] = which word of each half
                .rdata (word0)
            );
            sram_buf #(.DATA_W(32), .ADDR_W(1)) u_ram1 (
                .clk   (clk),
                .we    (wr_we[1] && (wr_addr[4:1] == i)),
                .waddr (wr_addr[0]),
                .wdata (wr_data[63:32]),
                .raddr (rd_k[4*i+3]),
                .rdata (word1)
            );

            always @(posedge clk)
                sel_q <= rd_k[4*i +: 3];

            wire [31:0] word = sel_q[2] ? word1 : word0;
            assign rd_data[8*i +: 8] = word[8*sel_q[1:0] +: 8];
        end
    endgenerate

endmodule