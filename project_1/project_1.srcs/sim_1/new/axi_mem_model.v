
`timescale 1ns/1ps

// Testbench-only AXI4 memory model.
// 16 KB memory represented as 4096 x 32-bit words.
// AXI4 interface: 64-bit data, 8 byte strobes.
// Each 64-bit beat accesses two adjacent 32-bit memory words.
//
// Supports queued bursts, randomized channel stalls, and SLVERR
// for accesses starting at addresses >= BAD_BASE.

module axi_mem_model #(
    parameter [31:0] BAD_BASE = 32'h0000_3000
) (
    input  wire         clk,
    input  wire         rst_n,

    // AXI4 write-address channel
    input  wire [31:0]  awaddr,
    input  wire [7:0]   awlen,
    input  wire [2:0]   awsize,
    input  wire [1:0]   awburst,
    input  wire         awvalid,
    output reg          awready,

    // AXI4 write-data channel
    input  wire [63:0]  wdata,
    input  wire [7:0]   wstrb,
    input  wire         wlast,
    input  wire         wvalid,
    output wire         wready,

    // AXI4 write-response channel
    output reg  [1:0]   bresp,
    output reg          bvalid,
    input  wire         bready,

    // AXI4 read-address channel
    input  wire [31:0]  araddr,
    input  wire [7:0]   arlen,
    input  wire [2:0]   arsize,
    input  wire [1:0]   arburst,
    input  wire         arvalid,
    output reg          arready,

    // AXI4 read-data channel
    output reg  [63:0]  rdata,
    output reg  [1:0]   rresp,
    output reg          rlast,
    output reg          rvalid,
    input  wire         rready
);

    localparam MEMWORDS = 4096;

    // Kept 32-bit for compatibility with existing initialization files.
    reg [31:0] dram [0:MEMWORDS-1];

    integer seed_ar = 11;
    integer seed_r  = 22;
    integer seed_aw = 33;
    integer seed_w  = 44;
    integer seed_b  = 55;

    integer ar_hs_count = 0;
    integer aw_hs_count = 0;
    integer proto_err   = 0;

    // Byte masks for the two 32-bit words within each 64-bit beat.
    wire [31:0] wmask_lo = {
        {8{wstrb[3]}},
        {8{wstrb[2]}},
        {8{wstrb[1]}},
        {8{wstrb[0]}}
    };

    wire [31:0] wmask_hi = {
        {8{wstrb[7]}},
        {8{wstrb[6]}},
        {8{wstrb[5]}},
        {8{wstrb[4]}}
    };

    // ============================================================
    // READ ADDRESS QUEUE
    // ============================================================

    reg [31:0] arq_addr [0:7];
    reg [7:0]  arq_len  [0:7];

    reg [2:0] arq_wp, arq_rp;
    reg [3:0] arq_cnt;

    reg        r_active;
    reg [31:0] r_addr_cur;
    reg [8:0]  r_left;

    always @(posedge clk) begin
        if (!rst_n) begin
            arready   <= 1'b0;
            arq_wp    <= 3'd0;
            arq_rp    <= 3'd0;
            arq_cnt   <= 4'd0;

            r_active  <= 1'b0;
            r_addr_cur <= 32'd0;
            r_left    <= 9'd0;

            rvalid    <= 1'b0;
            rdata     <= 64'd0;
            rresp     <= 2'b00;
            rlast     <= 1'b0;
        end else begin
            arready <= (arq_cnt <= 4) &&
                       ((($random(seed_ar)) & 3) != 0);

            if (arvalid && arready) begin
                arq_addr[arq_wp] <= araddr;
                arq_len[arq_wp]  <= arlen;
                arq_wp <= arq_wp + 3'd1;

                ar_hs_count = ar_hs_count + 1;

                if (arlen != 8'd15 ||
                    arsize != 3'd3 ||
                    arburst != 2'b01 ||
                    araddr[6:0] != 7'd0)
                    proto_err = proto_err + 1;
            end

            arq_cnt <= arq_cnt
                     + ((arvalid && arready) ? 4'd1 : 4'd0)
                     - ((!r_active && arq_cnt != 0) ? 4'd1 : 4'd0);

            if (rvalid && rready)
                rvalid <= 1'b0;

            if (!r_active) begin
                if (arq_cnt != 0) begin
                    r_active   <= 1'b1;
                    r_addr_cur <= arq_addr[arq_rp];
                    r_left     <= {1'b0, arq_len[arq_rp]} + 9'd1;
                    arq_rp     <= arq_rp + 3'd1;
                end
            end else if (!rvalid || rready) begin
                if (r_left != 0 &&
                    ((($random(seed_r)) & 3) != 0)) begin

                    if (r_addr_cur >= BAD_BASE) begin
                        rdata <= 64'd0;
                        rresp <= 2'b10;       // SLVERR
                    end else begin
                        // Little-endian mapping:
                        // lower address -> low 32-bit half
                        // next word      -> high 32-bit half
                        rdata <= {
                            dram[r_addr_cur[13:2] + 12'd1],
                            dram[r_addr_cur[13:2]]
                        };
                        rresp <= 2'b00;
                    end

                    rvalid <= 1'b1;
                    rlast  <= (r_left == 9'd1);

                    r_addr_cur <= r_addr_cur + 32'd8;
                    r_left     <= r_left - 9'd1;

                    if (r_left == 9'd1)
                        r_active <= 1'b0;
                end
            end
        end
    end

    // ============================================================
    // WRITE ADDRESS QUEUE
    // ============================================================

    reg [31:0] awq_addr [0:7];
    reg [7:0]  awq_len  [0:7];

    reg [2:0] awq_wp, awq_rp;
    reg [3:0] awq_cnt;

    reg        w_active;
    reg        w_bad;
    reg        w_rnd_q;

    reg [31:0] w_addr_cur;
    reg [8:0]  w_left;

    // ============================================================
    // WRITE RESPONSE QUEUE
    // ============================================================

    reg [1:0] bq [0:31];

    reg [4:0] bq_wp, bq_rp;
    reg [5:0] bq_cnt;

    reg b_push, b_pop;

    assign wready = w_active && w_rnd_q;

    always @(posedge clk) begin
        if (!rst_n) begin
            awready  <= 1'b0;
            w_rnd_q  <= 1'b0;

            awq_wp   <= 3'd0;
            awq_rp   <= 3'd0;
            awq_cnt  <= 4'd0;

            w_active <= 1'b0;
            w_bad    <= 1'b0;
            w_addr_cur <= 32'd0;
            w_left   <= 9'd0;

            bq_wp    <= 5'd0;
            bq_rp    <= 5'd0;
            bq_cnt   <= 6'd0;

            bvalid   <= 1'b0;
            bresp    <= 2'b00;
        end else begin
            b_push = 1'b0;
            b_pop  = 1'b0;

            awready <= (awq_cnt <= 4) &&
                       ((($random(seed_aw)) & 3) != 0);

            w_rnd_q <= ((($random(seed_w)) & 3) != 0);

            if (awvalid && awready) begin
                awq_addr[awq_wp] <= awaddr;
                awq_len[awq_wp]  <= awlen;
                awq_wp <= awq_wp + 3'd1;

                aw_hs_count = aw_hs_count + 1;

                if ((awlen != 8'd15 && awlen != 8'd31) ||
                    awsize != 3'd3 ||
                    awburst != 2'b01 ||
                    awaddr[6:0] != 7'd0)
                    proto_err = proto_err + 1;
            end

            awq_cnt <= awq_cnt
                     + ((awvalid && awready) ? 4'd1 : 4'd0)
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

                if (!w_bad) begin
                    // Write bytes [3:0] to the lower-address 32-bit word.
                    if (|wstrb[3:0]) begin
                        dram[w_addr_cur[13:2]] <=
                            (dram[w_addr_cur[13:2]] & ~wmask_lo) |
                            (wdata[31:0] & wmask_lo);
                    end

                    // Write bytes [7:4] to the next 32-bit word.
                    if (|wstrb[7:4]) begin
                        dram[w_addr_cur[13:2] + 12'd1] <=
                            (dram[w_addr_cur[13:2] + 12'd1] & ~wmask_hi) |
                            (wdata[63:32] & wmask_hi);
                    end
                end

                w_addr_cur <= w_addr_cur + 32'd8;
                w_left     <= w_left - 9'd1;

                if ((w_left == 9'd1) != wlast)
                    proto_err = proto_err + 1;

                if (w_left == 9'd1) begin
                    w_active  <= 1'b0;
                    bq[bq_wp] <= w_bad ? 2'b10 : 2'b00;
                    bq_wp     <= bq_wp + 5'd1;
                    b_push    = 1'b1;
                end
            end

            if (bvalid && bready)
                bvalid <= 1'b0;

            if ((!bvalid || bready) &&
                bq_cnt != 0 &&
                ((($random(seed_b)) & 3) != 0)) begin

                bvalid <= 1'b1;
                bresp  <= bq[bq_rp];
                bq_rp  <= bq_rp + 5'd1;
                b_pop  = 1'b1;
            end

            bq_cnt <= bq_cnt
                    + (b_push ? 6'd1 : 6'd0)
                    - (b_pop  ? 6'd1 : 6'd0);
        end
    end

endmodule
