`timescale 1ns/1ps

module tb_mac_pe;

    localparam NTRIALS = 200;
    localparam K       = 16;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    reg clear = 1'b0;
    reg signed [7:0] a_in = 8'sd0;
    reg signed [7:0] b_in = 8'sd0;
    wire signed [7:0]  a_out, b_out;
    wire signed [31:0] acc;

    reg [7:0]  a_mem   [0:NTRIALS*K-1];
    reg [7:0]  b_mem   [0:NTRIALS*K-1];
    reg [31:0] exp_mem [0:NTRIALS-1];

    integer t, k;
    integer errors;
    integer fwd_errors;
    reg     chk_en;
    reg signed [7:0] prev_a, prev_b;

    mac_pe dut (
        .clk(clk), .rst_n(rst_n), .clear(clear),
        .a_in(a_in), .b_in(b_in),
        .a_out(a_out), .b_out(b_out), .acc(acc)
    );

    always #5 clk = ~clk;

    // forwarding check: outputs must equal inputs delayed by one clock
    always @(posedge clk) begin
        prev_a <= a_in;
        prev_b <= b_in;
    end
    always @(negedge clk) begin
        if (chk_en && (a_out !== prev_a || b_out !== prev_b))
            fwd_errors = fwd_errors + 1;
    end

    initial begin
        errors     = 0;
        fwd_errors = 0;
        chk_en     = 1'b0;

        $readmemh("pe_a.hex",   a_mem);
        $readmemh("pe_b.hex",   b_mem);
        $readmemh("pe_exp.hex", exp_mem);

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        chk_en = 1'b1;

        for (t = 0; t < NTRIALS; t = t + 1) begin
            // one-cycle clear pulse
            clear = 1'b1; a_in = 8'sd0; b_in = 8'sd0;
            @(negedge clk);
            clear = 1'b0;
            @(negedge clk);

            // stream K operand pairs
            for (k = 0; k < K; k = k + 1) begin
                a_in = a_mem[t*K + k];
                b_in = b_mem[t*K + k];
                @(negedge clk);
            end

            // feed zeros: 1 cycle is needed (prod_r -> acc),
            // the 2nd proves zeros do not disturb the result
            a_in = 8'sd0; b_in = 8'sd0;
            repeat (2) @(negedge clk);

            if (acc !== exp_mem[t]) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("MISMATCH trial %0d: got %0d, expected %0d",
                             t, acc, $signed(exp_mem[t]));
            end
        end

        if (errors == 0 && fwd_errors == 0)
            $display("TEST PASSED: %0d trials", NTRIALS);
        else
            $display("TEST FAILED: %0d acc errors, %0d forwarding errors",
                     errors, fwd_errors);
        $finish;
    end

endmodule