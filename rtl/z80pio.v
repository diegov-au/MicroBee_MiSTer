//============================================================================
// z80pio - Zilog Z80 PIO (parallel I/O), two ports, IM2 interrupts.
//
// Written for the MicroBee, which uses it as:
//   port A  mode 0 (output)      - Centronics parallel printer
//   port B  mode 3 (bit control) - speaker, cassette, RS232
//
// Port B bit assignment (ubee512 src/pio.h):
//   0 cassette in     1 cassette out    2 RS232 DTR   3 RS232 CTS
//   4 RS232 RX        5 RS232 TX        6 SPEAKER     7 model-dependent
//
// On the 64K CIAB bit 7 is `MODPB7_PUP` - a pull-up, so it always reads 1.
// Other models put vsync or the RTC there, which is where the 50 Hz interrupt
// comes from on those machines; the CIAB has no such interrupt.
//
// Address mapping is the MicroBee's: addr[0] selects control over data,
// addr[1] selects port B over port A, giving $00 A-data, $01 A-control,
// $02 B-data, $03 B-control.
//
// The control-word decode below was checked against the CIAB boot ROM's own
// initialisation sequence (it writes the PIO through OTIR at $E064), each write
// matching what ubee512's --modio pio reports for the same byte:
//
//   A: $48 vector, $0F mode 0, $83 interrupt enable
//   B: $4A vector, $FF mode 3, $99 direction, $B7 int control, $EF mask
//
// $99 = 1001_1001, and a 1 means *input* on this device, so port B's inputs are
// bits 7, 4, 3 and 0 - PUP, RS232 RX, RS232 CTS and cassette in. Exactly the
// signals that are inputs on the board.
//============================================================================

module z80pio
(
	input             clk,
	input             ce,
	input             reset,

	// CPU interface
	input             cs,        // port group selected
	input       [1:0] addr,      // {port_b, control}
	input             rd,        // read strobe  (one cycle)
	input             wr,        // write strobe (one cycle)
	input       [7:0] din,
	output reg  [7:0] dout,

	// Interrupt / IM2 daisy chain
	input             iei,
	output            ieo,
	output            int_n,
	input             intack,    // interrupt acknowledge (M1 + IORQ)
	input             reti,      // RETI executed - clear the in-service latch
	output reg  [7:0] int_vec,
	output            vec_oe,

	// Peripheral side
	output      [7:0] a_out,
	input       [7:0] a_in,
	output      [7:0] b_out,
	input       [7:0] b_in
);

//--------------------------------------------------------------------------
// Per-port state
//--------------------------------------------------------------------------
// mode: 00 output, 01 input, 10 bidirectional (port A only), 11 bit control
reg  [1:0] mode   [0:1];
reg  [7:0] dir    [0:1];   // mode 3 only, 1 = input
reg  [7:0] odata  [0:1];   // output register
reg  [7:0] vector [0:1];
reg        ie     [0:1];   // interrupt enable
reg        i_and  [0:1];   // 1 = AND, 0 = OR
reg        i_high [0:1];   // 1 = active high
reg  [7:0] imask  [0:1];   // 0 = bit is monitored
reg        exp_dir[0:1];   // next control byte is the direction register
reg  [7:0] exp_msk;        // pending "mask follows" flags, one bit per port
reg  [1:0] ipend;          // interrupt pending
reg  [1:0] isrv;           // interrupt under service
reg  [1:0] cond_r;         // previous interrupt condition, for edge detection

wire [7:0] pin [0:1];
assign pin[0] = a_in;
assign pin[1] = b_in;

// In modes 0/1/2 the whole port is output or input; in mode 3 `dir` decides
// per bit. Reading a port returns the pin value on input bits and the latched
// output register on output bits - which is what ubee512 models as
// `data_in & direction | data_out`.
function [7:0] port_dir(input [1:0] m, input [7:0] d);
	case (m)
		2'b00: port_dir = 8'h00;   // all output
		2'b01: port_dir = 8'hFF;   // all input
		2'b10: port_dir = 8'hFF;   // bidirectional - inputs when read
		2'b11: port_dir = d;       // bit control
	endcase
endfunction

wire [7:0] dir_a = port_dir(mode[0], dir[0]);
wire [7:0] dir_b = port_dir(mode[1], dir[1]);

assign a_out = odata[0];
assign b_out = odata[1];

wire [7:0] rdval [0:1];
assign rdval[0] = (pin[0] & dir_a) | (odata[0] & ~dir_a);
assign rdval[1] = (pin[1] & dir_b) | (odata[1] & ~dir_b);

//--------------------------------------------------------------------------
// Mode 3 interrupt condition
//--------------------------------------------------------------------------
// Monitored bits are those with a 0 in the mask. The port value is compared
// against i_high, and i_and decides whether every monitored bit must match or
// just one. With no bits monitored the condition is never true, which is what
// stops an unprogrammed port from asserting INT.
function match(input [1:0] p, input [7:0] val, input [7:0] msk,
               input hi, input use_and);
	reg [7:0] v, mon;
	begin
		v   = hi ? val : ~val;
		mon = ~msk;
		match = (mon == 0)     ? 1'b0        :
		        use_and        ? ((v & mon) == mon) :
		                         ((v & mon) != 0);
	end
endfunction

