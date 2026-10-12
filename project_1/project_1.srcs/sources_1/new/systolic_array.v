`timescale 1ns/1ps

module systolic_array #(
    parameter N     = 16,
    parameter N_DSP = 192      // PEs 0..N_DSP-1 (row-major) use DSP48E1, the rest use LUTs
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                clear,
    input  wire [8*N-1:0]      a_row_in,   // west edge: byte i feeds row i
    input  wire [8*N-1:0]      b_col_in,   // north edge: byte j feeds column j
    output wire [32*N*N-1:0]   c_out       // C[i][j] at [32*(i*N+j) +: 32]
);

    wire [8*N*(N+1)-1:0] a_bus;
    wire [8*(N+1)*N-1:0] b_bus;

    genvar i, j;

    generate
        for (i = 0; i < N; i = i + 1) begin : g_west
            assign a_bus[8*(i*(N+1)) +: 8] = a_row_in[8*i +: 8];
        end
        for (j = 0; j < N; j = j + 1) begin : g_north
            assign b_bus[8*j +: 8] = b_col_in[8*j +: 8];
        end

        for (i = 0; i < N; i = i + 1) begin : g_row
            for (j = 0; j < N; j = j + 1) begin : g_col
                mac_pe #(.USE_DSP((i*N + j) < N_DSP)) u_pe (
                    .clk   (clk),
                    .rst_n (rst_n),
                    .clear (clear),
                    .a_in  (a_bus[8*(i*(N+1)+j)     +: 8]),
                    .b_in  (b_bus[8*(i*N+j)         +: 8]),
                    .a_out (a_bus[8*(i*(N+1)+j+1)   +: 8]),
                    .b_out (b_bus[8*((i+1)*N+j)     +: 8]),
                    .acc   (c_out[32*(i*N+j)        +: 32])
                );
            end
        end
    endgenerate

endmodule