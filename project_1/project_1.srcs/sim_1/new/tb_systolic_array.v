`timescale 1ns/1ps

module tb_systolic_array;

    localparam N       = 16;
    localparam NTRIALS = 24;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    reg clear = 1'b0;
    reg  [8*N-1:0]    a_row_in = 0;
    reg  [8*N-1:0]    b_col_in = 0;
    wire [32*N*N-1:0] c_out;

    reg [7:0]  a_mem   [0:NTRIALS*N*N-1];
    reg [7:0]  b_mem   [0:NTRIALS*N*N-1];
    reg [31:0] exp_mem [0:NTRIALS*N*N-1];

    integer t, tt, i, j, idx;
    integer errors;
    reg [31:0] got;

    systolic_array #(.N(N)) dut (
        .clk(clk), .rst_n(rst_n), .clear(clear),
        .a_row_in(a_row_in), .b_col_in(b_col_in),
        .c_out(c_out)
    );

    always #5 clk = ~clk;

    initial begin
        errors = 0;

        $readmemh("sa_a.hex",   a_mem);
        $readmemh("sa_b.hex",   b_mem);
        $readmemh("sa_exp.hex", exp_mem);

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        for (t = 0; t < NTRIALS; t = t + 1) begin
            // one-cycle clear, boundary inputs are zero
            clear = 1'b1; a_row_in = 0; b_col_in = 0;
            @(negedge clk);
            clear = 1'b0;
            @(negedge clk);

            // inject skewed operands; cycles beyond 2N-2 flush zeros
            for (tt = 0; tt <= 3*N-3; tt = tt + 1) begin
                for (i = 0; i < N; i = i + 1) begin
                    if (tt-i >= 0 && tt-i < N)
                        a_row_in[8*i +: 8] = a_mem[t*N*N + i*N + (tt-i)];
                    else
                        a_row_in[8*i +: 8] = 8'd0;
                end
                for (j = 0; j < N; j = j + 1) begin
                    if (tt-j >= 0 && tt-j < N)
                        b_col_in[8*j +: 8] = b_mem[t*N*N + (tt-j)*N + j];
                    else
                        b_col_in[8*j +: 8] = 8'd0;
                end
                @(negedge clk);
            end

            a_row_in = 0; b_col_in = 0;
            repeat (2) @(negedge clk);

            // compare all 256 results
            for (idx = 0; idx < N*N; idx = idx + 1) begin
                got = c_out[32*idx +: 32];
                if (got !== exp_mem[t*N*N + idx]) begin
                    errors = errors + 1;
                    if (errors <= 10)
                        $display("MISMATCH trial %0d C[%0d][%0d]: got %0d, expected %0d",
                                 t, idx/N, idx%N, $signed(got),
                                 $signed(exp_mem[t*N*N + idx]));
                end
            end
        end

        if (errors == 0)
            $display("TEST PASSED: %0d trials x %0d elements", NTRIALS, N*N);
        else
            $display("TEST FAILED: %0d element errors", errors);
        $finish;
    end

endmodule