wire cond_a = (mode[0] == 2'b11) &&
              match(2'd0, rdval[0], imask[0], i_high[0], i_and[0]);
wire cond_b = (mode[1] == 2'b11) &&
              match(2'd1, rdval[1], imask[1], i_high[1], i_and[1]);
wire [1:0] cond = {cond_b, cond_a};

//--------------------------------------------------------------------------
// Register access
//--------------------------------------------------------------------------
wire       sel_b = addr[1];
wire       sel_c = addr[0];
integer    i;

always @(posedge clk) begin
	if (reset) begin
		for (i = 0; i < 2; i = i + 1) begin
			mode[i]    <= 2'b01;   // input: safe, drives nothing
			dir[i]     <= 8'hFF;
			odata[i]   <= 8'h00;
			vector[i]  <= 8'h00;
			ie[i]      <= 1'b0;
			i_and[i]   <= 1'b0;
			i_high[i]  <= 1'b0;
			imask[i]   <= 8'hFF;   // nothing monitored
			exp_dir[i] <= 1'b0;
		end
		exp_msk <= 8'h00;
		ipend   <= 2'b00;
		isrv    <= 2'b00;
		cond_r  <= 2'b00;
	end
	else begin
		//------------------------------------------------------------------
		// Latch a new interrupt on the RISING EDGE of the condition.
		//
		// The mode-3 condition is a level - "any/all monitored bits high/low" -
		// and the signals behind it are held for a long time: a pull-up is true
		// forever, and vsync is true for a good slice of every frame. Re-arming
		// on the level would fire again the instant the handler returns, so the
		// CPU would spend the whole vblank in its interrupt routine, or in the
		// pull-up case never leave it at all.
		//
		// Edging it gives what the machines actually want: one interrupt per
		// vsync (the 50 Hz tick ROM BASIC models keep time with), and at most
		// one ever from a tied-high bit.
		cond_r <= cond;
		for (i = 0; i < 2; i = i + 1)
			if (ie[i] && cond[i] && !cond_r[i] && !ipend[i] && !isrv[i])
				ipend[i] <= 1'b1;

		//------------------------------------------------------------------
		// Interrupt acknowledge: the highest-priority pending port that its
		// daisy chain lets through goes into service and supplies the vector.
		// Port A outranks port B.
		//------------------------------------------------------------------
		if (intack && iei) begin
			if (ipend[0] && !isrv[0] && !isrv[1]) begin
				ipend[0] <= 1'b0; isrv[0] <= 1'b1;
			end
			else if (ipend[1] && !isrv[0] && !isrv[1]) begin
				ipend[1] <= 1'b0; isrv[1] <= 1'b1;
			end
		end

		// RETI ends the highest-priority service in progress
		if (reti) begin
			if      (isrv[0]) isrv[0] <= 1'b0;
			else if (isrv[1]) isrv[1] <= 1'b0;
		end

		//------------------------------------------------------------------
		// CPU writes
		//------------------------------------------------------------------
		// `wr` MUST be a one-shot strobe, not a level. Several of the control
		// words are sequential - a mode-3 select is followed by the direction
		// register, an interrupt control word by the mask - so writing the same
		// byte twice does not just repeat, it desynchronises the sequence and
		// silently lands the wrong value in the wrong register.
		//
		// (This module is clocked on clk_sys, so it needs strobes. The wd1793
		// next door is the opposite case: it takes a `ce` and edge-detects
		// internally, so it needs levels. See NOTES.md - getting either the
		// wrong way round fails quietly.)
		if (cs && wr) begin
			if (!sel_c) begin
				// data register
				odata[sel_b] <= din;
			end
			else if (exp_dir[sel_b]) begin
				dir[sel_b]     <= din;
				exp_dir[sel_b] <= 1'b0;
			end
			else if (exp_msk[sel_b]) begin
				imask[sel_b]   <= din;
				exp_msk[sel_b] <= 1'b0;
			end
			else if (!din[0]) begin
				// interrupt vector - bit 0 clear identifies it
				vector[sel_b] <= {din[7:1], 1'b0};
			end
			else if (din[3:0] == 4'b1111) begin
				// mode select; mode 3 is followed by the direction register
				mode[sel_b]    <= din[7:6];
				exp_dir[sel_b] <= (din[7:6] == 2'b11);
			end
			else if (din[3:0] == 4'b0111) begin
				// interrupt control word; bit 4 means a mask byte follows
				ie[sel_b]      <= din[7];
				i_and[sel_b]   <= din[6];
				i_high[sel_b]  <= din[5];
				exp_msk[sel_b] <= din[4];
				if (!din[7]) ipend[sel_b] <= 1'b0;
			end
			else if (din[3:0] == 4'b0011) begin
				// interrupt enable/disable only
				ie[sel_b] <= din[7];
				if (!din[7]) ipend[sel_b] <= 1'b0;
			end
		end
	end
end

//--------------------------------------------------------------------------
// CPU reads
//--------------------------------------------------------------------------
// Reading a control port is not meaningful on a real PIO; return $FF rather
// than invent a value.
always @* begin
	if (sel_c) dout = 8'hFF;
	else       dout = rdval[sel_b];
end

//--------------------------------------------------------------------------
// Interrupt outputs
//--------------------------------------------------------------------------
wire any_pend = (ipend[0] | ipend[1]) & iei;

assign int_n  = ~any_pend;
assign ieo    = iei & ~ipend[0] & ~ipend[1] & ~isrv[0] & ~isrv[1];
assign vec_oe = intack & iei & (ipend[0] | ipend[1] | isrv[0] | isrv[1]);

always @* begin
	if      (ipend[0] | isrv[0]) int_vec = vector[0];
	else                         int_vec = vector[1];
end

endmodule
