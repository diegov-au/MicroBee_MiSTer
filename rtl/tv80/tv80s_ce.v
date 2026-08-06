//============================================================================
// tv80s_ce - tv80s with a clock enable.
//
// tv80s.v hardwires the core's `cen` to 1, so the CPU runs at the full clock
// rate. The MicroBee runs its Z80 at 3.375 MHz while the core's clk_sys is
// 54 MHz, so we need a clock enable instead of a divided clock (divided clocks
// need their own timing closure and don't play well with BRAM inference).
//
// This is tv80s.v with `cen` promoted to an input and the output-register
// block gated by it. Everything else is unchanged; see tv80s.v for the
// original. tv80 is MIT licensed - see LICENSE in this directory.
//============================================================================

`define TV80DELAY

module tv80s_ce (
  // Outputs
  m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n, A, dout,
  // Inputs
  reset_n, clk, cen, wait_n, int_n, nmi_n, busrq_n, di
  );

  parameter Mode = 0;    // 0 => Z80, 1 => Fast Z80, 2 => 8080, 3 => GB
  parameter T2Write = 1; // 0 => wr_n active in T3, /=0 => wr_n active in T2
  parameter IOWait  = 1; // 0 => Single cycle I/O, 1 => Std I/O cycle

  input         reset_n;
  input         clk;
  input         cen;
  input         wait_n;
  input         int_n;
  input         nmi_n;
  input         busrq_n;
  output        m1_n;
  output        mreq_n;
  output        iorq_n;
  output        rd_n;
  output        wr_n;
  output        rfsh_n;
  output        halt_n;
  output        busak_n;
  output [15:0] A;
  input [7:0]   di;
  output [7:0]  dout;

  reg           mreq_n;
  reg           iorq_n;
  reg           rd_n;
  reg           wr_n;

  wire          intcycle_n;
  wire          no_read;
  wire          write;
  wire          iorq;
  reg [7:0]     di_reg;
  wire [6:0]    mcycle;
  wire [6:0]    tstate;

  tv80_core #(Mode, IOWait) i_tv80_core
    (
     .cen (cen),
     .m1_n (m1_n),
     .iorq (iorq),
     .no_read (no_read),
     .write (write),
     .rfsh_n (rfsh_n),
     .halt_n (halt_n),
     .wait_n (wait_n),
     .int_n (int_n),
     .nmi_n (nmi_n),
     .reset_n (reset_n),
     .busrq_n (busrq_n),
     .busak_n (busak_n),
     .clk (clk),
     .IntE (),
     .stop (),
     .A (A),
     .dinst (di),
     .di (di_reg),
     .dout (dout),
     .mc (mcycle),
     .ts (tstate),
     .intcycle_n (intcycle_n)
     );

  always @(posedge clk or negedge reset_n)
    begin
      if (!reset_n)
        begin
          rd_n   <= `TV80DELAY 1'b1;
          wr_n   <= `TV80DELAY 1'b1;
          iorq_n <= `TV80DELAY 1'b1;
          mreq_n <= `TV80DELAY 1'b1;
          di_reg <= `TV80DELAY 0;
        end
      else if (cen)
        begin
          rd_n <= `TV80DELAY 1'b1;
          wr_n <= `TV80DELAY 1'b1;
          iorq_n <= `TV80DELAY 1'b1;
          mreq_n <= `TV80DELAY 1'b1;
          if (mcycle[0])
            begin
              if (tstate[1] || (tstate[2] && wait_n == 1'b0))
                begin
                  rd_n <= `TV80DELAY ~ intcycle_n;
                  mreq_n <= `TV80DELAY ~ intcycle_n;
                  iorq_n <= `TV80DELAY intcycle_n;
                end
            `ifdef TV80_REFRESH
              if (tstate[3])
            mreq_n <= `TV80DELAY 1'b0;
            `endif
            end // if (mcycle[0])
          else
            begin
              if ((tstate[1] || (tstate[2] && wait_n == 1'b0)) && no_read == 1'b0 && write == 1'b0)
                begin
                  rd_n <= `TV80DELAY 1'b0;
                  iorq_n <= `TV80DELAY ~ iorq;
                  mreq_n <= `TV80DELAY iorq;
                end
              if (T2Write == 0)
                begin
                  if (tstate[2] && write == 1'b1)
                    begin
                      wr_n <= `TV80DELAY 1'b0;
                      iorq_n <= `TV80DELAY ~ iorq;
                      mreq_n <= `TV80DELAY iorq;
                    end
                end
              else
                begin
                  if ((tstate[1] || (tstate[2] && wait_n == 1'b0)) && write == 1'b1)
                    begin
                      wr_n <= `TV80DELAY 1'b0;
                      iorq_n <= `TV80DELAY ~ iorq;
                      mreq_n <= `TV80DELAY iorq;
                  end
                end // else: !if(T2write == 0)

            end // else: !if(mcycle[0])

          if (tstate[2] && wait_n == 1'b1 && !write && !no_read)
            di_reg <= `TV80DELAY di;
        end // else: !if(!reset_n)
    end // always @ (posedge clk or negedge reset_n)

endmodule // tv80s_ce
