//
// Copyright 2019 Ettus Research, a National Instruments Company
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Module: radio_tx_core
//
// Description:
//
// This module contains the core Tx radio data-path logic. It receives samples 
// over AXI-Stream that it then sends to the radio interface coincident with a 
// strobe signal that must be provided by the radio interface.
//
// There are no registers for starting or stopping the transmitter. It is 
// operated simply by providing data packets via its AXI-Stream data interface. 
// The end-of-burst (EOB) signal is used to indicate when the transmitter is 
// allowed to stop transmitting. Packet timestamps can be used to indicate when 
// transmission should start.
//
// Care must be taken to provide data to the transmitter at a rate that is 
// faster than the radio needs it so that underflows do not occur. Similarly, 
// timed packets must be delivered before the timestamp expires. If a packet 
// arrives late, then it will be dropped and the error will be reported via the 
// CTRL port interface.
//
// Parameters:
//
//   SAMP_W : Width of a radio sample
//   NSPC   : Number of radio samples per radio clock cycle
//


module radio_tx_core #(
  parameter SAMP_W = 32,
  parameter NSPC   = 1
) (
  input wire radio_clk,
  input wire radio_rst,


  //---------------------------------------------------------------------------
  // Control Interface
  //---------------------------------------------------------------------------

  // Slave (Register Reads and Writes)
  input  wire        s_ctrlport_req_wr,
  input  wire        s_ctrlport_req_rd,
  input  wire [19:0] s_ctrlport_req_addr,
  input  wire [31:0] s_ctrlport_req_data,
  output reg         s_ctrlport_resp_ack  = 1'b0,
  output reg  [31:0] s_ctrlport_resp_data,

  // Master (Error Reporting)
  output reg         m_ctrlport_req_wr = 1'b0,
  output reg  [19:0] m_ctrlport_req_addr,
  output reg  [31:0] m_ctrlport_req_data,
  output wire [ 9:0] m_ctrlport_req_portid,
  output wire [15:0] m_ctrlport_req_rem_epid,
  output wire [ 9:0] m_ctrlport_req_rem_portid,
  input  wire        m_ctrlport_resp_ack,


  //---------------------------------------------------------------------------
  // Radio Interface
  //---------------------------------------------------------------------------

  input wire [63:0] radio_time,

  output wire [SAMP_W*NSPC-1:0] radio_tx_data,
  input  wire                   radio_tx_stb,

  // Status indicator (true when transmitting)
  output wire radio_tx_running,


  //---------------------------------------------------------------------------
  // AXI-Stream Data Input
  //---------------------------------------------------------------------------

  input  wire [SAMP_W*NSPC-1:0] s_axis_tdata,
  input  wire                   s_axis_tlast,
  input  wire                   s_axis_tvalid,
  output wire                   s_axis_tready,
  // Sideband info
  input  wire [           63:0] s_axis_ttimestamp,
  input  wire                   s_axis_thas_time,
  input  wire                   s_axis_teob
);

  `include "rfnoc_block_radio_regs.vh"
  `include "../../core/rfnoc_chdr_utils.vh"


  //---------------------------------------------------------------------------
  // Register Read/Write Logic
  //---------------------------------------------------------------------------

  reg [SAMP_W-1:0] reg_idle_value       = 0; // Value to output when transmitter is idle
  reg [       9:0] reg_error_portid     = 0; // Port ID to use for error reporting
  reg [      15:0] reg_error_rem_epid   = 0; // Remote EPID to use for error reporting
  reg [       9:0] reg_error_rem_portid = 0; // Remote port ID to use for error reporting
  reg [      19:0] reg_error_addr       = 0; // Address to use for error reporting

  reg [TX_ERR_POLICY_LEN-1:0] reg_policy = TX_ERR_POLICY_PACKET;

  always @(posedge radio_clk) begin
    if (radio_rst) begin
      s_ctrlport_resp_ack  <= 0;
      reg_idle_value       <= 0;
      reg_error_portid     <= 0;
      reg_error_rem_epid   <= 0;
      reg_error_rem_portid <= 0;
      reg_error_addr       <= 0;
      reg_policy           <= TX_ERR_POLICY_PACKET;
    end else begin
      // Default assignments
      s_ctrlport_resp_ack  <= 0;
      s_ctrlport_resp_data <= 0;

      // Handle register writes
      if (s_ctrlport_req_wr) begin
        case (s_ctrlport_req_addr)
          REG_TX_IDLE_VALUE: begin
            reg_idle_value      <= s_ctrlport_req_data[SAMP_W-1:0];
            s_ctrlport_resp_ack <= 1;
          end
          REG_TX_ERROR_POLICY: begin
            // Only allow valid configurations
            case (s_ctrlport_req_data[TX_ERR_POLICY_LEN-1:0])
              TX_ERR_POLICY_PACKET : reg_policy <= TX_ERR_POLICY_PACKET;
              TX_ERR_POLICY_BURST  : reg_policy <= TX_ERR_POLICY_BURST;
              default              : reg_policy <= TX_ERR_POLICY_PACKET;
            endcase
            s_ctrlport_resp_ack <= 1;
          end
          REG_TX_ERR_PORT: begin
            reg_error_portid    <= s_ctrlport_req_data[9:0];
            s_ctrlport_resp_ack <= 1;
          end
          REG_TX_ERR_REM_PORT: begin
            reg_error_rem_portid <= s_ctrlport_req_data[9:0];
            s_ctrlport_resp_ack  <= 1;
          end
          REG_TX_ERR_REM_EPID: begin
            reg_error_rem_epid  <= s_ctrlport_req_data[15:0];
            s_ctrlport_resp_ack <= 1;
          end
          REG_TX_ERR_ADDR: begin
            reg_error_addr      <= s_ctrlport_req_data[19:0];
            s_ctrlport_resp_ack <= 1;
          end
        endcase
      end

      // Handle register reads
      if (s_ctrlport_req_rd) begin
        case (s_ctrlport_req_addr)
          REG_TX_IDLE_VALUE: begin
            s_ctrlport_resp_data[SAMP_W-1:0] <= reg_idle_value;
            s_ctrlport_resp_ack              <= 1;
          end
          REG_TX_ERROR_POLICY: begin
            s_ctrlport_resp_data[TX_ERR_POLICY_LEN-1:0] <= reg_policy;
            s_ctrlport_resp_ack                         <= 1;
          end
          REG_TX_ERR_PORT: begin
            s_ctrlport_resp_data[9:0] <= reg_error_portid;
            s_ctrlport_resp_ack       <= 1;
          end
          REG_TX_ERR_REM_PORT: begin
            s_ctrlport_resp_data[9:0] <= reg_error_rem_portid;
            s_ctrlport_resp_ack       <= 1;
          end
          REG_TX_ERR_REM_EPID: begin
            s_ctrlport_resp_data[15:0] <= reg_error_rem_epid;
            s_ctrlport_resp_ack        <= 1;
          end
          REG_TX_ERR_ADDR: begin
            s_ctrlport_resp_data[19:0] <= reg_error_addr;
            s_ctrlport_resp_ack        <= 1;
          end
        endcase
      end
    end
  end


  //---------------------------------------------------------------------------
  // Transmitter State Machine
  //---------------------------------------------------------------------------

  // FSM state values
  localparam ST_IDLE        = 0;
  localparam ST_TIME_CHECK  = 1;
  localparam ST_TRANSMIT    = 2;
  localparam ST_POLICY_WAIT = 3;

  reg [1:0] state = ST_IDLE;

  reg sop = 1'b1;  // Start of packet
  reg eob = 1'b0;  // End of burst

  reg [ERR_TX_CODE_W-1:0] new_error_code;
  reg [             63:0] new_error_time;
  reg                     new_error_valid = 1'b0;

  reg time_now, time_past;


  always @(posedge radio_clk) begin
    if (radio_rst) begin
      state           <= ST_IDLE;
      sop             <= 1'b1;
      eob             <= 1'b0;
      new_error_valid <= 1'b0;
    end else begin
      new_error_valid <= 1'b0;

      // Register time comparisons so they don't become the critical path
      time_now  <= (radio_time == s_axis_ttimestamp);
      time_past <= (radio_time >  s_axis_ttimestamp);

      // Track when a burst ends (eob) and when we are expecting the next
      // packet start (sop).
      if (s_axis_tvalid & s_axis_tready) begin
        if (s_axis_tlast) begin
          // This is the last word of packet, so set sop to indicate the next
          // packet should be starting soon.
          sop <= 1'b1;
        end else if (sop) begin
          // This is the first word of a new packet, so reset sop and set eob
          // if this is the last packet of a burst.
          sop <= 1'b0;
          eob <= s_axis_teob;
        end
      end

      case (state)
        ST_IDLE : begin
          // Wait for a new packet to arrive and allow a cycle for the time 
          // comparisons to update.
          if (s_axis_tvalid) begin
            state <= ST_TIME_CHECK;
          end
        end

        ST_TIME_CHECK : begin
          if (!s_axis_thas_time || time_now) begin
            // We have a new packet without a timestamp, or a new packet
            // whose time has arrived.
            state <= ST_TRANSMIT;
          end else if (time_past) begin
            // We have a new packet with a timestamp, but the time has passed.
            //synthesis translate off
            $display("WARNING: radio_tx_core: Late data error");
            //synthesis translate_on
            new_error_code  <= ERR_TX_LATE_DATA;
            new_error_time  <= radio_time;
            new_error_valid <= 1'b1;
            state           <= ST_POLICY_WAIT;
          end
        end

        ST_TRANSMIT : begin
          if (radio_tx_stb) begin
            if (~s_axis_tvalid) begin
              // The radio strobed for new data but we don't have any to give
              //synthesis translate off
              $display("WARNING: radio_tx_core: Underrun error");
              //synthesis translate_on
              new_error_code  <= ERR_TX_UNDERRUN;
              new_error_time  <= radio_time;
              new_error_valid <= 1'b1;
              state           <= ST_POLICY_WAIT;
            end else if (s_axis_tlast & eob) begin
              // We're done with this burst of packets, so go back to idle
              state <= ST_IDLE;
            end
          end
        end

        ST_POLICY_WAIT : begin
          // Wait here for the end of the packet or the end of the burst,
          // depending on the policy that's configured.
          if ((s_axis_tvalid & s_axis_tlast) | (~s_axis_tvalid & sop)) begin
            // We're either at the end of a packet or between packets
            if (reg_policy == TX_ERR_POLICY_PACKET ||
               ((reg_policy == TX_ERR_POLICY_BURST) & eob)) begin
              state <= ST_IDLE;
            end
          end
        end

        default : state <= ST_IDLE;
      endcase
    end
  end


  // Output the current sample whenever we're transmitting and the sample is
  // valid. Otherwise, output the idle value.
  assign radio_tx_data = (s_axis_tvalid && state == ST_TRANSMIT) ?
                         s_axis_tdata :
                         {NSPC{reg_idle_value[SAMP_W-1:0]}};

  // Read packet in the transmit state or dump it in the error state
  assign s_axis_tready = (radio_tx_stb & (state == ST_TRANSMIT)) |
                         (state == ST_POLICY_WAIT);

  // Indicate whether Tx interface is actively transmitting
  assign radio_tx_running = (state == ST_TRANSMIT);


  //---------------------------------------------------------------------------
  // Error FIFO
  //---------------------------------------------------------------------------
  //
  // This FIFO queues up errors in case we get multiple errors in a row faster
  // than they can be reported. If the FIFO fills then new errors will be
  // ignored.
  //
  //---------------------------------------------------------------------------

  // Error information
  wire [ERR_TX_CODE_W-1:0] next_error_code;
  wire [             63:0] next_error_time;
  wire                     next_error_valid;
  reg                      next_error_ready = 1'b0;

  wire new_error_ready;

  axi_fifo_short #(
    .WIDTH (64 + ERR_TX_CODE_W)
  ) error_fifo (
    .clk      (radio_clk),
    .reset    (radio_rst),
    .clear    (1'b0),
    .i_tdata  ({new_error_time, new_error_code}),
    .i_tvalid (new_error_valid & new_error_ready),   // Mask with ready to prevent FIFO corruption
    .i_tready (new_error_ready),
    .o_tdata  ({next_error_time, next_error_code}),
    .o_tvalid (next_error_valid),
    .o_tready (next_error_ready),
    .space    (),
    .occupied ()
  );

  //synthesis translate_off
  // Output a message if the error FIFO overflows
  always @(posedge radio_clk) begin
    if (new_error_valid && !new_error_ready) begin
      $display("WARNING: Tx error report dropped!");
    end
  end
  //synthesis translate_on


  //---------------------------------------------------------------------------
  // Error Reporting State Machine
  //---------------------------------------------------------------------------
  //
  // This state machine reports errors that have been queued up in the error
  // FIFO.
  //
  //---------------------------------------------------------------------------

  localparam ST_ERR_IDLE     = 0;
  localparam ST_ERR_CODE     = 1;
  localparam ST_ERR_TIME_LO  = 2;
  localparam ST_ERR_TIME_HI  = 3;

  reg [1:0] err_state = ST_ERR_IDLE;

  always @(posedge radio_clk) begin
    if (radio_rst) begin
      m_ctrlport_req_wr <= 1'b0;
      err_state         <= ST_ERR_IDLE;
      next_error_ready  <= 1'b0;
    end else begin
      m_ctrlport_req_wr <= 1'b0;
      next_error_ready  <= 1'b0;

      case (err_state)
        ST_ERR_IDLE : begin
          if (next_error_valid) begin
            // Setup write of error code
            m_ctrlport_req_wr   <= 1'b1;
            m_ctrlport_req_addr <= reg_error_addr;
            m_ctrlport_req_data <= {{(32-ERR_TX_CODE_W){1'b0}}, next_error_code};
            next_error_ready    <= 1'b1;
            err_state           <= ST_ERR_CODE;
          end
        end

        ST_ERR_CODE : begin
          // Wait for write of error code. Setup write of low word of time when done.
          if (m_ctrlport_resp_ack) begin
            m_ctrlport_req_wr   <= 1'b1;
            m_ctrlport_req_data <= next_error_time[31:0];
            m_ctrlport_req_addr <= reg_error_addr + 8;
            err_state           <= ST_ERR_TIME_LO;
          end
        end

        ST_ERR_TIME_LO : begin
          // Wait for write of low word of time. Setup write of high word when done.
          if (m_ctrlport_resp_ack) begin
            m_ctrlport_req_wr   <= 1'b1;
            m_ctrlport_req_data <= next_error_time[63:32];
            m_ctrlport_req_addr <= reg_error_addr + 12;
            err_state           <= ST_ERR_TIME_HI;
          end
        end

        ST_ERR_TIME_HI : begin
          // Wait for write of high word of time
          if (m_ctrlport_resp_ack) begin
            err_state <= ST_ERR_IDLE;
          end
        end

        default : err_state <= ST_ERR_IDLE;
      endcase
    end
  end


  // Directly connect the port ID, remote port ID, remote EPID since they are 
  // only used for error reporting.
  assign m_ctrlport_req_portid     = reg_error_portid;
  assign m_ctrlport_req_rem_epid   = reg_error_rem_epid;
  assign m_ctrlport_req_rem_portid = reg_error_rem_portid;


endmodule