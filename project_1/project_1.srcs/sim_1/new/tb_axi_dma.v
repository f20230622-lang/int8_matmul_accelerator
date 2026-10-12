
`timescale 1ns/1ps

module tb_axi_dma;

    localparam MEMWORDS = 4096;
    localparam [31:0] BAD_BASE = 32'h0000_3000;
    localparam MAXJOBS = 64;

    reg clk = 1'b0;
    reg rst_n = 1'b0;

    reg cmd_valid = 1'b0;
    reg [1:0] cmd = 2'd0;
    wire cmd_ready, done, err;
    reg [31:0] a_addr = 0, b_addr = 0, c_addr = 0;

    wire [1:0] a_wr_we, b_wr_we;
    wire [4:0] buf_wr_addr;
    wire [63:0] buf_wr_data;
    wire [6:0] c_rd_addr;
    wire [63:0] c_rd_data;
    reg [63:0] rd_k = 0;
    wire [127:0] a_rd_data, b_rd_data;

    reg drain_start = 0;
    wire drain_busy, drain_done;
    reg [32*256-1:0] c_in = 0;

    wire [31:0] awaddr;
    wire [7:0] awlen;
    wire [2:0] awsize;
    wire [1:0] awburst;
    wire awvalid, awready;

    wire [63:0] wdata;
    wire [7:0] wstrb;
    wire wlast, wvalid, wready;

    wire [1:0] bresp;
    wire bvalid, bready;

    wire [31:0] araddr;
    wire [7:0] arlen;
    wire [2:0] arsize;
    wire [1:0] arburst;
    wire arvalid, arready;

    wire [63:0] rdata;
    wire [1:0] rresp;
    wire rlast, rvalid, rready;

    axi_dma dut (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(cmd_valid), .cmd(cmd), .cmd_ready(cmd_ready),
        .done(done), .err(err),
        .a_addr(a_addr), .b_addr(b_addr), .c_addr(c_addr),
        .a_wr_we(a_wr_we), .b_wr_we(b_wr_we),
        .buf_wr_addr(buf_wr_addr), .buf_wr_data(buf_wr_data),
        .c_rd_addr(c_rd_addr), .c_rd_data(c_rd_data),
        .m_axi_awaddr(awaddr), .m_axi_awlen(awlen),
        .m_axi_awsize(awsize), .m_axi_awburst(awburst),
        .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb),
        .m_axi_wlast(wlast), .m_axi_wvalid(wvalid),
        .m_axi_wready(wready),
        .m_axi_bresp(bresp), .m_axi_bvalid(bvalid),
        .m_axi_bready(bready),
        .m_axi_araddr(araddr), .m_axi_arlen(arlen),
        .m_axi_arsize(arsize), .m_axi_arburst(arburst),
        .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rdata(rdata), .m_axi_rresp(rresp),
        .m_axi_rlast(rlast), .m_axi_rvalid(rvalid),
        .m_axi_rready(rready)
    );

    a_buf u_abuf (
        .clk(clk), .wr_we(a_wr_we), .wr_addr(buf_wr_addr),
        .wr_data(buf_wr_data), .rd_k(rd_k), .rd_data(a_rd_data)
    );

    b_buf u_bbuf (
        .clk(clk), .wr_we(b_wr_we), .wr_addr(buf_wr_addr),
        .wr_data(buf_wr_data), .rd_k(rd_k), .rd_data(b_rd_data)
    );

    c_buf u_cbuf (
        .clk(clk), .rst_n(rst_n), .drain_start(drain_start),
        .drain_busy(drain_busy), .drain_done(drain_done),
        .c_in(c_in), .rd_addr(c_rd_addr), .rd_data(c_rd_data)
    );

    axi_mem_model #(.BAD_BASE(BAD_BASE)) u_mem (
        .clk(clk), .rst_n(rst_n),
        .awaddr(awaddr), .awlen(awlen),
        .awsize(awsize), .awburst(awburst),
        .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb),
        .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .araddr(araddr), .arlen(arlen),
        .arsize(arsize), .arburst(arburst),
        .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp),
        .rlast(rlast), .rvalid(rvalid), .rready(rready)
    );

    always #5 clk = ~clk;

    reg [31:0] script [0:3+8*MAXJOBS-1];
    reg [31:0] cmat [0:256*MAXJOBS-1];

    integer errors = 0;
    integer njobs, exp_ar, exp_aw;
    integer j, base, idx, cyc;
    integer cmd_cycles;
    integer a_sum = 0, b_sum = 0, c_sum = 0;
    integer a_count = 0, b_count = 0, c_count = 0;

    reg [31:0] ja, jb, jc, t3, t4, t5;
    reg jeA, jeB, jeC, got_err;

    task send_cmd;
        input [1:0] c;
        output e;
        output integer elapsed_cycles;
        integer cy;
        begin
            @(negedge clk);
            cmd = c;
            cmd_valid = 1'b1;

            @(posedge clk);
            while (!cmd_ready)
                @(posedge clk);

            @(negedge clk);
            cmd_valid = 1'b0;

            cy = 0;
            while (!done && !err && cy < 20000) begin
                @(negedge clk);
                cy = cy + 1;
            end

            elapsed_cycles = cy;

            if (cy >= 20000) begin
                errors = errors + 1;
                $display("TIMEOUT: command %0d", c);
                e = 1'b1;
            end else begin
                e = err;
            end
        end
    endtask

    task verify_a;
        input [31:0] bs;
        integer k, i;
        reg [31:0] w;
        begin
            for (k = 0; k < 16; k = k + 1) begin
                rd_k = {16{k[3:0]}};
                @(negedge clk);
                for (i = 0; i < 16; i = i + 1) begin
                    w = u_mem.dram[(bs >> 2) + i*4 + (k >> 2)];
                    if (a_rd_data[8*i +: 8] !== w[8*(k & 3) +: 8]) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("A mismatch [%0d][%0d]", i, k);
                    end
                end
            end
        end
    endtask

    task verify_b;
        input [31:0] bs;
        integer k, jj;
        reg [31:0] w;
        begin
            for (k = 0; k < 16; k = k + 1) begin
                rd_k = {16{k[3:0]}};
                @(negedge clk);
                for (jj = 0; jj < 16; jj = jj + 1) begin
                    w = u_mem.dram[(bs >> 2) + k*4 + (jj >> 2)];
                    if (b_rd_data[8*jj +: 8] !== w[8*(jj & 3) +: 8]) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("B mismatch [%0d][%0d]", k, jj);
                    end
                end
            end
        end
    endtask

    initial begin
        $readmemh("dma_dram_init.hex", u_mem.dram);
        $readmemh("dma_script.hex", script);
        $readmemh("dma_cmat.hex", cmat);

        njobs = script[0];
        exp_ar = script[1];
        exp_aw = script[2];

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        for (j = 0; j < njobs; j = j + 1) begin
            base = 3 + 8*j;
            ja = script[base];
            jb = script[base+1];
            jc = script[base+2];
            t3 = script[base+3]; jeA = t3[0];
            t4 = script[base+4]; jeB = t4[0];
            t5 = script[base+5]; jeC = t5[0];

            for (idx = 0; idx < 256; idx = idx + 1)
                c_in[32*idx +: 32] = cmat[j*256 + idx];

            drain_start = 1'b1;
            @(negedge clk);
            drain_start = 1'b0;

            cyc = 0;
            while (!drain_done && cyc < 100) begin
                @(negedge clk);
                cyc = cyc + 1;
            end
            repeat (2) @(negedge clk);

            a_addr = ja;
            b_addr = jb;
            c_addr = jc;

            send_cmd(2'd0, got_err, cmd_cycles);
            $display("PERF job=%0d op=LOAD_A cycles=%0d err=%0d",
                     j, cmd_cycles, got_err);
            if (got_err !== jeA) begin
                errors = errors + 1;
                $display("job %0d LOAD_A error mismatch", j);
            end else if (!jeA) begin
                a_sum = a_sum + cmd_cycles;
                a_count = a_count + 1;
                verify_a(ja);
            end

            send_cmd(2'd1, got_err, cmd_cycles);
            $display("PERF job=%0d op=LOAD_B cycles=%0d err=%0d",
                     j, cmd_cycles, got_err);
            if (got_err !== jeB) begin
                errors = errors + 1;
                $display("job %0d LOAD_B error mismatch", j);
            end else if (!jeB) begin
                b_sum = b_sum + cmd_cycles;
                b_count = b_count + 1;
                verify_b(jb);
            end

            send_cmd(2'd2, got_err, cmd_cycles);
            $display("PERF job=%0d op=STORE_C cycles=%0d err=%0d",
                     j, cmd_cycles, got_err);
            if (got_err !== jeC) begin
                errors = errors + 1;
                $display("job %0d STORE_C error mismatch", j);
            end else if (!jeC) begin
                c_sum = c_sum + cmd_cycles;
                c_count = c_count + 1;
            end
        end

        repeat (10) @(negedge clk);
        $writememh("dma_dram_final.hex", u_mem.dram);

        if (u_mem.ar_hs_count != exp_ar) begin
            errors = errors + 1;
            $display("AR bursts: saw %0d expected %0d",
                     u_mem.ar_hs_count, exp_ar);
        end

        if (u_mem.aw_hs_count != exp_aw) begin
            errors = errors + 1;
            $display("AW bursts: saw %0d expected %0d",
                     u_mem.aw_hs_count, exp_aw);
        end

        if (u_mem.proto_err != 0) begin
            errors = errors + 1;
            $display("Protocol errors: %0d", u_mem.proto_err);
        end

        $display("========== DMA PERFORMANCE ==========");
        if (a_count > 0)
            $display("AVG LOAD_A: %0d cycles (%0d samples)",
                     a_sum/a_count, a_count);
        if (b_count > 0)
            $display("AVG LOAD_B: %0d cycles (%0d samples)",
                     b_sum/b_count, b_count);
        if (c_count > 0)
            $display("AVG STORE_C: %0d cycles (%0d samples)",
                     c_sum/c_count, c_count);

        if (errors == 0)
            $display("TEST PASSED: %0d jobs", njobs);
        else
            $display("TEST FAILED: %0d errors", errors);

        $finish;
    end

    initial begin
        #20000000;
        $display("TEST FAILED: watchdog timeout");
        $finish;
    end

endmodule
