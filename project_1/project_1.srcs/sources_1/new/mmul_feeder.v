`timescale 1ns/1ps

module mmul_feeder (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,       // pulse; ignored while busy
    output wire         busy,
    output reg          done,        // high when c_out is final, cleared by next start
    output wire         clear,       // to systolic_array (1-cycle pulse)
    output wire [63:0]  rd_k,        // read index per bank, shared by A and B buffers
    input  wire [127:0] a_data,      // from a_buf (1-cycle latency)
    input  wire [127:0] b_data,      // from b_buf (1-cycle latency)
    output wire [127:0] a_row_in,    // to systolic_array
    output wire [127:0] b_col_in
);

    localparam [1:0] S_IDLE = 2'd0, S_CLEAR = 2'd1, S_RUN = 2'd2, S_DRAIN = 2'd3;
    localparam [5:0] CLEAR_LAST = 6'd3;    // CLEAR state lasts 4 cycles
    localparam [5:0] RUN_LAST   = 6'd30;   // 2N-2
    localparam [5:0] DRAIN_LAST = 6'd16;   // N

    reg [1:0]  state;
    reg [5:0]  cnt;
    reg [15:0] vq;                         // valid flags, aligned with RAM output

    assign busy  = (state != S_IDLE);
    assign clear = (state == S_CLEAR) && (cnt == 6'd0);

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            cnt   <= 6'd0;
            done  <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (start) begin
                        state <= S_CLEAR;
                        cnt   <= 6'd0;
                        done  <= 1'b0;
                    end
                end
                S_CLEAR: begin
                    if (cnt == CLEAR_LAST) begin
                        state <= S_RUN;
                        cnt   <= 6'd0;
                    end else begin
                        cnt <= cnt + 6'd1;
                    end
                end
                S_RUN: begin
                    if (cnt == RUN_LAST) begin
                        state <= S_DRAIN;
                        cnt   <= 6'd0;
                    end else begin
                        cnt <= cnt + 6'd1;
                    end
                end
                S_DRAIN: begin
                    if (cnt == DRAIN_LAST) begin
                        state <= S_IDLE;
                        done  <= 1'b1;
                    end else begin
                        cnt <= cnt + 6'd1;
                    end
                end
            endcase
        end
    end

    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : g_idx
            wire       in_win = (state == S_RUN) && (cnt >= i) && (cnt <= i + 15);
            wire [5:0] kk     = cnt - i;

            assign rd_k[4*i +: 4] = in_win ? kk[3:0] : 4'd0;

            always @(posedge clk)
                vq[i] <= rst_n & in_win;

            assign a_row_in[8*i +: 8] = vq[i] ? a_data[8*i +: 8] : 8'd0;
            assign b_col_in[8*i +: 8] = vq[i] ? b_data[8*i +: 8] : 8'd0;
        end
    endgenerate

endmodule