`timescale 1ns/1ps

module tb_mmul_ctrl;

    localparam N       = 16;
    localparam NTRIALS = 12;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    reg start = 1'b0;

    wire        busy, done_pulse, err_pulse;
    wire [31:0] cycles;

    wire        dma_cmd_valid;
    wire [1:0]  dma_cmd;
    reg         dma_cmd_ready = 1'b0;
    reg         dma_done      = 1'b0;
    reg         dma_err       = 1'b0;

    // buffer write/read ports driven by the DMA model
    reg         a_wr_en = 1'b0, b_wr_en = 1'b0;
    reg  [5:0]  wr_addr = 6'd0;
    reg  [31:0] wr_data = 32'd0;
    reg  [7:0]  c_rd_addr = 8'd0;
    wire [63:0] c_rd64;                 // c_buf returns 64-bit beats
    reg         c_half_q;
    always @(posedge clk) c_half_q <= c_rd_addr[0];
    wire [31:0] c_rd_data = c_half_q ? c_rd64[63:32] : c_rd64[31:0];

    wire         feeder_start, feeder_done, feeder_busy, clear;
    wire         drain_start, drain_done, drain_busy;
    wire [63:0]  rd_k;
    wire [127:0] a_data, b_data, a_row_in, b_col_in;
    wire [32*N*N-1:0] c_out;

    reg [31:0] a_words [0:NTRIALS*64-1];
    reg [31:0] b_words [0:NTRIALS*64-1];
    reg [31:0] exp_mem [0:NTRIALS*N*N-1];
    reg [31:0] res_mem [0:N*N-1];

    integer trial      = 0;
    integer inject_err = 0;
    integer seed       = 1;
    integer errors     = 0;
    integer done_count = 0;
    integer err_count  = 0;
    integer lat        = 0;
    integer t;

    mmul_ctrl u_ctrl (
        .clk(clk), .rst_n(rst_n), .start(start), .busy(busy),
        .done_pulse(done_pulse), .err_pulse(err_pulse), .cycles(cycles),
        .dma_cmd_valid(dma_cmd_valid), .dma_cmd(dma_cmd),
        .dma_cmd_ready(dma_cmd_ready), .dma_done(dma_done), .dma_err(dma_err),
        .feeder_start(feeder_start), .feeder_done(feeder_done),
        .drain_start(drain_start), .drain_done(drain_done)
    );

    a_buf u_abuf (
        .clk(clk), .wr_we(a_wr_en ? (wr_addr[0] ? 2'b10 : 2'b01) : 2'b00),
        .wr_addr(wr_addr[5:1]), .wr_data({wr_data, wr_data}),
        .rd_k(rd_k), .rd_data(a_data)
    );
    b_buf u_bbuf (
        .clk(clk), .wr_we(b_wr_en ? (wr_addr[0] ? 2'b10 : 2'b01) : 2'b00),
        .wr_addr(wr_addr[5:1]), .wr_data({wr_data, wr_data}),
        .rd_k(rd_k), .rd_data(b_data)
    );
    mmul_feeder u_feed (
        .clk(clk), .rst_n(rst_n), .start(feeder_start), .busy(feeder_busy),
        .done(feeder_done), .clear(clear), .rd_k(rd_k),
        .a_data(a_data), .b_data(b_data),
        .a_row_in(a_row_in), .b_col_in(b_col_in)
    );
    systolic_array #(.N(N)) u_arr (
        .clk(clk), .rst_n(rst_n), .clear(clear),
        .a_row_in(a_row_in), .b_col_in(b_col_in), .c_out(c_out)
    );
    c_buf u_cbuf (
        .clk(clk), .rst_n(rst_n), .drain_start(drain_start),
        .drain_busy(drain_busy), .drain_done(drain_done),
        .c_in(c_out), .rd_addr(c_rd_addr[7:1]), .rd_data(c_rd64)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (done_pulse) done_count = done_count + 1;
        if (err_pulse)  err_count  = err_count + 1;
    end

    // ------------------------------------------------------------------
    // Behavioral DMA model
    // ------------------------------------------------------------------
    integer m_cmd, m_w, m_i;
    initial begin : dma_model
        forever begin
            @(negedge clk);
            if (rst_n && dma_cmd_valid) begin
                m_cmd = dma_cmd;

                repeat ($random(seed) & 3) @(negedge clk);   // accept delay 0..3
                dma_cmd_ready = 1'b1;
                @(negedge clk);
                dma_cmd_ready = 1'b0;

                case (m_cmd)
                    0: begin
                        for (m_w = 0; m_w < 64; m_w = m_w + 1) begin
                            a_wr_en = 1'b1; wr_addr = m_w;
                            wr_data = a_words[trial*64 + m_w];
                            @(negedge clk);
                        end
                        a_wr_en = 1'b0;
                    end
                    1: begin
                        for (m_w = 0; m_w < 64; m_w = m_w + 1) begin
                            b_wr_en = 1'b1; wr_addr = m_w;
                            wr_data = b_words[trial*64 + m_w];
                            @(negedge clk);
                        end
                        b_wr_en = 1'b0;
                    end
                    default: begin
                        // read all 256 C words, 1-cycle read latency
                        for (m_i = 0; m_i <= 256; m_i = m_i + 1) begin
                            if (m_i > 0) res_mem[m_i - 1] = c_rd_data;
                            if (m_i < 256) c_rd_addr = m_i;
                            @(negedge clk);
                        end
                    end
                endcase

                repeat ($random(seed) & 3) @(negedge clk);   // completion delay 0..3
                if (inject_err != 0 && m_cmd == 1) begin
                    dma_err = 1'b1;
                    @(negedge clk);
                    dma_err = 1'b0;
                end else begin
                    dma_done = 1'b1;
                    @(negedge clk);
                    dma_done = 1'b0;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // One job: start, wait, check
    // ------------------------------------------------------------------
    task run_job(input integer tr, input integer want_err);
        integer i, cyc;
        begin
            trial = tr;
            for (i = 0; i < N*N; i = i + 1) res_mem[i] = 32'hBAD0BAD0;

            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            cyc = 0;

            if (want_err != 0) begin
                while (!err_pulse && cyc < 5000) begin
                    @(negedge clk);
                    cyc = cyc + 1;
                end
                if (cyc >= 5000) begin
                    errors = errors + 1;
                    $display("TIMEOUT: err_pulse never asserted");
                end
                repeat (3) @(negedge clk);
                if (busy) begin
                    errors = errors + 1;
                    $display("ERROR: controller still busy after DMA error");
                end
            end else begin
                while (!done_pulse && cyc < 5000) begin
                    // stray start pulses while busy must be ignored
                    start = (tr == 0) && (cyc == 100 || cyc == 200 || cyc == 300);
                    @(negedge clk);
                    cyc = cyc + 1;
                end
                start = 1'b0;

                if (cyc >= 5000) begin
                    errors = errors + 1;
                    $display("TIMEOUT on job %0d: done_pulse never asserted", tr);
                end else begin
                    for (i = 0; i < N*N; i = i + 1) begin
                        if (res_mem[i] !== exp_mem[tr*N*N + i]) begin
                            errors = errors + 1;
                            if (errors <= 10)
                                $display("MISMATCH job %0d C[%0d][%0d]: got %0d, expected %0d",
                                         tr, i/N, i%N, $signed(res_mem[i]),
                                         $signed(exp_mem[tr*N*N + i]));
                        end
                    end
                end
            end
            repeat (2) @(negedge clk);
        end
    endtask

    initial begin
        $readmemh("ctrl_a_words.hex", a_words);
        $readmemh("ctrl_b_words.hex", b_words);
        $readmemh("ctrl_exp.hex",     exp_mem);

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        for (t = 0; t < NTRIALS; t = t + 1) begin
            run_job(t, 0);
            if (t == 0) lat = cycles;
        end

        // DMA error during LOAD_B, then prove the controller recovers
        inject_err = 1;
        run_job(0, 1);
        inject_err = 0;
        run_job(NTRIALS - 1, 0);

        repeat (3) @(negedge clk);
        if (done_count != NTRIALS + 1) begin
            errors = errors + 1;
            $display("ERROR: expected %0d done pulses, saw %0d", NTRIALS + 1, done_count);
        end
        if (err_count != 1) begin
            errors = errors + 1;
            $display("ERROR: expected 1 err pulse, saw %0d", err_count);
        end

        if (errors == 0)
            $display("TEST PASSED: %0d jobs + error recovery, job latency = %0d cycles",
                     NTRIALS, lat);
        else
            $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

endmodule