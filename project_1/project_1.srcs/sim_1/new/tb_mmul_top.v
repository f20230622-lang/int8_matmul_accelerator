
`timescale 1ns/1ps

module tb_mmul_top;

    localparam MAXJOBS = 64;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;

    // ============================================================
    // AXI4-Lite master: 32-bit
    // ============================================================
    reg  [7:0]  l_awaddr  = 8'd0;
    reg         l_awvalid = 1'b0;
    wire        l_awready;

    reg  [31:0] l_wdata   = 32'd0;
    reg  [3:0]  l_wstrb   = 4'hF;
    reg         l_wvalid  = 1'b0;
    wire        l_wready;

    wire [1:0]  l_bresp;
    wire        l_bvalid;
    reg         l_bready  = 1'b0;

    reg  [7:0]  l_araddr  = 8'd0;
    reg         l_arvalid = 1'b0;
    wire        l_arready;

    wire [31:0] l_rdata;
    wire [1:0]  l_rresp;
    wire        l_rvalid;
    reg         l_rready  = 1'b0;

    // ============================================================
    // AXI4 master: 64-bit data path
    // ============================================================
    wire [31:0] m_awaddr;
    wire [7:0]  m_awlen;
    wire [2:0]  m_awsize;
    wire [1:0]  m_awburst;
    wire        m_awvalid, m_awready;

    wire [63:0] m_wdata;
    wire [7:0]  m_wstrb;
    wire        m_wlast, m_wvalid, m_wready;

    wire [1:0]  m_bresp;
    wire        m_bvalid, m_bready;

    wire [31:0] m_araddr;
    wire [7:0]  m_arlen;
    wire [2:0]  m_arsize;
    wire [1:0]  m_arburst;
    wire        m_arvalid, m_arready;

    wire [63:0] m_rdata;
    wire [1:0]  m_rresp;
    wire        m_rlast, m_rvalid, m_rready;

    wire irq;

    // ============================================================
    // DUT
    // ============================================================
    mmul_top dut (
        .clk(clk),
        .rst_n(rst_n),

        .s_axi_awaddr(l_awaddr),
        .s_axi_awvalid(l_awvalid),
        .s_axi_awready(l_awready),
        .s_axi_wdata(l_wdata),
        .s_axi_wstrb(l_wstrb),
        .s_axi_wvalid(l_wvalid),
        .s_axi_wready(l_wready),
        .s_axi_bresp(l_bresp),
        .s_axi_bvalid(l_bvalid),
        .s_axi_bready(l_bready),

        .s_axi_araddr(l_araddr),
        .s_axi_arvalid(l_arvalid),
        .s_axi_arready(l_arready),
        .s_axi_rdata(l_rdata),
        .s_axi_rresp(l_rresp),
        .s_axi_rvalid(l_rvalid),
        .s_axi_rready(l_rready),

        .m_axi_awaddr(m_awaddr),
        .m_axi_awlen(m_awlen),
        .m_axi_awsize(m_awsize),
        .m_axi_awburst(m_awburst),
        .m_axi_awvalid(m_awvalid),
        .m_axi_awready(m_awready),

        .m_axi_wdata(m_wdata),
        .m_axi_wstrb(m_wstrb),
        .m_axi_wlast(m_wlast),
        .m_axi_wvalid(m_wvalid),
        .m_axi_wready(m_wready),
        .m_axi_bresp(m_bresp),
        .m_axi_bvalid(m_bvalid),
        .m_axi_bready(m_bready),

        .m_axi_araddr(m_araddr),
        .m_axi_arlen(m_arlen),
        .m_axi_arsize(m_arsize),
        .m_axi_arburst(m_arburst),
        .m_axi_arvalid(m_arvalid),
        .m_axi_arready(m_arready),

        .m_axi_rdata(m_rdata),
        .m_axi_rresp(m_rresp),
        .m_axi_rlast(m_rlast),
        .m_axi_rvalid(m_rvalid),
        .m_axi_rready(m_rready),

        .irq(irq)
    );

    // ============================================================
    // AXI memory model
    // ============================================================
    axi_mem_model #(
        .BAD_BASE(32'h0000_3000)
    ) u_mem (
        .clk(clk),
        .rst_n(rst_n),

        .awaddr(m_awaddr),
        .awlen(m_awlen),
        .awsize(m_awsize),
        .awburst(m_awburst),
        .awvalid(m_awvalid),
        .awready(m_awready),

        .wdata(m_wdata),
        .wstrb(m_wstrb),
        .wlast(m_wlast),
        .wvalid(m_wvalid),
        .wready(m_wready),

        .bresp(m_bresp),
        .bvalid(m_bvalid),
        .bready(m_bready),

        .araddr(m_araddr),
        .arlen(m_arlen),
        .arsize(m_arsize),
        .arburst(m_arburst),
        .arvalid(m_arvalid),
        .arready(m_arready),

        .rdata(m_rdata),
        .rresp(m_rresp),
        .rlast(m_rlast),
        .rvalid(m_rvalid),
        .rready(m_rready)
    );

    always #5 clk = ~clk;

    integer seed   = 5;
    integer errors = 0;

    // ============================================================
    // AXI4-Lite write task
    // ============================================================
    task lite_write(input [7:0] addr, input [31:0] data);
        integer mode;
        reg [1:0] resp;
        begin
            mode = $random(seed) & 3;
            if (mode == 3)
                mode = 0;

            if (mode == 0) begin
                fork
                    begin
                        l_awaddr  = addr;
                        l_awvalid = 1'b1;

                        @(posedge clk);
                        while (!l_awready)
                            @(posedge clk);

                        @(negedge clk);
                        l_awvalid = 1'b0;
                    end

                    begin
                        l_wdata   = data;
                        l_wstrb   = 4'hF;
                        l_wvalid  = 1'b1;

                        @(posedge clk);
                        while (!l_wready)
                            @(posedge clk);

                        @(negedge clk);
                        l_wvalid = 1'b0;
                    end
                join
            end else if (mode == 1) begin
                l_awaddr  = addr;
                l_awvalid = 1'b1;

                @(posedge clk);
                while (!l_awready)
                    @(posedge clk);

                @(negedge clk);
                l_awvalid = 1'b0;

                repeat ($random(seed) & 3)
                    @(negedge clk);

                l_wdata  = data;
                l_wstrb  = 4'hF;
                l_wvalid = 1'b1;

                @(posedge clk);
                while (!l_wready)
                    @(posedge clk);

                @(negedge clk);
                l_wvalid = 1'b0;
            end else begin
                l_wdata  = data;
                l_wstrb  = 4'hF;
                l_wvalid = 1'b1;

                @(posedge clk);
                while (!l_wready)
                    @(posedge clk);

                @(negedge clk);
                l_wvalid = 1'b0;

                repeat ($random(seed) & 3)
                    @(negedge clk);

                l_awaddr  = addr;
                l_awvalid = 1'b1;

                @(posedge clk);
                while (!l_awready)
                    @(posedge clk);

                @(negedge clk);
                l_awvalid = 1'b0;
            end

            repeat ($random(seed) & 3)
                @(negedge clk);

            l_bready = 1'b1;

            @(posedge clk);
            while (!l_bvalid)
                @(posedge clk);

            resp = l_bresp;

            @(negedge clk);
            l_bready = 1'b0;

            if (resp !== 2'b00) begin
                errors = errors + 1;
                $display(
                    "lite_write 0x%02h: unexpected bresp %0d",
                    addr, resp
                );
            end
        end
    endtask

    // ============================================================
    // AXI4-Lite read task
    // ============================================================
    task lite_read(input [7:0] addr, output [31:0] data);
        reg [1:0] resp;
        begin
            l_araddr  = addr;
            l_arvalid = 1'b1;

            @(posedge clk);
            while (!l_arready)
                @(posedge clk);

            @(negedge clk);
            l_arvalid = 1'b0;

            repeat ($random(seed) & 3)
                @(negedge clk);

            l_rready = 1'b1;

            @(posedge clk);
            while (!l_rvalid)
                @(posedge clk);

            data = l_rdata;
            resp = l_rresp;

            @(negedge clk);
            l_rready = 1'b0;

            if (resp !== 2'b00) begin
                errors = errors + 1;
                $display(
                    "lite_read 0x%02h: unexpected rresp %0d",
                    addr, resp
                );
            end
        end
    endtask

    // ============================================================
    // Test script
    // Header: number of jobs, expected AR bursts, expected AW bursts
    // Per job: A address, B address, C address, soft reset,
    //          expected error, three unused words
    // ============================================================
    reg [31:0] script [0:3+8*MAXJOBS-1];

    integer njobs, exp_ar, exp_aw;
    integer j, base, polls, n_err_jobs;

    reg [31:0] ja, jb, jc, jsoft, jexp;
    reg [31:0] st, rd, cyc_val, first_cycles;
    reg first_seen;

    // ============================================================
    // End-to-end performance totals
    // ============================================================
    integer perf_count;
    reg [63:0] perf_sum;

    // ============================================================
    // Phase profiling
    //
    // Command 0 = LOAD_A
    // Command 1 = LOAD_B
    // Command 2 = STORE_C
    // Phase 3   = COMPUTE (feeder_start to feeder_done)
    //
    // Separate active flags allow independent phase tracking.
    // All measurements are simulation clock cycles.
    // ============================================================
    integer profile_cycle;

    integer dma_phase_cmd;
    integer dma_phase_start;
    reg     dma_phase_active;

    integer compute_phase_start;
    reg     compute_phase_active;
    reg     compute_seen_done_low;

    integer job_load_a;
    integer job_load_b;
    integer job_compute;
    integer job_store_c;

    integer total_load_a;
    integer total_load_b;
    integer total_compute;
    integer total_store_c;

    integer count_load_a;
    integer count_load_b;
    integer count_compute;
    integer count_store_c;

    integer phase_duration;

    // STORE_C AXI write-path counters (testbench-only).
    reg     store_profile_active;
    integer store_aw_stall;
    integer store_w_stall;
    integer store_b_wait;
    integer store_aw_accept;
    integer store_w_accept;
    integer store_b_accept;
    integer store_w_beats_seen;
    integer store_bursts_pending;

    // ============================================================
    // Phase monitor
    // Uses internal DUT handshakes; simulation instrumentation only.
    // ============================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            profile_cycle       = 0;

            dma_phase_cmd       = -1;
            dma_phase_start     = 0;
            dma_phase_active    = 1'b0;

            compute_phase_start  = 0;
            compute_phase_active = 1'b0;
            compute_seen_done_low = 1'b0;

            store_profile_active = 1'b0;
            store_aw_stall = 0;
            store_w_stall = 0;
            store_b_wait = 0;
            store_aw_accept = 0;
            store_w_accept = 0;
            store_b_accept = 0;
            store_w_beats_seen = 0;
            store_bursts_pending = 0;
        end else begin
            profile_cycle = profile_cycle + 1;

            // ----------------------------------------------------
            // DMA command accepted
            // ----------------------------------------------------
            if (dut.cmd_valid && dut.cmd_ready) begin
                dma_phase_cmd    = dut.cmd;
                dma_phase_start  = profile_cycle;
                dma_phase_active = 1'b1;

                if (dut.cmd == 2) begin
                    store_profile_active = 1'b1;
                    store_aw_stall = 0;
                    store_w_stall = 0;
                    store_b_wait = 0;
                    store_aw_accept = 0;
                    store_w_accept = 0;
                    store_b_accept = 0;
                    store_w_beats_seen = 0;
                    store_bursts_pending = 0;
                end
            end

            // Count actual AXI handshakes and backpressure during STORE_C.
            if (store_profile_active) begin
                if (m_awvalid && !m_awready)
                    store_aw_stall = store_aw_stall + 1;
                if (m_wvalid && !m_wready)
                    store_w_stall = store_w_stall + 1;

                if (m_awvalid && m_awready)
                    store_aw_accept = store_aw_accept + 1;

                if (m_wvalid && m_wready) begin
                    store_w_accept = store_w_accept + 1;
                    store_w_beats_seen = store_w_beats_seen + 1;
                    if (m_wlast)
                        store_bursts_pending = store_bursts_pending + 1;
                end

                if (store_bursts_pending > store_b_accept && !m_bvalid)
                    store_b_wait = store_b_wait + 1;

                if (m_bvalid && m_bready) begin
                    store_b_accept = store_b_accept + 1;
                    if (store_bursts_pending > 0)
                        store_bursts_pending = store_bursts_pending - 1;
                end
            end

            // ----------------------------------------------------
            // DMA command completed
            // ----------------------------------------------------
            if (dma_phase_active &&
                (dut.dma_done || dut.dma_err)) begin

                phase_duration =
                    profile_cycle - dma_phase_start;

                case (dma_phase_cmd)
                    0: begin
                        job_load_a  = job_load_a + phase_duration;
                        total_load_a = total_load_a + phase_duration;
                        count_load_a = count_load_a + 1;
                    end

                    1: begin
                        job_load_b  = job_load_b + phase_duration;
                        total_load_b = total_load_b + phase_duration;
                        count_load_b = count_load_b + 1;
                    end

                    2: begin
                        job_store_c  = job_store_c + phase_duration;
                        total_store_c = total_store_c + phase_duration;
                        count_store_c = count_store_c + 1;
                    end
                endcase

                if (dma_phase_cmd == 2) begin
                    $display(
                        "PERF_WRITE AW_STALL=%0d W_STALL=%0d B_WAIT=%0d AW_ACCEPTED=%0d W_ACCEPTED=%0d B_ACCEPTED=%0d",
                        store_aw_stall, store_w_stall, store_b_wait,
                        store_aw_accept, store_w_accept, store_b_accept
                    );
                    store_profile_active = 1'b0;
                end

                dma_phase_active = 1'b0;
                dma_phase_cmd    = -1;
            end

            // ----------------------------------------------------
            // Compute start
            // ----------------------------------------------------
            if (dut.feeder_start) begin
                compute_phase_start  = profile_cycle;
                compute_phase_active = 1'b1;
                compute_seen_done_low = 1'b0;
            end

            // ----------------------------------------------------
            // Compute completion
            // feeder_done can still be HIGH from the previous job
            // when feeder_start is asserted. Require it to go LOW
            // after this start before accepting a HIGH as completion.
            // ----------------------------------------------------
            if (compute_phase_active && !dut.feeder_done)
                compute_seen_done_low = 1'b1;

            if (compute_phase_active &&
                compute_seen_done_low &&
                dut.feeder_done) begin
                phase_duration =
                    profile_cycle - compute_phase_start;

                job_compute   = job_compute + phase_duration;
                total_compute = total_compute + phase_duration;
                count_compute = count_compute + 1;

                compute_phase_active = 1'b0;
                compute_seen_done_low = 1'b0;
            end
        end
    end

    // ============================================================
    // Main test
    // ============================================================
    initial begin
        $readmemh("top_dram_init.hex", u_mem.dram);
        $readmemh("top_script.hex", script);

        njobs  = script[0];
        exp_ar = script[1];
        exp_aw = script[2];

        n_err_jobs   = 0;
        first_seen   = 1'b0;
        first_cycles = 32'd0;

        perf_count = 0;
        perf_sum   = 64'd0;

        job_load_a  = 0;
        job_load_b  = 0;
        job_compute = 0;
        job_store_c = 0;

        total_load_a  = 0;
        total_load_b  = 0;
        total_compute = 0;
        total_store_c = 0;

        count_load_a  = 0;
        count_load_b  = 0;
        count_compute = 0;
        count_store_c = 0;

        repeat (6) @(negedge clk);
        rst_n = 1'b1;

        repeat (4) @(negedge clk);

        // --------------------------------------------------------
        // VERSION, idle STATUS, IRQ checks
        // --------------------------------------------------------
        lite_read(8'h18, rd);

        if (rd !== 32'h4D4D0001) begin
            errors = errors + 1;
            $display(
                "VERSION read %h, expected 4D4D0001",
                rd
            );
        end

        lite_read(8'h04, rd);

        if (rd !== 32'h0 || irq !== 1'b0) begin
            errors = errors + 1;
            $display(
                "idle STATUS %h irq %b, expected 0 and 0",
                rd, irq
            );
        end

        lite_write(8'h00, 32'h4); // IRQ_EN

        for (j = 0; j < njobs; j = j + 1) begin
            base  = 3 + 8*j;
            ja    = script[base];
            jb    = script[base+1];
            jc    = script[base+2];
            jsoft = script[base+3];
            jexp  = script[base+4];

            if (jexp[0])
                n_err_jobs = n_err_jobs + 1;

            // ----------------------------------------------------
            // Optional soft reset
            // ----------------------------------------------------
            if (jsoft[0]) begin
                lite_write(8'h00, 32'h6);
                repeat (12) @(negedge clk);
            end

            // ----------------------------------------------------
            // Configure addresses
            // ----------------------------------------------------
            lite_write(8'h08, ja);
            lite_write(8'h0C, jb);
            lite_write(8'h10, jc);

            lite_read(8'h10, rd);

            if (rd !== jc) begin
                errors = errors + 1;
                $display(
                    "job %0d: C_ADDR read back %h, expected %h",
                    j, rd, jc
                );
            end

            // Reset per-job phase measurements before START.
            // The monitor accumulates these while the job executes.
            job_load_a  = 0;
            job_load_b  = 0;
            job_compute = 0;
            job_store_c = 0;

            // ----------------------------------------------------
            // START
            // ----------------------------------------------------
            lite_write(8'h00, 32'h5);

            polls = 0;
            st = 32'd0;

            while (st[2:1] == 2'b00 && polls < 3000) begin
                repeat (8) @(negedge clk);
                lite_read(8'h04, st);
                polls = polls + 1;
            end

            if (polls >= 3000) begin
                errors = errors + 1;
                $display(
                    "job %0d: TIMEOUT waiting for DONE/ERR",
                    j
                );
            end else begin
                if (jexp[0]) begin
                    if (st !== 32'h4) begin
                        errors = errors + 1;
                        $display(
                            "job %0d: STATUS %h, expected 4 (ERR)",
                            j, st
                        );
                    end
                end else begin
                    if (st !== 32'h2) begin
                        errors = errors + 1;
                        $display(
                            "job %0d: STATUS %h, expected 2 (DONE)",
                            j, st
                        );
                    end

                    lite_read(8'h14, cyc_val);

                    if (cyc_val == 0 || cyc_val > 5000) begin
                        errors = errors + 1;
                        $display(
                            "job %0d: CYCLES = %0d out of range",
                            j, cyc_val
                        );
                    end

                    // End-to-end accelerator cycle count
                    $display(
                        "PERF_TOP job=%0d cycles=%0d",
                        j, cyc_val
                    );

                    // Per-job phase breakdown
                    $display(
                        "PERF_PHASE job=%0d LOAD_A=%0d LOAD_B=%0d COMPUTE=%0d STORE_C=%0d",
                        j,
                        job_load_a,
                        job_load_b,
                        job_compute,
                        job_store_c
                    );

                    perf_sum   = perf_sum + cyc_val;
                    perf_count = perf_count + 1;

                    if (!first_seen) begin
                        first_seen   = 1'b1;
                        first_cycles = cyc_val;
                    end
                end

                if (irq !== 1'b1) begin
                    errors = errors + 1;
                    $display(
                        "job %0d: irq not asserted",
                        j
                    );
                end
            end

            // ----------------------------------------------------
            // Acknowledge DONE and ERR
            // ----------------------------------------------------
            lite_write(8'h04, 32'h6);
            repeat (2) @(negedge clk);

            lite_read(8'h04, st);

            if (st !== 32'h0 || irq !== 1'b0) begin
                errors = errors + 1;
                $display(
                    "job %0d: after clear STATUS %h irq %b, expected 0 and 0",
                    j, st, irq
                );
            end
        end

        // --------------------------------------------------------
        // Dump final DRAM contents
        // --------------------------------------------------------
        repeat (10) @(negedge clk);
        $writememh("top_dram_final.hex", u_mem.dram);

        // --------------------------------------------------------
        // Burst-count checks
        // --------------------------------------------------------
        if (u_mem.ar_hs_count != exp_ar) begin
            errors = errors + 1;
            $display(
                "AR bursts: saw %0d, expected %0d",
                u_mem.ar_hs_count, exp_ar
            );
        end

        if (u_mem.aw_hs_count != exp_aw) begin
            errors = errors + 1;
            $display(
                "AW bursts: saw %0d, expected %0d",
                u_mem.aw_hs_count, exp_aw
            );
        end

        if (u_mem.proto_err != 0) begin
            errors = errors + 1;
            $display(
                "AXI protocol check failures: %0d",
                u_mem.proto_err
            );
        end

        // --------------------------------------------------------
        // End-to-end summary
        // --------------------------------------------------------
        if (perf_count > 0) begin
            $display("");
            $display("========== END-TO-END PERFORMANCE ==========");
            $display(
                "Successful jobs: %0d",
                perf_count
            );
            $display(
                "Average cycles: %.2f",
                $itor(perf_sum) / perf_count
            );
            $display(
                "Average latency at 100 MHz: %.4f us",
                ($itor(perf_sum) / perf_count) / 100.0
            );
        end

        // --------------------------------------------------------
        // Phase summary
        // --------------------------------------------------------
        $display("");
        $display("========== PHASE PROFILING TOTALS ==========");

        $display(
            "LOAD_A:  %0d cycles across %0d completions",
            total_load_a, count_load_a
        );

        $display(
            "LOAD_B:  %0d cycles across %0d completions",
            total_load_b, count_load_b
        );

        $display(
            "COMPUTE: %0d cycles across %0d completions",
            total_compute, count_compute
        );

        $display(
            "STORE_C: %0d cycles across %0d completions",
            total_store_c, count_store_c
        );

        if (count_load_a > 0)
            $display(
                "Average LOAD_A: %.2f cycles",
                $itor(total_load_a) / count_load_a
            );

        if (count_load_b > 0)
            $display(
                "Average LOAD_B: %.2f cycles",
                $itor(total_load_b) / count_load_b
            );

        if (count_compute > 0)
            $display(
                "Average COMPUTE: %.2f cycles",
                $itor(total_compute) / count_compute
            );

        if (count_store_c > 0)
            $display(
                "Average STORE_C: %.2f cycles",
                $itor(total_store_c) / count_store_c
            );

        // --------------------------------------------------------
        // Final result
        // --------------------------------------------------------
        if (errors == 0) begin
            $display(
                "TEST PASSED: %0d jobs (%0d expected-error), first job CYCLES = %0d",
                njobs, n_err_jobs, first_cycles
            );
        end else begin
            $display(
                "TEST FAILED: %0d errors",
                errors
            );
        end

        $finish;
    end

    // Watchdog
    initial begin
        #50000000;
        $display("TEST FAILED: watchdog timeout");
        $finish;
    end

endmodule
