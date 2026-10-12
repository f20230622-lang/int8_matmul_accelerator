`timescale 1ns/1ps

module tb_c_buf;

    localparam NTRIALS = 16;

    reg clk         = 1'b0;
    reg rst_n       = 1'b0;
    reg drain_start = 1'b0;
    reg [32*256-1:0] c_in = 0;
    reg [7:0] rd_addr = 8'd0;
    wire drain_busy, drain_done;
    wire [63:0] rd64;                   // c_buf returns 64-bit beats
    reg         half_q;
    always @(posedge clk) half_q <= rd_addr[0];
    wire [31:0] rd_data = half_q ? rd64[63:32] : rd64[31:0];

    reg [31:0] c_mem [0:NTRIALS*256-1];

    integer t, idx, pass, cyc, lat, cur, prev, errors;

    c_buf dut (
        .clk(clk), .rst_n(rst_n),
        .drain_start(drain_start), .drain_busy(drain_busy), .drain_done(drain_done),
        .c_in(c_in), .rd_addr(rd_addr[7:1]), .rd_data(rd64)
    );

    always #5 clk = ~clk;

    initial begin
        errors = 0;
        lat    = 0;
        prev   = 0;
        $readmemh("cbuf_c.hex", c_mem);

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        for (t = 0; t < NTRIALS; t = t + 1) begin
            // present the 256 accumulator values
            for (idx = 0; idx < 256; idx = idx + 1)
                c_in[32*idx +: 32] = c_mem[t*256 + idx];

            drain_start = 1'b1;
            @(negedge clk);
            drain_start = 1'b0;

            cyc = 0;
            while (!drain_done && cyc < 100) begin
                @(negedge clk);
                cyc = cyc + 1;
            end
            if (t == 0) lat = cyc;
            if (cyc >= 100) begin
                errors = errors + 1;
                $display("TIMEOUT on trial %0d: drain_done never asserted", t);
            end

            // accumulators may now change; the buffer must not follow
            c_in = {256{32'hFFFFFFFF}};

            // pass 0: sequential reads, pass 1: scrambled order (bijection mod 256)
            for (pass = 0; pass < 2; pass = pass + 1) begin
                for (idx = 0; idx <= 256; idx = idx + 1) begin
                    if (idx > 0) begin
                        if (rd_data !== c_mem[t*256 + prev]) begin
                            errors = errors + 1;
                            if (errors <= 10)
                                $display("MISMATCH trial %0d pass %0d addr %0d: got %h want %h",
                                         t, pass, prev, rd_data, c_mem[t*256 + prev]);
                        end
                    end
                    if (pass == 0) cur = idx & 255;
                    else           cur = (idx*37 + 5) & 255;
                    rd_addr = cur;
                    prev    = cur;
                    @(negedge clk);
                end
            end
        end

        if (errors == 0)
            $display("TEST PASSED: %0d trials x 256 words, drain = %0d cycles", NTRIALS, lat);
        else
            $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

endmodule