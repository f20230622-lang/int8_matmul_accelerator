`timescale 1ns/1ps

module mmul_ctrl (
    input  wire        clk,
    input  wire        rst_n,

    // job control / status (to/from the AXI4-Lite register block)
    input  wire        start,          // pulse; ignored while busy
    output wire        busy,
    output reg         done_pulse,     // 1 cycle: job finished
    output reg         err_pulse,      // 1 cycle: job aborted by DMA error
    output reg  [31:0] cycles,         // length of the last finished job

    // DMA command channel
    output wire        dma_cmd_valid,
    output wire [1:0]  dma_cmd,        // 0 LOAD_A, 1 LOAD_B, 2 STORE_C
    input  wire        dma_cmd_ready,
    input  wire        dma_done,       // pulse: command finished
    input  wire        dma_err,        // pulse: command failed

    // feeder / array
    output wire        feeder_start,
    input  wire        feeder_done,

    // C buffer drain
    output wire        drain_start,
    input  wire        drain_done
);

    localparam [3:0] S_IDLE       = 4'd0,
                     S_CMD_A      = 4'd1,
                     S_WAIT_A     = 4'd2,
                     S_CMD_B      = 4'd3,
                     S_WAIT_B     = 4'd4,
                     S_FEED_GO    = 4'd5,
                     S_FEED_WAIT  = 4'd6,
                     S_DRAIN_GO   = 4'd7,
                     S_DRAIN_WAIT = 4'd8,
                     S_CMD_C      = 4'd9,
                     S_WAIT_C     = 4'd10;

    reg [3:0]  state;
    reg [31:0] cnt;

    assign busy          = (state != S_IDLE);
    assign dma_cmd_valid = (state == S_CMD_A) || (state == S_CMD_B) || (state == S_CMD_C);
    assign dma_cmd       = (state == S_CMD_A) ? 2'd0 :
                           (state == S_CMD_B) ? 2'd1 : 2'd2;
    assign feeder_start  = (state == S_FEED_GO);
    assign drain_start   = (state == S_DRAIN_GO);

    always @(posedge clk) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            cnt        <= 32'd0;
            cycles     <= 32'd0;
            done_pulse <= 1'b0;
            err_pulse  <= 1'b0;
        end else begin
            done_pulse <= 1'b0;
            err_pulse  <= 1'b0;
            if (state != S_IDLE)
                cnt <= cnt + 32'd1;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        cnt   <= 32'd0;
                        state <= S_CMD_A;
                    end
                end

                S_CMD_A: if (dma_cmd_ready) state <= S_WAIT_A;
                S_WAIT_A: begin
                    if (dma_err) begin
                        err_pulse <= 1'b1;
                        state     <= S_IDLE;
                    end else if (dma_done) begin
                        state <= S_CMD_B;
                    end
                end

                S_CMD_B: if (dma_cmd_ready) state <= S_WAIT_B;
                S_WAIT_B: begin
                    if (dma_err) begin
                        err_pulse <= 1'b1;
                        state     <= S_IDLE;
                    end else if (dma_done) begin
                        state <= S_FEED_GO;
                    end
                end

                // one-cycle start pulse; the feeder clears its own done on accept,
                // so by the next state the stale done from the previous job is gone
                S_FEED_GO:   state <= S_FEED_WAIT;
                S_FEED_WAIT: if (feeder_done) state <= S_DRAIN_GO;

                S_DRAIN_GO:   state <= S_DRAIN_WAIT;
                S_DRAIN_WAIT: if (drain_done) state <= S_CMD_C;

                S_CMD_C: if (dma_cmd_ready) state <= S_WAIT_C;
                S_WAIT_C: begin
                    if (dma_err) begin
                        err_pulse <= 1'b1;
                        state     <= S_IDLE;
                    end else if (dma_done) begin
                        done_pulse <= 1'b1;
                        cycles     <= cnt + 32'd1;
                        state      <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule