`timescale 1ns/1ps

module tb_axi_dma;

    localparam MEMWORDS = 4096;                    // 16 KB
    localparam [31:0] BAD_BASE = 32'h0000_3000;    // accesses >= this return SLVERR
    localparam MAXJOBS  = 64;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;

    // command channel
    reg         cmd_valid = 1'b0;
    reg  [1:0]  cmd       = 2'd0;
    wire        cmd_ready, done, err;
    reg  [31:0] a_addr = 32'd0, b_addr = 32'd0, c_addr = 32'd0;

    // buffers
    wire [1:0] a_wr_we, b_wr_we;
    wire [4:0] buf_wr_addr;
    wire [63:0] buf_wr_data;
    wire [6:0] c_rd_addr;
    wire [63:0] c_rd_data;
    reg  [63:0]  rd_k = 64'd0;
    wire [127:0] a_rd_data, b_rd_data;

    reg              drain_start = 1'b0;
    wire             drain_busy, drain_done;
    reg [32*256-1:0] c_in = 0;

    // AXI
    wire [31:0] awaddr;  wire [7:0] awlen;  wire [2:0] awsize;  wire [1:0] awburst;
    wire        awvalid; reg awready = 1'b0;
    wire [31:0] wdata;   wire [3:0] wstrb;  wire wlast;  wire wvalid;  wire wready;
    reg  [1:0]  bresp = 2'b00;  reg bvalid = 1'b0;  wire bready;
    wire [31:0] araddr;  wire [7:0] arlen;  wire [2:0] arsize;  wire [1:0] arburst;
    wire        arvalid; reg arready = 1'b0;
    reg  [31:0] rdata = 32'd0;  reg [1:0] rresp = 2'b00;  reg rlast = 1'b0;  reg rvalid = 1'b0;
    wire        rready;

    axi_dma dut (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(cmd_valid), .cmd(cmd), .cmd_ready(cmd_ready),
        .done(done), .err(err),
        .a_addr(a_addr), .b_addr(b_addr), .c_addr(c_addr),
        .a_wr_we(a_wr_we), .b_wr_we(b_wr_we),
        .buf_wr_addr(buf_wr_addr), .buf_wr_data(buf_wr_data),
        .c_rd_addr(c_rd_addr), .c_rd_data(c_rd_data),
        .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
        .m_axi_awburst(awburst), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
        .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize),
        .m_axi_arburst(arburst), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast),
        .m_axi_rvalid(rvalid), .m_axi_rready(rready)
    );

    a_buf u_abuf (
        .clk(clk), .wr_we(a_wr_we), .wr_addr(buf_wr_addr), .wr_data(buf_wr_data),
        .rd_k(rd_k), .rd_data(a_rd_data)
    );
    b_buf u_bbuf (
        .clk(clk), .wr_we(b_wr_we), .wr_addr(buf_wr_addr), .wr_data(buf_wr_data),
        .rd_k(rd_k), .rd_data(b_rd_data)
    );
    c_buf u_cbuf (
        .clk(clk), .rst_n(rst_n), .drain_start(drain_start),
        .drain_busy(drain_busy), .drain_done(drain_done),
        .c_in(c_in), .rd_addr(c_rd_addr), .rd_data(c_rd_data)
    );

    always #5 clk = ~clk;

    // ------------------------------------------------------------------
    // AXI4 slave memory model
    // ------------------------------------------------------------------
    reg [31:0] dram [0:MEMWORDS-1];

    integer seed_ar = 11, seed_r = 22, seed_aw = 33, seed_w = 44, seed_b = 55;
    integer ar_hs_count = 0, aw_hs_count = 0, proto_err = 0;

    wire [31:0] wmask = {{8{wstrb[3]}}, {8{wstrb[2]}}, {8{wstrb[1]}}, {8{wstrb[0]}}};

    // ---- read side: AR queue + R engine
    reg [31:0] arq_addr [0:7];
    reg [7:0]  arq_len  [0:7];
    reg [2:0]  arq_wp, arq_rp;
    reg [3:0]  arq_cnt;
    reg        r_active;
    reg [31:0] r_addr_cur;
    reg [8:0]  r_left;

    always @(posedge clk) begin
        if (!rst_n) begin
            arready <= 1'b0;
            arq_wp <= 3'd0; arq_rp <= 3'd0; arq_cnt <= 4'd0;
            r_active <= 1'b0; r_addr_cur <= 32'd0; r_left <= 9'd0;
            rvalid <= 1'b0; rdata <= 32'd0; rresp <= 2'b00; rlast <= 1'b0;
        end else begin
            arready <= (arq_cnt <= 4) && ((($random(seed_ar)) & 3) != 0);

            if (arvalid && arready) begin
                arq_addr[arq_wp] <= araddr;
                arq_len[arq_wp]  <= arlen;
                arq_wp <= arq_wp + 3'd1;
                ar_hs_count = ar_hs_count + 1;
                if (arlen != 8'd15 || arsize != 3'd2 || arburst != 2'b01 || araddr[5:0] != 6'd0)
                    proto_err = proto_err + 1;
            end
            arq_cnt <= arq_cnt + ((arvalid && arready) ? 4'd1 : 4'd0)
                               - ((!r_active && arq_cnt != 0) ? 4'd1 : 4'd0);

            if (rvalid && rready) rvalid <= 1'b0;

            if (!r_active) begin
                if (arq_cnt != 0) begin
                    r_active   <= 1'b1;
                    r_addr_cur <= arq_addr[arq_rp];
                    r_left     <= {1'b0, arq_len[arq_rp]} + 9'd1;
                    arq_rp     <= arq_rp + 3'd1;
                end
            end else if (!rvalid || rready) begin
                if (r_left != 0 && ((($random(seed_r)) & 3) != 0)) begin
                    rvalid <= 1'b1;
                    if (r_addr_cur >= BAD_BASE) begin
                        rdata <= 32'd0;
                        rresp <= 2'b10;
                    end else begin
                        rdata <= dram[r_addr_cur[13:2]];
                        rresp <= 2'b00;
                    end
                    rlast      <= (r_left == 9'd1);
                    r_addr_cur <= r_addr_cur + 32'd4;
                    r_left     <= r_left - 9'd1;
                    if (r_left == 9'd1) r_active <= 1'b0;
                end
            end
        end
    end

    // ---- write side: AW queue + W engine + B queue
    reg [31:0] awq_addr [0:7];
    reg [7:0]  awq_len  [0:7];
    reg [2:0]  awq_wp, awq_rp;
    reg [3:0]  awq_cnt;
    reg        w_active, w_bad, w_rnd_q;
    reg [31:0] w_addr_cur;
    reg [8:0]  w_left;
    reg [1:0]  bq [0:31];
    reg [4:0]  bq_wp, bq_rp;
    reg [5:0]  bq_cnt;
    reg        b_push, b_pop;

    assign wready = w_active && w_rnd_q;

    always @(posedge clk) begin
        if (!rst_n) begin
            awready <= 1'b0; w_rnd_q <= 1'b0;
            awq_wp <= 3'd0; awq_rp <= 3'd0; awq_cnt <= 4'd0;
            w_active <= 1'b0; w_bad <= 1'b0; w_addr_cur <= 32'd0; w_left <= 9'd0;
            bq_wp <= 5'd0; bq_rp <= 5'd0; bq_cnt <= 6'd0;
            bvalid <= 1'b0; bresp <= 2'b00;
        end else begin
            b_push = 1'b0;
            b_pop  = 1'b0;

            awready <= (awq_cnt <= 4) && ((($random(seed_aw)) & 3) != 0);
            w_rnd_q <= ((($random(seed_w)) & 3) != 0);

            if (awvalid && awready) begin
                awq_addr[awq_wp] <= awaddr;
                awq_len[awq_wp]  <= awlen;
                awq_wp <= awq_wp + 3'd1;
                aw_hs_count = aw_hs_count + 1;
                if (awlen != 8'd15 || awsize != 3'd2 || awburst != 2'b01 || awaddr[5:0] != 6'd0)
                    proto_err = proto_err + 1;
            end
            awq_cnt <= awq_cnt + ((awvalid && awready) ? 4'd1 : 4'd0)
                               - ((!w_active && awq_cnt != 0) ? 4'd1 : 4'd0);

            if (!w_active) begin
                if (awq_cnt != 0) begin
                    w_active   <= 1'b1;
                    w_addr_cur <= awq_addr[awq_rp];
                    w_left     <= {1'b0, awq_len[awq_rp]} + 9'd1;
                    w_bad      <= (awq_addr[awq_rp] >= BAD_BASE);
                    awq_rp     <= awq_rp + 3'd1;
                end
            end else if (wvalid && wready) begin
                if (!w_bad)
                    dram[w_addr_cur[13:2]] <= (dram[w_addr_cur[13:2]] & ~wmask) | (wdata & wmask);
                w_addr_cur <= w_addr_cur + 32'd4;
                w_left     <= w_left - 9'd1;
                if ((w_left == 9'd1) != wlast) proto_err = proto_err + 1;
                if (w_left == 9'd1) begin
                    w_active <= 1'b0;
                    bq[bq_wp] <= w_bad ? 2'b10 : 2'b00;
                    bq_wp <= bq_wp + 5'd1;
                    b_push = 1'b1;
                end
            end

            if (bvalid && bready) bvalid <= 1'b0;
            if ((!bvalid || bready) && bq_cnt != 0 && ((($random(seed_b)) & 3) != 0)) begin
                bvalid <= 1'b1;
                bresp  <= bq[bq_rp];
                bq_rp  <= bq_rp + 5'd1;
                b_pop  = 1'b1;
            end
            bq_cnt <= bq_cnt + (b_push ? 6'd1 : 6'd0) - (b_pop ? 6'd1 : 6'd0);
        end
    end

    // ------------------------------------------------------------------
    // Test sequencing
    // ------------------------------------------------------------------
    reg [31:0] script [0:3+8*MAXJOBS-1];
    reg [31:0] cmat   [0:256*MAXJOBS-1];

    integer errors = 0;
    integer njobs, exp_ar, exp_aw, j, base, idx, cyc;
    reg [31:0] ja, jb, jc, t3, t4, t5;
    reg        jeA, jeB, jeC, got_err;

    task send_cmd(input [1:0] c, input integer job_id, output e);
        integer cy;
        reg [8*8-1:0] op_name;
        begin
            case (c)
                2'd0: op_name = "LOAD_A";
                2'd1: op_name = "LOAD_B";
                default: op_name = "STORE_C";
            endcase
            cmd = c;
            cmd_valid = 1'b1;
            @(posedge clk);
            while (!cmd_ready) @(posedge clk);
            @(negedge clk);
            cmd_valid = 1'b0;
            cy = 0;
            while (!done && !err && cy < 20000) begin
                @(negedge clk);
                cy = cy + 1;
            end
            if (cy >= 20000) begin
                errors = errors + 1;
                $display("TIMEOUT: command %0d never finished", c);
            end
            e = err;
            $display("PERF job=%0d op=%0s cycles=%0d err=%0d", job_id, op_name, cy, e);
        end
    endtask

    // A[i][k] = byte (k&3) of word (i*4 + k/4)
    task verify_a(input [31:0] bs);
        integer k, i;
        reg [31:0] w;
        begin
            for (k = 0; k < 16; k = k + 1) begin
                rd_k = {16{k[3:0]}};
                @(negedge clk);
                for (i = 0; i < 16; i = i + 1) begin
                    w = dram[(bs >> 2) + i*4 + (k >> 2)];
                    if (a_rd_data[8*i +: 8] !== w[8*(k & 3) +: 8]) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("A buffer mismatch A[%0d][%0d]: got %h want %h",
                                     i, k, a_rd_data[8*i +: 8], w[8*(k & 3) +: 8]);
                    end
                end
            end
        end
    endtask

    // B[k][j] = byte (j&3) of word (k*4 + j/4)
    task verify_b(input [31:0] bs);
        integer k, jj;
        reg [31:0] w;
        begin
            for (k = 0; k < 16; k = k + 1) begin
                rd_k = {16{k[3:0]}};
                @(negedge clk);
                for (jj = 0; jj < 16; jj = jj + 1) begin
                    w = dram[(bs >> 2) + k*4 + (jj >> 2)];
                    if (b_rd_data[8*jj +: 8] !== w[8*(jj & 3) +: 8]) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("B buffer mismatch B[%0d][%0d]: got %h want %h",
                                     k, jj, b_rd_data[8*jj +: 8], w[8*(jj & 3) +: 8]);
                    end
                end
            end
        end
    endtask

    initial begin
        $readmemh("dma_dram_init.hex", dram);
        $readmemh("dma_script.hex",    script);
        $readmemh("dma_cmat.hex",      cmat);
        njobs  = script[0];
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
            t3 = script[base+3];  jeA = t3[0];
            t4 = script[base+4];  jeB = t4[0];
            t5 = script[base+5];  jeC = t5[0];

            // fill c_buf with this job's C matrix via the real drain path
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

            a_addr = ja; b_addr = jb; c_addr = jc;

            send_cmd(2'd0, j, got_err);
            if (got_err !== jeA) begin
                errors = errors + 1;
                $display("job %0d LOAD_A: err=%0d expected %0d", j, got_err, jeA);
            end else if (!jeA) verify_a(ja);

            send_cmd(2'd1, j, got_err);
            if (got_err !== jeB) begin
                errors = errors + 1;
                $display("job %0d LOAD_B: err=%0d expected %0d", j, got_err, jeB);
            end else if (!jeB) verify_b(jb);

            send_cmd(2'd2, j, got_err);
            if (got_err !== jeC) begin
                errors = errors + 1;
                $display("job %0d STORE_C: err=%0d expected %0d", j, got_err, jeC);
            end
        end

        repeat (10) @(negedge clk);
        $writememh("dma_dram_final.hex", dram);

        if (ar_hs_count != exp_ar) begin
            errors = errors + 1;
            $display("AR bursts: saw %0d, expected %0d", ar_hs_count, exp_ar);
        end
        if (aw_hs_count != exp_aw) begin
            errors = errors + 1;
            $display("AW bursts: saw %0d, expected %0d", aw_hs_count, exp_aw);
        end
        if (proto_err != 0) begin
            errors = errors + 1;
            $display("AXI protocol check failures: %0d", proto_err);
        end

        if (errors == 0)
            $display("TEST PASSED: %0d jobs, %0d AR bursts, %0d AW bursts",
                     njobs, ar_hs_count, aw_hs_count);
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