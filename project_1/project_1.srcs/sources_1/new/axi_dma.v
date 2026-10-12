
`timescale 1ns/1ps

module axi_dma (
    input  wire         clk,
    input  wire         rst_n,

    // Command channel
    input  wire         cmd_valid,
    input  wire [1:0]   cmd,       // 0 = LOAD_A, 1 = LOAD_B, 2 = STORE_C
    output wire         cmd_ready,
    output reg          done,
    output reg          err,

    // Base addresses
    input  wire [31:0]  a_addr,
    input  wire [31:0]  b_addr,
    input  wire [31:0]  c_addr,

    // Internal buffers
    output wire [1:0]   a_wr_we,
    output wire [1:0]   b_wr_we,
    output wire [4:0]   buf_wr_addr,
    output wire [63:0]  buf_wr_data,
    output wire [6:0]   c_rd_addr,
    input  wire [63:0]  c_rd_data,

    // AXI4 write-address channel
    output wire [31:0]  m_axi_awaddr,
    output wire [7:0]   m_axi_awlen,
    output wire [2:0]   m_axi_awsize,
    output wire [1:0]   m_axi_awburst,
    output wire         m_axi_awvalid,
    input  wire         m_axi_awready,

    // AXI4 write-data channel
    output wire [63:0]  m_axi_wdata,
    output wire [7:0]   m_axi_wstrb,
    output wire         m_axi_wlast,
    output wire         m_axi_wvalid,
    input  wire         m_axi_wready,

    // AXI4 write-response channel
    input  wire [1:0]   m_axi_bresp,
    input  wire         m_axi_bvalid,
    output wire         m_axi_bready,

    // AXI4 read-address channel
    output wire [31:0]  m_axi_araddr,
    output wire [7:0]   m_axi_arlen,
    output wire [2:0]   m_axi_arsize,
    output wire [1:0]   m_axi_arburst,
    output wire         m_axi_arvalid,
    input  wire         m_axi_arready,

    // AXI4 read-data channel
    input  wire [63:0]  m_axi_rdata,
    input  wire [1:0]   m_axi_rresp,
    input  wire         m_axi_rlast,
    input  wire         m_axi_rvalid,
    output wire         m_axi_rready
);

    localparam [1:0] S_IDLE     = 2'd0;
    localparam [1:0] S_RD       = 2'd1;
    localparam [1:0] S_WR_PRIME = 2'd2;
    localparam [1:0] S_WR       = 2'd3;

    reg [1:0] state;

    reg [31:0] base_q;
    reg        sel_b;
    reg        xfer_err;

    // A/B reads: 32 beats per matrix, two bursts of 16 beats.
    reg [1:0] ar_cnt;
    reg [5:0] r_cnt;

    // C writes: 128 beats, four bursts of 32 beats.
    reg [3:0] aw_cnt;
    reg [3:0] b_cnt;
    reg [7:0] widx;
    reg       w_done;

    wire [31:0] cmd_base =
        (cmd == 2'd0) ? a_addr :
        (cmd == 2'd1) ? b_addr :
                        c_addr;

    // Each 16-beat burst is 128 bytes; require 128-byte alignment.
    wire cmd_ok = (cmd != 2'd3) && (cmd_base[6:0] == 7'd0);

    assign cmd_ready = (state == S_IDLE);

    // ------------------------------------------------------------
    // AXI4 read path
    // ------------------------------------------------------------

    assign m_axi_arvalid = (state == S_RD) && (ar_cnt < 2'd2);
    assign m_axi_araddr  = base_q + {ar_cnt, 7'b0};
    assign m_axi_arlen   = 8'd15;
    assign m_axi_arsize  = 3'b011;  // 8 bytes per beat
    assign m_axi_arburst = 2'b01;   // INCR
    assign m_axi_rready  = (state == S_RD);

    wire r_fire = m_axi_rvalid && m_axi_rready;

    // Each 64-bit beat writes one complete buffer word.
    assign a_wr_we = (r_fire && !sel_b) ? 2'b11 : 2'b00;
    assign b_wr_we = (r_fire &&  sel_b) ? 2'b11 : 2'b00;

    assign buf_wr_addr = r_cnt[4:0];
    assign buf_wr_data = m_axi_rdata;

    // ------------------------------------------------------------
    // AXI4 write path
    // ------------------------------------------------------------

    assign m_axi_awvalid =
        ((state == S_WR_PRIME) || (state == S_WR)) &&
        (aw_cnt < 4'd4);

    assign m_axi_awaddr  = base_q + {aw_cnt[1:0], 8'b0};
    assign m_axi_awlen   = 8'd31;
    assign m_axi_awsize  = 3'b011;  // 8 bytes per beat
    assign m_axi_awburst = 2'b01;   // INCR

    assign m_axi_wvalid = (state == S_WR) && !w_done;
    assign m_axi_wdata  = c_rd_data;
    assign m_axi_wstrb  = 8'hFF;
    assign m_axi_wlast  = (widx[4:0] == 5'd31);

    assign m_axi_bready = (state == S_WR);

    wire w_fire = m_axi_wvalid && m_axi_wready;
    wire b_fire = m_axi_bvalid && m_axi_bready;

    // c_buf has a one-cycle read latency. Select the next 64-bit word
    // when the current W beat is accepted.
    wire [7:0] word_ahead = widx + (w_fire ? 8'd1 : 8'd0);
    assign c_rd_addr = word_ahead[6:0];

    // ------------------------------------------------------------
    // State machine
    // ------------------------------------------------------------

    always @(posedge clk) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            base_q   <= 32'd0;
            sel_b    <= 1'b0;
            xfer_err <= 1'b0;

            ar_cnt   <= 2'd0;
            r_cnt    <= 6'd0;

            aw_cnt   <= 4'd0;
            b_cnt    <= 4'd0;
            widx     <= 8'd0;
            w_done   <= 1'b0;

            done     <= 1'b0;
            err      <= 1'b0;
        end else begin
            done <= 1'b0;
            err  <= 1'b0;

            case (state)

                S_IDLE: begin
                    if (cmd_valid) begin
                        if (!cmd_ok) begin
                            err <= 1'b1;
                        end else begin
                            base_q   <= cmd_base;
                            xfer_err <= 1'b0;

                            if (cmd == 2'd2) begin
                                state  <= S_WR_PRIME;
                                aw_cnt <= 4'd0;
                                b_cnt  <= 4'd0;
                                widx   <= 8'd0;
                                w_done <= 1'b0;
                            end else begin
                                state  <= S_RD;
                                sel_b  <= cmd[0];
                                ar_cnt <= 2'd0;
                                r_cnt  <= 6'd0;
                            end
                        end
                    end
                end

                S_RD: begin
                    if (m_axi_arvalid && m_axi_arready)
                        ar_cnt <= ar_cnt + 2'd1;

                    if (r_fire) begin
                        if (m_axi_rresp[1])
                            xfer_err <= 1'b1;

                        // RLAST must occur on beats 15 and 31.
                        if (m_axi_rlast != (r_cnt[3:0] == 4'd15))
                            xfer_err <= 1'b1;

                        if (r_cnt == 6'd31) begin
                            state <= S_IDLE;

                            if (xfer_err || m_axi_rresp[1] ||
                                (m_axi_rlast != (r_cnt[3:0] == 4'd15)))
                                err <= 1'b1;
                            else
                                done <= 1'b1;
                        end else begin
                            r_cnt <= r_cnt + 6'd1;
                        end
                    end
                end

                // Prime synchronous C-buffer read so word zero is ready
                // when the write-data channel starts.
                S_WR_PRIME: begin
                    if (m_axi_awvalid && m_axi_awready)
                        aw_cnt <= aw_cnt + 4'd1;

                    state <= S_WR;
                end

                S_WR: begin
                    if (m_axi_awvalid && m_axi_awready)
                        aw_cnt <= aw_cnt + 4'd1;

                    if (w_fire) begin
                        if (widx == 8'd127)
                            w_done <= 1'b1;
                        else
                            widx <= widx + 8'd1;
                    end

                    if (b_fire) begin
                        if (m_axi_bresp[1])
                            xfer_err <= 1'b1;

                        if (b_cnt == 4'd3) begin
                            // Four responses complete the store.
                            if (w_done || (w_fire && widx == 8'd127)) begin
                                state <= S_IDLE;

                                if (xfer_err || m_axi_bresp[1])
                                    err <= 1'b1;
                                else
                                    done <= 1'b1;
                            end

                            b_cnt <= 4'd4;
                        end else begin
                            b_cnt <= b_cnt + 4'd1;
                        end
                    end

                    // Handle the case where all responses were already
                    // received and the final data beat is accepted later.
                    if (w_fire && widx == 8'd127 && b_cnt == 4'd4) begin
                        state <= S_IDLE;

                        if (xfer_err)
                            err <= 1'b1;
                        else
                            done <= 1'b1;
                    end
                end

                default: begin
                    state <= S_IDLE;
                    err   <= 1'b1;
                end

            endcase
        end
    end

endmodule
