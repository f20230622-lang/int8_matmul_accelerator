`timescale 1ns/1ps

module tb_mmul_bufs;

    localparam NTRIALS = 16;

    reg clk = 1'b0;
    reg [1:0]  wr_we   = 2'b00;
    reg [4:0]  wr_addr = 5'd0;
    reg [63:0] a_wdata = 64'd0;
    reg [63:0] b_wdata = 64'd0;
    reg [63:0] a_rd_k  = 64'd0;
    reg [63:0] b_rd_k  = 64'd0;
    wire [127:0] a_rd_data;
    wire [127:0] b_rd_data;

    reg [31:0] a_words [0:NTRIALS*64-1];
    reg [31:0] b_words [0:NTRIALS*64-1];
    reg [7:0]  a_bytes [0:NTRIALS*256-1];
    reg [7:0]  b_bytes [0:NTRIALS*256-1];

    integer t, w, r, i, mode, idx;
    integer errors;
    reg [7:0] got, want;

    a_buf dut_a (
        .clk(clk), .wr_we(wr_we), .wr_addr(wr_addr), .wr_data(a_wdata),
        .rd_k(a_rd_k), .rd_data(a_rd_data)
    );
    b_buf dut_b (
        .clk(clk), .wr_we(wr_we), .wr_addr(wr_addr), .wr_data(b_wdata),
        .rd_k(b_rd_k), .rd_data(b_rd_data)
    );

    always #5 clk = ~clk;

    initial begin
        errors = 0;
        $readmemh("buf_a_words.hex", a_words);
        $readmemh("buf_b_words.hex", b_words);
        $readmemh("buf_a_bytes.hex", a_bytes);
        $readmemh("buf_b_bytes.hex", b_bytes);

        repeat (4) @(negedge clk);

        for (t = 0; t < NTRIALS; t = t + 1) begin
            mode = t % 3;

            if (mode == 0) begin
                // 32 full 64-bit beats, both halves at once
                for (w = 0; w < 32; w = w + 1) begin
                    wr_we   = 2'b11;
                    wr_addr = w;
                    a_wdata = {a_words[t*64 + 2*w + 1], a_words[t*64 + 2*w]};
                    b_wdata = {b_words[t*64 + 2*w + 1], b_words[t*64 + 2*w]};
                    @(negedge clk);
                end
            end else begin
                // 64 single-word writes (one half enabled), ascending or reversed
                for (w = 0; w < 64; w = w + 1) begin
                    idx     = (mode == 1) ? w : (63 - w);
                    wr_we   = idx[0] ? 2'b10 : 2'b01;
                    wr_addr = idx >> 1;
                    a_wdata = {2{a_words[t*64 + idx]}};
                    b_wdata = {2{b_words[t*64 + idx]}};
                    @(negedge clk);
                end
            end

            // junk with write disabled must not change anything
            wr_we   = 2'b00;
            wr_addr = 5'd5;
            a_wdata = 64'hDEADBEEFDEADBEEF;
            b_wdata = 64'hDEADBEEFDEADBEEF;
            repeat (2) @(negedge clk);

            // read back with a different index per bank
            for (r = 0; r < 16; r = r + 1) begin
                for (i = 0; i < 16; i = i + 1) begin
                    a_rd_k[4*i +: 4] = (r + i) & 15;
                    b_rd_k[4*i +: 4] = (r + i) & 15;
                end
                @(negedge clk);   // 1-cycle read latency
                for (i = 0; i < 16; i = i + 1) begin
                    got  = a_rd_data[8*i +: 8];
                    want = a_bytes[t*256 + i*16 + ((r + i) & 15)];
                    if (got !== want) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("A MISMATCH trial %0d (mode %0d) A[%0d][%0d]: got %h want %h",
                                     t, mode, i, (r+i)&15, got, want);
                    end
                    got  = b_rd_data[8*i +: 8];
                    want = b_bytes[t*256 + ((r + i) & 15)*16 + i];
                    if (got !== want) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("B MISMATCH trial %0d (mode %0d) B[%0d][%0d]: got %h want %h",
                                     t, mode, (r+i)&15, i, got, want);
                    end
                end
            end
        end

        if (errors == 0)
            $display("TEST PASSED: %0d trials x 2 buffers x 256 elements", NTRIALS);
        else
            $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

endmodule