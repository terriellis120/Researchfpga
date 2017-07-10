//
// Copyright 2016 Ettus Research LLC
//

module aurora_phy_x1 #(
   parameter SIMULATION = 0
)(
   // Clocks and Resets
   input             areset,
   input             refclk,
   input             init_clk,
   input             qpllclk,
   input             qpllrefclk,
   output            user_clk,
   output            user_rst,
   // GTX Serial I/O
   input             rx_p,
   input             rx_n,
   output            tx_p,
   output            tx_n,
   // AXI4-Stream TX Interface
   input  [63:0]     s_axis_tdata, 
   input             s_axis_tvalid,
   output            s_axis_tready,
   // AXI4-Stream RX Interface
   output [63:0]     m_axis_tdata,  
   output            m_axis_tvalid,
   // AXI4-Lite Config Interface
   input  [31:0]     s_axi_awaddr,
   input  [31:0]     s_axi_araddr,
   input  [31:0]     s_axi_wdata,
   input  [3:0]      s_axi_wstrb,
   input             s_axi_awvalid, 
   input             s_axi_rready, 
   output  [31:0]    s_axi_rdata,
   output            s_axi_awready,
   output            s_axi_wready, 
   output            s_axi_bvalid, 
   output  [1:0]     s_axi_bresp, 
   output  [1:0]     s_axi_rresp, 
   input             s_axi_bready, 
   output            s_axi_arready, 
   output            s_axi_rvalid, 
   input             s_axi_arvalid, 
   input             s_axi_wvalid, 
   // Status and Error Reporting Interface
   output reg        channel_up,
   output reg        hard_err,
   output reg        soft_err,
   input             qplllock,
   output            qpllreset,
   output            qpllrefclklost

);

   //--------------------------------------------------------------
   // Status and Error Signals
   //--------------------------------------------------------------
   wire hard_err_i, soft_err_i, channel_up_i, lane_up_i;
   always @(posedge user_clk) begin
      hard_err   <= hard_err_i;
      soft_err   <= soft_err_i;
      channel_up <= channel_up_i && lane_up_i;
   end

   //--------------------------------------------------------------
   // Reset and PMA Init Sequence
   //--------------------------------------------------------------
   // Requirements from PG074:
   // -  It is expected that user_clock is stable when the reset_pb signal is applied.
   // -  During the board power-on sequence, both the pma_init and reset_pb signals are
   //    expected to be High. INIT_CLK and GT_REFCLK are expected to be stable during
   //    power-on for the proper functioning of the Aurora 64B/66B core. When both clocks are
   //    stable, pma_init is deasserted followed by the deassertion of reset_pb.
   // - Normal Operation Reset Sequence:
   //   1. Assert reset. Wait for a minimum time equal to 128*user_clk's time-period.
   //   2. Assert pma_init. Keep pma_init and reset asserted for at least one second to prevent
   //      the transmission of CC characters and ensure that the remote agent detects a hot plug event.
   //   3. Deassert pma_init.
   //   4. Deassert reset_pb.

   localparam PWRON_PMA_INIT_CYC       = 32'd1024;
   localparam SYSRST_ASSERT_CYC        = 32'd128;
   localparam PMA_INIT_ASSERT_CYC_LOG2 = (SIMULATION == 1) ? 4 : 26;
   localparam SYSRST_DEASSERT_CYC      = 32'd20;

   wire reset_iclk, pma_init, reset_pb;
   wire gt_pll_lock, gt_pll_lock_iclk, mmcm_locked, mmcm_locked_iclk;

   synchronizer #( .STAGES(3), .INITIAL_VAL(1'b1) ) input_rst_sync_i (
      .clk(init_clk), .rst(1'b0), .in(areset), .out(reset_iclk)
   );

   synchronizer #( .STAGES(3), .INITIAL_VAL(1'b0) ) gt_pll_lock_sync_i (
      .clk(init_clk), .rst(1'b0), .in(gt_pll_lock), .out(gt_pll_lock_iclk)
   );

   synchronizer #( .STAGES(3), .INITIAL_VAL(1'b0) ) mmcm_locked_sync_i (
      .clk(init_clk), .rst(1'b0), .in(mmcm_locked), .out(mmcm_locked_iclk)
   );

   localparam [2:0] RST_ST_PWRON_PMA_INIT    = 3'd0;
   localparam [2:0] RST_ST_PWRON_PMA_SYSRST  = 3'd1;
   localparam [2:0] RST_ST_IDLE              = 3'd2;
   localparam [2:0] RST_ST_SYSRST_PRE        = 3'd3;
   localparam [2:0] RST_ST_PMA_INIT          = 3'd4;
   localparam [2:0] RST_ST_SYSRST_POST       = 3'd5;

   reg [2:0]  rst_state = RST_ST_PWRON_PMA_INIT;
   reg [31:0] rst_counter = PWRON_PMA_INIT_CYC;

   always @(posedge init_clk) begin
      case (rst_state)
         RST_ST_PWRON_PMA_INIT: begin
            if (rst_counter == 32'd0) begin
               rst_state   <= RST_ST_PWRON_PMA_SYSRST;
               rst_counter <= SYSRST_DEASSERT_CYC;
            end else begin
               rst_counter <= rst_counter - 32'd1;
            end
         end
         RST_ST_PWRON_PMA_SYSRST: begin
            if (rst_counter == 32'd0) begin
               rst_state   <= RST_ST_IDLE;
            end else begin
               rst_counter <= rst_counter - 32'd1;
            end
         end
         RST_ST_IDLE: begin
            if (reset_iclk) begin
               rst_state   <= RST_ST_SYSRST_PRE;
               rst_counter <= SYSRST_ASSERT_CYC;
            end
         end
         RST_ST_SYSRST_PRE: begin
            if (rst_counter == 32'd0) begin
               rst_state   <= RST_ST_PMA_INIT;
               rst_counter <= {{(32-PMA_INIT_ASSERT_CYC_LOG2){1'b0}}, {PMA_INIT_ASSERT_CYC_LOG2{1'b1}}};
            end else if (mmcm_locked_iclk) begin
               rst_counter <= rst_counter - 32'd1;
            end
         end
         RST_ST_PMA_INIT: begin
            if (rst_counter == 32'd0) begin
               rst_state   <= RST_ST_SYSRST_POST;
               rst_counter <= SYSRST_DEASSERT_CYC;
            end else begin
               rst_counter <= rst_counter - 32'd1;
            end
         end
         RST_ST_SYSRST_POST: begin
            if (rst_counter == 32'd0) begin
               rst_state   <= RST_ST_IDLE;
            end else begin
               rst_counter <= rst_counter - 32'd1;
            end
         end
      endcase
   end

   assign reset_pb = (rst_state != RST_ST_IDLE);
   assign pma_init = (rst_state == RST_ST_PMA_INIT || rst_state == RST_ST_PWRON_PMA_INIT);

   //--------------------------------------------------------------
   // Clocking
   //--------------------------------------------------------------

   wire tx_out_clk, tx_out_clk_bufg;
   wire sync_clk_i;
   wire user_clk_i;
   wire mmcm_fb_clk;
   wire sync_clk;

   localparam MULT        = 10;
   localparam DIVIDE      = 5;
   localparam CLK_PERIOD  = 3.103;
   localparam OUT0_DIVIDE = 4;
   localparam OUT1_DIVIDE = 2;
   localparam OUT2_DIVIDE = 6;
   localparam OUT3_DIVIDE = 8;

   MMCME2_ADV #(
      .BANDWIDTH            ("OPTIMIZED"),
      .CLKOUT4_CASCADE      ("FALSE"),
      .COMPENSATION         ("ZHOLD"),
      .STARTUP_WAIT         ("FALSE"),
      .DIVCLK_DIVIDE        (DIVIDE),
      .CLKFBOUT_MULT_F      (MULT),
      .CLKFBOUT_PHASE       (0.000),
      .CLKFBOUT_USE_FINE_PS ("FALSE"),
      .CLKOUT0_DIVIDE_F     (OUT0_DIVIDE),
      .CLKOUT0_PHASE        (0.000),
      .CLKOUT0_DUTY_CYCLE   (0.500),
      .CLKOUT0_USE_FINE_PS  ("FALSE"),
      .CLKIN1_PERIOD        (CLK_PERIOD),
      .CLKOUT1_DIVIDE       (OUT1_DIVIDE),
      .CLKOUT1_PHASE        (0.000),
      .CLKOUT1_DUTY_CYCLE   (0.500),
      .CLKOUT1_USE_FINE_PS  ("FALSE"),
      .CLKOUT2_DIVIDE       (OUT2_DIVIDE),
      .CLKOUT2_PHASE        (0.000),
      .CLKOUT2_DUTY_CYCLE   (0.500),
      .CLKOUT2_USE_FINE_PS  ("FALSE"),
      .CLKOUT3_DIVIDE       (OUT3_DIVIDE),
      .CLKOUT3_PHASE        (0.000),
      .CLKOUT3_DUTY_CYCLE   (0.500),
      .CLKOUT3_USE_FINE_PS  ("FALSE"),
      .REF_JITTER1          (0.010)
   ) mmcm_adv_inst (
      .CLKFBOUT            (mmcm_fb_clk),
      .CLKFBOUTB           (),
      .CLKOUT0             (user_clk_i),
      .CLKOUT0B            (),
      .CLKOUT1             (sync_clk_i),
      .CLKOUT1B            (),
      .CLKOUT2             (),
      .CLKOUT2B            (),
      .CLKOUT3             (),
      .CLKOUT3B            (),
      .CLKOUT4             (),
      .CLKOUT5             (),
      .CLKOUT6             (),
       // Input clock control
      .CLKFBIN             (mmcm_fb_clk),
      .CLKIN1              (tx_out_clk_bufg),
      .CLKIN2              (1'b0),
       // Tied to always select the primary input clock
      .CLKINSEL            (1'b1),
      // Ports for dynamic reconfiguration
      .DADDR               (7'h0),
      .DCLK                (1'b0),
      .DEN                 (1'b0),
      .DI                  (16'h0),
      .DO                  (),
      .DRDY                (),
      .DWE                 (1'b0),
      // Ports for dynamic phase shift
      .PSCLK               (1'b0),
      .PSEN                (1'b0),
      .PSINCDEC            (1'b0),
      .PSDONE              (),
      // Other control and status signals
      .LOCKED              (mmcm_locked),
      .CLKINSTOPPED        (),
      .CLKFBSTOPPED        (),
      .PWRDWN              (1'b0),
      .RST                 (!gt_pll_lock)
   );

   // BUFG for the feedback clock.  The feedback signal is phase aligned to the input
   // and must come from the CLK0 or CLK2X output of the PLL.  In this case, we use
   // the CLK0 output.
   BUFG txout_clock_net_i (
      .I(tx_out_clk),
      .O(tx_out_clk_bufg)
   );
   BUFG user_clk_net_i (
      .I(user_clk_i),
      .O(user_clk)
   );
   BUFG sync_clock_net_i (
      .I(sync_clk_i),
      .O(sync_clk)
   );

   //--------------------------------------------------------------
   // GT Common
   //--------------------------------------------------------------

   wire gt_qpllclk_quad1_i;
   wire gt_qpllrefclk_quad1_i;
   wire gt_to_common_qpllreset_i;
   wire gt_qpllrefclklost_i; 
   wire gt_qplllock_i; 
   
   assign gt_qpllclk_quad1_i = qpllclk;
   assign gt_qpllrefclk_quad1_i =  qpllrefclk;
   assign gt_qplllock_i = qplllock;
   assign qpllreset = gt_to_common_qpllreset_i;
   assign qpllrefclklost = gt_qpllrefclklost_i;

   //wire    [7:0]      qpll_drpaddr_in_i = 8'h0;
   //wire    [15:0]     qpll_drpdi_in_i = 16'h0;
   //wire               qpll_drpen_in_i =  1'b0;
   //wire               qpll_drpwe_in_i =  1'b0;
   //wire    [15:0]     qpll_drpdo_out_i;
   //wire               qpll_drprdy_out_i;

   //aurora_64b66b_pcs_pma_gt_common_wrapper gt_common_support (
   //   .gt_qpllclk_quad1_out      (gt_qpllclk_quad1_i),
   //   .gt_qpllrefclk_quad1_out   (gt_qpllrefclk_quad1_i),
   //   .GT0_GTREFCLK0_COMMON_IN   (refclk), 
   //   //----------------------- Common Block - QPLL Ports ------------------------
   //   .GT0_QPLLLOCK_OUT          (gt_qplllock_i),
   //   .GT0_QPLLRESET_IN          (gt_to_common_qpllreset_i),
   //   .GT0_QPLLLOCKDETCLK_IN     (init_clk),
   //   .GT0_QPLLREFCLKLOST_OUT    (gt_qpllrefclklost_i),
   //   //---------------------- Common DRP Ports ----------------------
   //   .qpll_drpaddr_in           (qpll_drpaddr_in_i),
   //   .qpll_drpdi_in             (qpll_drpdi_in_i),
   //   .qpll_drpclk_in            (init_clk),
   //   .qpll_drpdo_out            (qpll_drpdo_out_i), 
   //   .qpll_drprdy_out           (qpll_drprdy_out_i), 
   //   .qpll_drpen_in             (qpll_drpen_in_i), 
   //  .qpll_drpwe_in             (qpll_drpwe_in_i)
   //);

   //--------------------------------------------------------------
   // IP Instantiation
   //--------------------------------------------------------------

   wire        gt_rxcdrovrden_i  = 1'b0;
   wire [2:0]  loopback_i        = 3'b000;
   wire        power_down_i      = 1'b0;

   aurora_64b66b_pcs_pma aurora_64b66b_pcs_pma_i (
      .refclk1_in                (refclk),
      // TX AXI4-S Interface
      .s_axi_tx_tdata            (s_axis_tdata),
      .s_axi_tx_tvalid           (s_axis_tvalid),
      .s_axi_tx_tready           (s_axis_tready),
      // RX AXI4-S Interface
      .m_axi_rx_tdata            (m_axis_tdata),
      .m_axi_rx_tvalid           (m_axis_tvalid),
      // GTX Serial I/O
      .rxp                       (rx_p),
      .rxn                       (rx_n),
      .txp                       (tx_p),
      .txn                       (tx_n),
      // Status and Error
      .hard_err                  (hard_err_i),
      .soft_err                  (soft_err_i),
      .channel_up                (channel_up_i),
      .lane_up                   (lane_up_i),
      // System Interface
      .mmcm_not_locked           (!mmcm_locked),
      .user_clk                  (user_clk),
      .sync_clk                  (sync_clk),
      .reset_pb                  (reset_pb),
      .gt_rxcdrovrden_in         (gt_rxcdrovrden_i),
      .power_down                (power_down_i),
      .loopback                  (loopback_i),
      .pma_init                  (pma_init),
      .gt_pll_lock               (gt_pll_lock),
      .drp_clk_in                (init_clk),
      .gt_qpllclk_quad1_in       (gt_qpllclk_quad1_i),
      .gt_qpllrefclk_quad1_in    (gt_qpllrefclk_quad1_i),
      .gt_to_common_qpllreset_out(gt_to_common_qpllreset_i),
      .gt_qplllock_in            (gt_qplllock_i), 
      .gt_qpllrefclklost_in      (gt_qpllrefclklost_i),
      // AXI4-Lite config
      .s_axi_awaddr              (s_axi_awaddr),
      .s_axi_awvalid             (s_axi_awvalid), 
      .s_axi_awready             (s_axi_awready), 
      .s_axi_wdata               (s_axi_wdata),
      .s_axi_wstrb               (s_axi_wstrb),
      .s_axi_wvalid              (s_axi_wvalid), 
      .s_axi_wready              (s_axi_wready), 
      .s_axi_bvalid              (s_axi_bvalid), 
      .s_axi_bresp               (s_axi_bresp), 
      .s_axi_bready              (s_axi_bready), 
      .s_axi_araddr              (s_axi_araddr),
      .s_axi_arvalid             (s_axi_arvalid), 
      .s_axi_arready             (s_axi_arready), 
      .s_axi_rdata               (s_axi_rdata),
      .s_axi_rvalid              (s_axi_rvalid), 
      .s_axi_rresp               (s_axi_rresp), 
      .s_axi_rready              (s_axi_rready), 
      // GTXE2 COMMON DRP Ports
      .qpll_drpaddr_in           (qpll_drpaddr_in_i),
      .qpll_drpdi_in             (qpll_drpdi_in_i),
      .qpll_drpdo_out            (), 
      .qpll_drprdy_out           (), 
      .qpll_drpen_in             (qpll_drpen_in_i), 
      .qpll_drpwe_in             (qpll_drpwe_in_i), 
      .init_clk                  (init_clk),
      .link_reset_out            (),
      .sys_reset_out             (user_rst),
      .tx_out_clk                (tx_out_clk)
   );

 endmodule
