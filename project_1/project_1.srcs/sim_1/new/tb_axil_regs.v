`timescale 1ns/1ps

module tb_axil_regs;

    localparam MAXWORDS = 6*700 + 8;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;

    reg  [7:0]  awaddr = 8'd0;   reg awvalid = 1'b0;  wire awready;
    reg  [31:0] wdata  = 32'd0;  reg [3:0] wstrb = 4'd0;
    reg         wvalid = 1'b0;   wire wready;
    wire [1:0]  bresp;           wire bvalid;         reg bready = 1'b0;
    reg  [7:0]  araddr = 8'd0;   reg arvalid = 1'b0;  wire arready;
    wire [31:0] rdata;           wire [1:0] rresp;    wire rvalid;
    reg         rready = 1'b0;

    wire        start, soft_reset, irq;
    wire [31:0] a_addr, b_addr, c_addr;
    reg         busy = 1'b0, done_pulse = 1'b0, err_pulse = 1'b0;
    reg  [31:0] cycles = 32'd0;

    axil_regs dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid),
        .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid),
        .s_axi_rready(rready),
        .start(start), .soft_reset(soft_reset), .irq(irq),
        .a_addr(a_addr), .b_addr(b_addr), .c_addr(c_addr),
        .busy(busy), .done_pulse(done_pulse), .err_pulse(err_pulse),
        .cycles(cycles)
    );

    always #5 clk = ~clk;

    integer start_cnt = 0;
    integer soft_cnt  = 0;
    always @(posedge clk) begin
        if (start)      start_cnt = start_cnt + 1;
        if (soft_reset) soft_cnt  = soft_cnt + 1;
    end

    integer seed   = 7;
    integer errors = 0;

    // ------------------------------------------------------------------
    // AXI4-Lite master tasks. Signals are driven at negedge; handshakes are
    // detected by sampling the slave's ready/valid at posedge (pre-update).
    // ------------------------------------------------------------------
    task axi_write(input [7:0] addr, input [31:0] data, input [3:0] strb,
                   output [1:0] resp);
        integer mode;
        begin
            mode = $random(seed) & 3;
            if (mode == 3) mode = 0;

            if (mode == 0) begin                 // AW and W together
                fork
                    begin
                        awaddr = addr; awvalid = 1'b1;
                        @(posedge clk);
                        while (!awready) @(posedge clk);
                        @(negedge clk);
                        awvalid = 1'b0;
                    end
                    begin
                        wdata = data; wstrb = strb; wvalid = 1'b1;
                        @(posedge clk);
                        while (!wready) @(posedge clk);
                        @(negedge clk);
                        wvalid = 1'b0;
                    end
                join
            end else if (mode == 1) begin        // AW first, W later
                awaddr = addr; awvalid = 1'b1;
                @(posedge clk);
                while (!awready) @(posedge clk);
                @(negedge clk);
                awvalid = 1'b0;
                repeat ($random(seed) & 3) @(negedge clk);
                wdata = data; wstrb = strb; wvalid = 1'b1;
                @(posedge clk);
                while (!wready) @(posedge clk);
                @(negedge clk);
                wvalid = 1'b0;
            end else begin                       // W first, AW later
                wdata = data; wstrb = strb; wvalid = 1'b1;
                @(posedge clk);
                while (!wready) @(posedge clk);
                @(negedge clk);
                wvalid = 1'b0;
                repeat ($random(seed) & 3) @(negedge clk);
                awaddr = addr; awvalid = 1'b1;
                @(posedge clk);
                while (!awready) @(posedge clk);
                @(negedge clk);
                awvalid = 1'b0;
            end

            repeat ($random(seed) & 3) @(negedge clk);   // stall bready
            bready = 1'b1;
            @(posedge clk);
            while (!bvalid) @(posedge clk);
            resp = bresp;
            @(negedge clk);
            bready = 1'b0;
        end
    endtask

    task axi_read(input [7:0] addr, output [31:0] data, output [1:0] resp);
        begin
            araddr = addr; arvalid = 1'b1;
            @(posedge clk);
            while (!arready) @(posedge clk);
            @(negedge clk);
            arvalid = 1'b0;

            repeat ($random(seed) & 3) @(negedge clk);   // stall rready
            rready = 1'b1;
            @(posedge clk);
            while (!rvalid) @(posedge clk);
            data = rdata;
            resp = rresp;
            @(negedge clk);
            rready = 1'b0;
        end
    endtask

    // ------------------------------------------------------------------
    // Script interpreter. Word 0 = number of ops; then 6 words per op.
    //  0 WRITE  addr data strb exp_resp      1 READ  addr exp_data exp_resp
    //  2 SET_BUSY v    3 PULSE_DONE    4 PULSE_ERR    5 SET_CYCLES v
    //  6 CHECK_IRQ v   7 CHECK_ADDRS a b c   8 CHECK_PULSES start soft
    //  9 IDLE n
    // ------------------------------------------------------------------
    reg [31:0] script [0:MAXWORDS-1];
    integer    k, base, nops, op;
    reg [31:0] f1, f2, f3, f4;
    reg [31:0] rd;
    reg [1:0]  rsp;

    initial begin
        $readmemh("axil_script.hex", script);
        nops = script[0];

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        for (k = 0; k < nops; k = k + 1) begin
            base = 1 + 6*k;
            op = script[base];
            f1 = script[base+1];
            f2 = script[base+2];
            f3 = script[base+3];
            f4 = script[base+4];

            case (op)
                0: begin
                    axi_write(f1[7:0], f2, f3[3:0], rsp);
                    if (rsp !== f4[1:0]) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("op %0d WRITE 0x%02h: bresp %0d, expected %0d",
                                     k, f1[7:0], rsp, f4[1:0]);
                    end
                end
                1: begin
                    axi_read(f1[7:0], rd, rsp);
                    if (rd !== f2 || rsp !== f3[1:0]) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("op %0d READ 0x%02h: got %h resp %0d, expected %h resp %0d",
                                     k, f1[7:0], rd, rsp, f2, f3[1:0]);
                    end
                end
                2: busy   = f1[0];
                3: begin done_pulse = 1'b1; @(negedge clk); done_pulse = 1'b0; @(negedge clk); end
                4: begin err_pulse  = 1'b1; @(negedge clk); err_pulse  = 1'b0; @(negedge clk); end
                5: cycles = f1;
                6: begin
                    @(negedge clk);
                    if (irq !== f1[0]) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("op %0d CHECK_IRQ: got %0d, expected %0d", k, irq, f1[0]);
                    end
                end
                7: begin
                    @(negedge clk);
                    if (a_addr !== f1 || b_addr !== f2 || c_addr !== f3) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("op %0d CHECK_ADDRS: got %h/%h/%h, expected %h/%h/%h",
                                     k, a_addr, b_addr, c_addr, f1, f2, f3);
                    end
                end
                8: begin
                    @(negedge clk);
                    if (start_cnt != f1 || soft_cnt != f2) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("op %0d CHECK_PULSES: start %0d soft %0d, expected %0d %0d",
                                     k, start_cnt, soft_cnt, f1, f2);
                    end
                end
                9: repeat (f1) @(negedge clk);
                default: begin
                    errors = errors + 1;
                    $display("op %0d: unknown opcode %0d", k, op);
                end
            endcase
        end

        if (errors == 0)
            $display("TEST PASSED: %0d AXI4-Lite ops", nops);
        else
            $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    // watchdog
    initial begin
        #5000000;
        $display("TEST FAILED: watchdog timeout");
        $finish;
    end

endmodule