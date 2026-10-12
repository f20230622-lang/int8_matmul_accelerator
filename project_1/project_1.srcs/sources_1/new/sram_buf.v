`timescale 1ns/1ps

// Simple dual-port RAM: 1 write port, 1 read port, registered read (1-cycle latency).
// Read-during-write to the same address returns the OLD data.
module sram_buf #(
    parameter DATA_W = 8,
    parameter ADDR_W = 4
) (
    input  wire                 clk,
    input  wire                 we,
    input  wire [ADDR_W-1:0]    waddr,
    input  wire [DATA_W-1:0]    wdata,
    input  wire [ADDR_W-1:0]    raddr,
    output reg  [DATA_W-1:0]    rdata
);

    (* ram_style = "distributed" *)
    reg [DATA_W-1:0] mem [0:(1<<ADDR_W)-1];

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end

endmodule