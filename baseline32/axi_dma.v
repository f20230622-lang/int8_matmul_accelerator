`timescale 1ns/1ps

module axi_dma (
    input  wire         clk,
    input  wire         rst_n,

    // command channel (from mmul_ctrl)
    input  wire         cmd_valid,
    input  wire [1:0]   cmd,             // 0 LOAD_A, 1 LOAD_B, 2 STORE_C
    output wire         cmd_ready,
    output reg          done,            // 1-cycle pulse
    output reg          err,             // 1-cycle pulse

    // base addresses (from axil_regs)
    input  wire [31:0]  a_addr,
    input  wire [31:0]  b_addr,
    input  wire [31:0]  c_addr,

    // buffer ports
    output wire [1:0]  a_wr_we,
    output wire [1:0]  b_wr_we,
    output wire [4:0]  buf_wr_addr,
    output wire [63:0] buf_wr_data,
    output wire [6:0]  c_rd_addr,       // to c_buf (1-cycle read latency)
    input  wire [63:0] c_rd_data,

    // AXI4 master
    output wire [31:0]  m_axi_awaddr,
    output wire [7:0]   m_axi_awlen,
    output wire [2:0]   m_axi_awsize,
    output wire [1:0]   m_axi_awburst,
    output wire         m_axi_awvalid,
    input  wire         m_axi_awready,
    output wire [31:0]  m_axi_wdata,
    output wire [3:0]   m_axi_wstrb,
    output wire         m_axi_wlast,
    output wire         m_axi_wvalid,
    input  wire         m_axi_wready,
    input  wire [1:0]   m_axi_bresp,
    input  wire         m_axi_bvalid,
    output wire         m_axi_bready,
    output wire [31:0]  m_axi_araddr,
    output wire [7:0]   m_axi_arlen,
    output wire [2:0]   m_axi_arsize,
    output wire [1:0]   m_axi_arburst,
    output wire         m_axi_arvalid,
    input  wire         m_axi_arready,
    input  wire [31:0]  m_axi_rdata,
    input  wire [1:0]   m_axi_rresp,
    input  wire         m_axi_rlast,
    input  wire         m_axi_rvalid,
    output wire         m_axi_rready
);

    localparam [1:0] S_IDLE = 2'd0, S_RD = 2'd1, S_WR_PRIME = 2'd2, S_WR = 2'd3;

    reg [1:0]  state;
    reg [31:0] base_q;
    reg        sel_b;
    reg [2:0]  ar_cnt;      // read bursts issued, 0..4
    reg [5:0]  r_cnt;       // read beats received, 0..63
    reg [4:0]  aw_cnt;      // write bursts issued, 0..16
    reg [4:0]  b_cnt;       // write responses received, 0..15
    reg [7:0]  widx;        // C word currently presented on the W channel
    reg        w_done;      // all 256 words sent
    reg        xfer_err;

    // ------------------------------------------------------------------
    // Command acceptance
    // ------------------------------------------------------------------
    assign cmd_ready = (state == S_IDLE);

    wire [31:0] cmd_base = (cmd == 2'd0) ? a_addr :
                           (cmd == 2'd1) ? b_addr : c_addr;
    wire        cmd_ok   = (cmd != 2'd3) && (cmd_base[5:0] == 6'd0);

    // ------------------------------------------------------------------
    // Read path
    // ------------------------------------------------------------------
    assign m_axi_arvalid = (state == S_RD) && (ar_cnt < 3'd4);
    assign m_axi_araddr  = base_q + {ar_cnt, 6'b000000};
    assign m_axi_arlen   = 8'd15;
    assign m_axi_arsize  = 3'b010;
    assign m_axi_arburst = 2'b01;
    assign m_axi_rready  = (state == S_RD);

    wire r_fire = (state == S_RD) && m_axi_rvalid;

    wire [1:0] half_we = r_cnt[0] ? 2'b10 : 2'b01;
    assign a_wr_we     = (r_fire && !sel_b) ? half_we : 2'b00;
    assign b_wr_we     = (r_fire &&  sel_b) ? half_we : 2'b00;
    assign buf_wr_addr = r_cnt[5:1];
    assign buf_wr_data = {m_axi_rdata, m_axi_rdata};

    // ------------------------------------------------------------------
    // Write path
    // ------------------------------------------------------------------
    assign m_axi_awvalid = ((state == S_WR_PRIME) || (state == S_WR)) && (aw_cnt < 5'd16);
    assign m_axi_awaddr  = base_q + {aw_cnt[3:0], 6'b000000};
    assign m_axi_awlen   = 8'd15;
    assign m_axi_awsize  = 3'b010;
    assign m_axi_awburst = 2'b01;

    assign m_axi_wvalid  = (state == S_WR) && !w_done;
    reg half_q;   // which 32-bit half of the c_buf beat is on the W channel
    assign m_axi_wdata   = half_q ? c_rd_data[63:32] : c_rd_data[31:0];
    assign m_axi_wstrb   = 4'hF;
    assign m_axi_wlast   = (widx[3:0] == 4'd15);
    assign m_axi_bready  = (state == S_WR);

    wire w_fire = m_axi_wvalid && m_axi_wready;

    // look-ahead: when a beat is accepted, fetch the next word
    wire [7:0] word_ahead = widx + {7'd0, w_fire};
    always @(posedge clk) half_q <= word_ahead[0];
    assign c_rd_addr = word_ahead[7:1];

    // ------------------------------------------------------------------
    // Sequencing
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            base_q   <= 32'd0;
            sel_b    <= 1'b0;
            ar_cnt   <= 3'd0;
            r_cnt    <= 6'd0;
            aw_cnt   <= 5'd0;
            b_cnt    <= 5'd0;
            widx     <= 8'd0;
            w_done   <= 1'b0;
            xfer_err <= 1'b0;
            done     <= 1'b0;
            err      <= 1'b0;
        end else begin
            done <= 1'b0;
            err  <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (cmd_valid) begin
                        if (!cmd_ok) begin
                            err <= 1'b1;              // no AXI traffic
                        end else begin
                            base_q   <= cmd_base;
                            xfer_err <= 1'b0;
                            if (cmd == 2'd2) begin
                                state  <= S_WR_PRIME;
                                aw_cnt <= 5'd0;
                                b_cnt  <= 5'd0;
                                widx   <= 8'd0;
                                w_done <= 1'b0;
                            end else begin
                                state  <= S_RD;
                                sel_b  <= cmd[0];
                                ar_cnt <= 3'd0;
                                r_cnt  <= 6'd0;
                            end
                        end
                    end
                end

                S_RD: begin
                    if (m_axi_arvalid && m_axi_arready)
                        ar_cnt <= ar_cnt + 3'd1;
                    if (r_fire) begin
                        r_cnt <= r_cnt + 6'd1;
                        if (m_axi_rresp[1])
                            xfer_err <= 1'b1;
                        if (r_cnt == 6'd63) begin
                            state <= S_IDLE;
                            if (xfer_err || m_axi_rresp[1]) err  <= 1'b1;
                            else                            done <= 1'b1;
                        end
                    end
                end

                // one cycle with c_rd_addr = 0 so word 0 is on c_rd_data in S_WR
                S_WR_PRIME: begin
                    if (m_axi_awvalid && m_axi_awready)
                        aw_cnt <= aw_cnt + 5'd1;
                    state <= S_WR;
                end

                S_WR: begin
                    if (m_axi_awvalid && m_axi_awready)
                        aw_cnt <= aw_cnt + 5'd1;
                    if (w_fire) begin
                        if (widx == 8'd255) w_done <= 1'b1;
                        else                widx   <= widx + 8'd1;
                    end
                    if (m_axi_bvalid) begin
                        b_cnt <= b_cnt + 5'd1;
                        if (m_axi_bresp[1])
                            xfer_err <= 1'b1;
                        if (b_cnt == 5'd15) begin
                            state <= S_IDLE;
                            if (xfer_err || m_axi_bresp[1]) err  <= 1'b1;
                            else                            done <= 1'b1;
                        end
                    end
                end
            endcase
        end
    end

endmodule