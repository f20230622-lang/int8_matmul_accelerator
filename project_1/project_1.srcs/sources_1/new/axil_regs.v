`timescale 1ns/1ps

module axil_regs #(
    parameter [31:0] VERSION = 32'h4D4D0001
) (
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Lite slave
    input  wire [7:0]  s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [7:0]  s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    // to / from the accelerator
    output reg         start,        // 1-cycle pulse -> mmul_ctrl.start
    output reg         soft_reset,   // 1-cycle pulse -> top-level reset logic
    output wire        irq,
    output wire [31:0] a_addr,
    output wire [31:0] b_addr,
    output wire [31:0] c_addr,
    input  wire        busy,
    input  wire        done_pulse,
    input  wire        err_pulse,
    input  wire [31:0] cycles
);

    // ------------------------------------------------------------------
    // Registers
    // ------------------------------------------------------------------
    reg        irq_en;
    reg        done_flag, err_flag;
    reg [31:0] a_r, b_r, c_r;

    assign a_addr = a_r;
    assign b_addr = b_r;
    assign c_addr = c_r;
    assign irq    = irq_en & (done_flag | err_flag);

    // ------------------------------------------------------------------
    // Write channel: AW and W accepted independently, applied when both held
    // ------------------------------------------------------------------
    reg        aw_got, w_got, bvalid_r;
    reg [7:0]  awaddr_q;
    reg [31:0] wdata_q;
    reg [3:0]  wstrb_q;
    reg [1:0]  bresp_r;

    assign s_axi_awready = !aw_got && !bvalid_r;
    assign s_axi_wready  = !w_got  && !bvalid_r;
    assign s_axi_bvalid  = bvalid_r;
    assign s_axi_bresp   = bresp_r;

    wire        do_write = aw_got && w_got && !bvalid_r;
    wire [2:0]  wr_word  = awaddr_q[4:2];
    wire        wr_ok    = (awaddr_q[7:5] == 3'd0) && (wr_word <= 3'd6);
    wire [31:0] wmask    = {{8{wstrb_q[3]}}, {8{wstrb_q[2]}}, {8{wstrb_q[1]}}, {8{wstrb_q[0]}}};

    always @(posedge clk) begin
        if (!rst_n) begin
            aw_got     <= 1'b0;
            w_got      <= 1'b0;
            bvalid_r   <= 1'b0;
            bresp_r    <= 2'b00;
            awaddr_q   <= 8'd0;
            wdata_q    <= 32'd0;
            wstrb_q    <= 4'd0;
            start      <= 1'b0;
            soft_reset <= 1'b0;
            irq_en     <= 1'b0;
            done_flag  <= 1'b0;
            err_flag   <= 1'b0;
            a_r        <= 32'd0;
            b_r        <= 32'd0;
            c_r        <= 32'd0;
        end else begin
            start      <= 1'b0;
            soft_reset <= 1'b0;

            // status flags set by the accelerator (clears below take priority)
            if (done_pulse) done_flag <= 1'b1;
            if (err_pulse)  err_flag  <= 1'b1;

            if (s_axi_awvalid && s_axi_awready) begin
                aw_got   <= 1'b1;
                awaddr_q <= s_axi_awaddr;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_got   <= 1'b1;
                wdata_q <= s_axi_wdata;
                wstrb_q <= s_axi_wstrb;
            end

            if (do_write) begin
                aw_got   <= 1'b0;
                w_got    <= 1'b0;
                bvalid_r <= 1'b1;
                bresp_r  <= wr_ok ? 2'b00 : 2'b10;   // OKAY / SLVERR

                if (wr_ok) begin
                    case (wr_word)
                        3'd0: begin   // CTRL
                            if (wstrb_q[0]) begin
                                if (wdata_q[0] && !busy) begin
                                    start     <= 1'b1;
                                    done_flag <= 1'b0;
                                    err_flag  <= 1'b0;
                                end
                                if (wdata_q[1]) begin
                                    soft_reset <= 1'b1;
                                    done_flag  <= 1'b0;
                                    err_flag   <= 1'b0;
                                end
                                irq_en <= wdata_q[2];
                            end
                        end
                        3'd1: begin   // STATUS: write 1 to clear
                            if (wstrb_q[0]) begin
                                if (wdata_q[1]) done_flag <= 1'b0;
                                if (wdata_q[2]) err_flag  <= 1'b0;
                            end
                        end
                        3'd2: a_r <= (a_r & ~wmask) | (wdata_q & wmask);
                        3'd3: b_r <= (b_r & ~wmask) | (wdata_q & wmask);
                        3'd4: c_r <= (c_r & ~wmask) | (wdata_q & wmask);
                        default: ;    // CYCLES, VERSION: read-only, write ignored
                    endcase
                end
            end else if (bvalid_r && s_axi_bready) begin
                bvalid_r <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------
    // Read channel
    // ------------------------------------------------------------------
    reg        rvalid_r;
    reg [31:0] rdata_r;
    reg [1:0]  rresp_r;

    assign s_axi_arready = !rvalid_r;
    assign s_axi_rvalid  = rvalid_r;
    assign s_axi_rdata   = rdata_r;
    assign s_axi_rresp   = rresp_r;

    wire [2:0] rd_word = s_axi_araddr[4:2];
    wire       rd_ok   = (s_axi_araddr[7:5] == 3'd0) && (rd_word <= 3'd6);

    always @(posedge clk) begin
        if (!rst_n) begin
            rvalid_r <= 1'b0;
            rdata_r  <= 32'd0;
            rresp_r  <= 2'b00;
        end else begin
            if (s_axi_arvalid && s_axi_arready) begin
                rvalid_r <= 1'b1;
                rresp_r  <= rd_ok ? 2'b00 : 2'b10;
                if (!rd_ok) begin
                    rdata_r <= 32'd0;
                end else begin
                    case (rd_word)
                        3'd0:    rdata_r <= {29'd0, irq_en, 2'b00};
                        3'd1:    rdata_r <= {29'd0, err_flag, done_flag, busy};
                        3'd2:    rdata_r <= a_r;
                        3'd3:    rdata_r <= b_r;
                        3'd4:    rdata_r <= c_r;
                        3'd5:    rdata_r <= cycles;
                        default: rdata_r <= VERSION;
                    endcase
                end
            end else if (rvalid_r && s_axi_rready) begin
                rvalid_r <= 1'b0;
            end
        end
    end

endmodule