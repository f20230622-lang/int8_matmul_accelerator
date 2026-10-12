`timescale 1ns/1ps

// Multiply-accumulate core, mapped onto a DSP48E1.
// Only 'clear' resets it: synchronous, zeroes product and accumulator.
(* use_dsp = "yes" *)
module mac_core_dsp (
    input  wire               clk,
    input  wire               clear,
    input  wire signed [7:0]  a,
    input  wire signed [7:0]  b,
    output reg  signed [31:0] acc
);
    reg signed [15:0] prod_r;

    always @(posedge clk) begin
        if (clear) begin
            prod_r <= 16'sd0;
            acc    <= 32'sd0;
        end else begin
            prod_r <= a * b;
            acc    <= acc + prod_r;
        end
    end
endmodule

// Same logic, forced into fabric (LUTs + carry chains).
(* use_dsp = "no" *)
module mac_core_lut (
    input  wire               clk,
    input  wire               clear,
    input  wire signed [7:0]  a,
    input  wire signed [7:0]  b,
    output reg  signed [31:0] acc
);
    reg signed [15:0] prod_r;

    always @(posedge clk) begin
        if (clear) begin
            prod_r <= 16'sd0;
            acc    <= 32'sd0;
        end else begin
            prod_r <= a * b;
            acc    <= acc + prod_r;
        end
    end
endmodule

module mac_pe #(
    parameter USE_DSP = 1
) (
    input  wire               clk,
    input  wire               rst_n,   // joins 'clear' (system reset also clears the accumulator)
    input  wire               clear,   // takes effect ONE CYCLE after it is asserted
    input  wire signed [7:0]  a_in,
    input  wire signed [7:0]  b_in,
    output reg  signed [7:0]  a_out,   // a_in delayed 1 cycle
    output reg  signed [7:0]  b_out,   // b_in delayed 1 cycle
    output wire signed [31:0] acc
);

    (* dont_touch = "true" *) reg clear_q;   // keep one copy per PE: stops synthesis merging them                       // local, registered copy: keeps fanout per net small

    // power-up values (FPGA flip-flops start at 0); no reset needed on the data path
    initial begin
        a_out   = 8'sd0;
        b_out   = 8'sd0;
        clear_q = 1'b1;
    end

    always @(posedge clk) begin
        a_out   <= a_in;
        b_out   <= b_in;
        clear_q <= clear | ~rst_n;
    end

    generate
        if (USE_DSP != 0) begin : g_dsp
            mac_core_dsp u_core (
                .clk(clk), .clear(clear_q),
                .a(a_in), .b(b_in), .acc(acc)
            );
        end else begin : g_lut
            mac_core_lut u_core (
                .clk(clk), .clear(clear_q),
                .a(a_in), .b(b_in), .acc(acc)
            );
        end
    endgenerate

endmodule