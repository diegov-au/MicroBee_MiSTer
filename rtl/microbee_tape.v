//============================================================================
// microbee_tape - cassette LOAD. Streams a DGOS .tap image off the SD card and
// generates the Kansas City Standard waveform on PIO port B bit 0.
//
// LOAD only. There is no decoder and nothing writes back - see docs/PLAN.md
// "M8-1 build scope" for why SAVE is a separate milestone.
//
// The file is byte-level, not pulse-level: there is no waveform in a .tap, so
// this module *generates* the modulation and a load therefore takes the real
// amount of time and sounds right. Format established in docs/NOTES.md 15 from
// toptensoftware/tapetool's MachineTypeMicrobee.cpp and cross-checked against
// tools/defender.tap.
//
//   bit 0 = 4 cycles of 1200 Hz     bit 1 = 8 cycles of 2400 Hz   (at 300 baud)
//   framing 0nnnnnnnn11 - start, 8 data bits LSB FIRST, two stop bits
//
// Both bit values take the same time, which is what makes KCS self-clocking.
// At 1200 baud the cycle counts quarter; the two frequencies do not change.
// 300 and 1200 are the only rates this machine has - see the speed byte below.
//
//----------------------------------------------------------------------------
// THE TIMEBASE IS ce, WHICH MUST BE 13.5 MHz
//
// Not clk_sys. The harness runs the core at 13.5 MHz under --fast and 54 MHz
// otherwise, so a divider off clk_sys would need two sets of constants and the
// simulated tape would not be the hardware tape. ce_pix is 13.5 MHz in BOTH
// cases (clk_sys/4 at 54 MHz, clk_sys itself under --fast), so counting it
// gives one set of constants that is exact at both rates:
//
//   1200 Hz cycle = 13500000/1200 = 11250 ticks        exact
//   2400 Hz cycle = 13500000/2400 =  5625 ticks        exact
//   300 baud bit  = 4*11250 = 8*5625 = 45000 ticks     exact
//
// So there is no fractional divider and no accumulated phase error over a
// multi-minute load. The waveform is built by COMPARING against the half cycle
// rather than by toggling, because 5625 is odd - the 2400 Hz half is 2812.5.
// Comparing keeps every full cycle exactly 5625 ticks and puts the 74 ns of
// error into the duty cycle (49.99%), where nothing can see it.
//----------------------------------------------------------------------------
// THE START TRIGGER, WHICH WAS THE ONE REAL UNKNOWN
//
// The MicroBee has no tape motor control - on real hardware *you* pressed PLAY -
// so the software cannot tell us to start and something has to decide.
//
// ubee512 answers it twice, differently. Its WAV path (src/tape.c, called from
// src/pio.c:848) gates on `tape.in_status && tapei[0] && (pio_b.direction &
// PIO_B_CASIN)` and then free-runs: position in the file is a pure function of
// elapsed T-states since the first read. Its .tap path (src/tapfile.c) does not
// model tape at all - it patches the ROM's tape vectors at $8012/$E012 and
// injects bytes. We do neither: we generate a real waveform from a .tap, which
// is what the Spectrum MiSTer cores do with theirs.
//
// The direction-register test does NOT discriminate on this machine - the boot
// ROM writes $99 to port B's direction register, so bit 0 is an input from boot
// (see rtl/z80pio.v). So on ubee512's WAV path the user's Rewind is really what
// starts playback.
//
// MEASURED INSTEAD, on a 32K IC with --piob-log (session 10). Every CPU read of
// port B data over 600 frames, booting and then typing LOAD:
//
//   PC $A767   200 reads, ALL exactly 634 us apart, all during boot
//   PC $BD53   736,404 reads, 10.7 us apart, from the moment LOAD is typed
//
// A 60x separation with nothing in between, so the read *rate* is the trigger:
// eight reads spaced under 100 us apart means the machine is in its tape
// sampling loop. That is ~9x clear of the loop and ~6x clear of the idle poll.
// Rate is also the only trigger that works on every model, which matters
// because a naive "any port B read" would fire at boot on exactly the ROM-BASIC
// machines that need tape most - they take their 50 Hz tick from PB7.
//
// Once started it free-runs to the end of the image, like ubee512's WAV path
// and like a real deck. It never pauses on read inactivity: the ROM stops
// reading between blocks while it checksums, and pausing there would break the
// waveform it is timing.
//============================================================================

`default_nettype none

module microbee_tape
(
	input  wire        clk_sys,
	input  wire        ce,          // 13.5 MHz - see header
	input  wire        reset,

	// Mount, and the block interface behind it
	input  wire        img_mounted,
	input  wire [31:0] img_size,
	output reg  [31:0] sd_lba,
	output reg         sd_rd,
	input  wire        sd_ack,
	input  wire  [8:0] sd_buff_addr,
	input  wire  [7:0] sd_buff_dout,
	input  wire        sd_buff_wr,

	// Controls
	input  wire        rewind,      // one-shot: back to the start, stop playing
	input  wire        pb_rd,       // one-shot: CPU read PIO port B data

	// To the machine
	output wire        cass_in,     // PIO port B bit 0
	output wire        playing,

	// For the harness stop report - proves the tape actually moved
	output reg  [31:0] tape_bytes,
	// Diagnostics: ce ticks the encoder spent wanting a byte the double buffer
	// could not supply, and how many blocks were fetched. A starved tape holds
	// its output level, which the ROM reads as a half-cycle that never ends -
	// so it hangs rather than reporting an error.
	output reg  [31:0] tape_stalls,
	output reg  [31:0] tape_fetches
);

//--------------------------------------------------------------------------
// Double-buffered block window
//--------------------------------------------------------------------------
// 1 KB, two 512-byte halves. Tape is producer-driven - we set the pace - so at
// 1200 baud one half lasts 3.4 seconds and the prefetch has all the time in the
// world. It is double-buffered anyway because the alternative is stalling mid
// waveform for the SD latency, and the ROM is timing that waveform.
//
// The read port is REGISTERED, both so Quartus infers block RAM rather than
// 8192 flops and because an asynchronous read of an array this size is the kind
// of thing that fits in simulation and not on the device. Safe here: the
// pointer only moves once per byte, which is milliseconds apart.
reg [7:0] tbuf [0:1023];

reg        fill_half  /* verilator public_flat_rd */ = 1'b0;
reg        play_half  /* verilator public_flat_rd */ = 1'b0;
reg  [1:0] half_valid /* verilator public_flat_rd */ = 2'b00;
reg  [8:0] play_ptr   = 9'd0;
reg [31:0] byte_pos   /* verilator public_flat_rd */ = 32'd0;  // file pos of play_ptr
reg [31:0] blocks_total /* verilator public_flat_rd */ = 32'd0;
reg [31:0] next_lba   /* verilator public_flat_rd */ = 32'd0;
reg [31:0] tape_size  = 32'd0;
reg        mounted    /* verilator public_flat_rd */ = 1'b0;
reg        rew_req    /* verilator public_flat_rd */ = 1'b0;

always @(posedge clk_sys) if (sd_buff_wr & sd_ack)
	tbuf[{fill_half, sd_buff_addr}] <= sd_buff_dout;

reg [7:0] buf_byte;
always @(posedge clk_sys) buf_byte <= tbuf[{play_half, play_ptr}];

// One ce tick of settle after the read pointer moves, because the read above is
// registered and buf_byte is therefore one clock behind the pointer.
//
// It never matters while framing - consumes are milliseconds apart - but the
// container signature is skipped rather than modulated, so those bytes are taken
// on CONSECUTIVE ce ticks and the stale value is read. Under --fast, where ce is
// every clock, that skips one byte more than at 54 MHz, where ce is one clock in
// four and the lag is absorbed. The two rates must agree exactly: the whole point
// of counting ce is that simulation and hardware behave identically.
reg fetch_hold = 1'b0;

// sd_rd is a REQUEST PULSE and must be dropped on the ack RISE, not on the
// fall. Both hps_io and SimBlockDevice take a still-high sd_rd as a fresh
// request the moment the previous transfer retires, so clearing it late issues
// the same block twice - and the second copy lands in the half the first one
// just advanced into. wd1793.sv does the same thing (`ack[5:4] == 'b01`); this
// is the mistake that costs an afternoon if it is not copied from there.
// The fall is what says the data has all arrived.
reg [2:0] ackr = 3'd0;
reg       sd_busy /* verilator public_flat_rd */ = 1'b0;
wire      ack_rise = (ackr[2:1] == 2'b01);
wire      ack_fall = (ackr[2:1] == 2'b10);

//--------------------------------------------------------------------------
// Encoder state
//--------------------------------------------------------------------------
localparam [13:0] CYC_1200 = 14'd11250;   // one cycle of 1200 Hz, in ce ticks
localparam [13:0] CYC_2400 = 14'd5625;    // one cycle of 2400 Hz

// Byte-level parse. The header's speed byte sets the baud rate for the data
// blocks that follow it, so the stream cannot be framed blindly - a 1200-baud
// tape played at 300 is noise, and tools/defender.tap is speed=$FF, i.e. 1200.
// tapetool switches after rendering the header AND its checksum byte, so the
// switch belongs there and not a byte earlier.
localparam [2:0] S_MAGIC  = 3'd0;   // container signature, not tape data
localparam [2:0] S_LEADER = 3'd1;   // run of zeros, terminated by $01
localparam [2:0] S_HEADER = 3'd2;   // 16-byte DGOS header + 1 checksum byte
localparam [2:0] S_DATA   = 3'd3;   // datalen bytes in blocks of <=256, +1 CRC
localparam [2:0] S_DONE   = 3'd4;

reg  [2:0] state      /* verilator public_flat_rd */ = S_MAGIC;
reg  [4:0] hdr_cnt    = 5'd0;
reg [16:0] data_left  /* verilator public_flat_rd */ = 17'd0;  // data bytes still owed
reg  [8:0] blk_left   = 9'd0;    // bytes left in this block before its checksum
reg  [1:0] speed      /* verilator public_flat_rd */ = 2'd0;   // shift: 0 = 300 baud, 2 = 1200
reg  [1:0] speed_next = 2'd0;
// The rate the byte CURRENTLY being framed is going out at, latched when that
// byte is fetched. `speed` alone is not enough: it changes at the header's last
// byte, and a bit-by-bit reload that read it directly sent that byte's start bit
// at 300 baud and its remaining ten bits at the new rate. The machine then read
// a corrupt header checksum and answered "Bad load" - which looks exactly like a
// broken 1200-baud encoder, and is not.
reg  [1:0] bit_speed  = 2'd0;

reg [10:0] frame       = 11'd0;  // {stop, stop, byte[7:0], start}
reg  [3:0] bits_left   = 4'd0;
reg  [3:0] cycles_left = 4'd0;
reg [13:0] cyc_cnt     = 14'd0;
reg [13:0] cyc_len     = CYC_1200;
reg        running     = 1'b0;

// Is this byte part of the container signature rather than tape data? The
// signature is "TAP_DGOS_MBEE" terminated by a NUL - matched the way ubee512
// matches it, up to the NUL, so the "MBEE..." variant works too. A file that
// starts with neither letter is taken to be raw tape data from byte 0.
wire magic_byte = (state == S_MAGIC) &&
                  !((byte_pos == 32'd0) && (buf_byte != 8'h54) && (buf_byte != 8'h4D));

assign cass_in = running & (cyc_cnt < {1'b0, cyc_len[13:1]});
assign playing = running;

//--------------------------------------------------------------------------
// Start trigger - eight port B data reads under 100 us apart
//--------------------------------------------------------------------------
localparam [11:0] GAP_MAX = 12'd1350;   // 100 us at 13.5 MHz
localparam  [3:0] BURST_N = 4'd8;

reg [11:0] gap_timer = 12'd0;
reg  [3:0] burst     = 4'd0;

//--------------------------------------------------------------------------
always @(posedge clk_sys) begin
	ackr <= {ackr[1:0], sd_ack};

	//----------------------------------------------------------------------
	// Mount. img_size is valid at the img_mounted pulse; a size of zero is an
	// unmount, which stops the tape rather than playing an empty file.
	//----------------------------------------------------------------------
	if (img_mounted) begin
		tape_size    <= img_size;
		blocks_total <= (img_size + 32'd511) >> 9;
		mounted      <= |img_size;
		half_valid   <= 2'b00;
		fill_half    <= 1'b0;
		play_half    <= 1'b0;
		play_ptr     <= 9'd0;
		byte_pos     <= 32'd0;
		next_lba     <= 32'd0;
		running      <= 1'b0;
		burst        <= 4'd0;
		gap_timer    <= 12'd0;
		state        <= S_MAGIC;
		speed        <= 2'd0;
		bits_left    <= 4'd0;
		fetch_hold   <= 1'b0;
		rew_req      <= 1'b0;
		tape_bytes   <= 32'd0;
		tape_stalls  <= 32'd0;
		tape_fetches <= 32'd0;
	end
	else begin
		// A machine reset is not an eject: the mount survives, the transport
		// goes back to the start. Same handling as a rewind, so it goes through
		// the same request latch and cannot abandon a block transfer in flight.
		if (reset | rewind) rew_req <= 1'b1;

		//------------------------------------------------------------------
		// Block prefetch
		//------------------------------------------------------------------
		if (ack_rise) sd_rd <= 1'b0;

		if (sd_busy) begin
			if (ack_fall) begin
				sd_busy               <= 1'b0;
				tape_fetches          <= tape_fetches + 32'd1;
				half_valid[fill_half] <= 1'b1;
				fill_half             <= ~fill_half;
				next_lba              <= next_lba + 32'd1;
			end
		end
		else if (rew_req) begin
			// Applied only with no transfer outstanding, so a completing block
			// cannot land in a buffer that has just been rewound out from
			// under it.
			rew_req    <= 1'b0;
			half_valid <= 2'b00;
			fill_half  <= 1'b0;
			play_half  <= 1'b0;
			play_ptr   <= 9'd0;
			byte_pos   <= 32'd0;
			next_lba   <= 32'd0;
			running    <= 1'b0;
			burst      <= 4'd0;
			gap_timer  <= 12'd0;
			state      <= S_MAGIC;
			speed      <= 2'd0;
			bits_left  <= 4'd0;
			fetch_hold <= 1'b0;
		end
		else if (mounted && !half_valid[fill_half] && (next_lba < blocks_total)) begin
			sd_lba  <= next_lba;
			sd_rd   <= 1'b1;
			sd_busy <= 1'b1;
		end

		//------------------------------------------------------------------
		// Start trigger. Counted in ce ticks, so it is a rate in emulated time
		// and is identical at both master clock rates.
		//------------------------------------------------------------------
		if (ce && gap_timer != 12'd0) gap_timer <= gap_timer - 12'd1;

		if (pb_rd) begin
			if (gap_timer != 12'd0) begin
				if (burst < BURST_N) burst <= burst + 4'd1;
			end
			else burst <= 4'd0;
			gap_timer <= GAP_MAX;
		end

		if (!running && mounted && !rew_req && (state != S_DONE) && (burst >= BURST_N))
			running <= 1'b1;

		//------------------------------------------------------------------
		// Waveform: one cycle of the current tone per cyc_cnt wrap, then the
		// next bit, then the next byte.
		//------------------------------------------------------------------
		if (ce && running) begin
			if (bits_left != 4'd0 && cycles_left != 4'd0) begin
				if (cyc_cnt >= cyc_len - 14'd1) begin
					cyc_cnt     <= 14'd0;
					cycles_left <= cycles_left - 4'd1;
				end
				else cyc_cnt <= cyc_cnt + 14'd1;
			end

			// Bit finished. Only load another if one is owed - loading on the
			// last would emit a twelfth bit per byte.
			if (bits_left != 4'd0 && cycles_left == 4'd0) begin
				bits_left <= bits_left - 4'd1;
				if (bits_left > 4'd1) begin
					frame       <= {1'b1, frame[10:1]};
					cyc_len     <= frame[1] ? CYC_2400 : CYC_1200;
					cycles_left <= frame[1] ? (4'd8 >> bit_speed) : (4'd4 >> bit_speed);
					cyc_cnt     <= 14'd0;
				end
			end

			//--------------------------------------------------------------
			// Byte finished - fetch and frame the next one.
			//--------------------------------------------------------------
			if (fetch_hold) fetch_hold <= 1'b0;
			else if (bits_left == 4'd0) begin
				if (byte_pos >= tape_size) begin
					state   <= S_DONE;
					running <= 1'b0;
				end
				else if (!half_valid[play_half]) begin
					// Starved: the half we need has not arrived. Counted rather
					// than hidden - a starved tape holds its output level, and
					// the ROM reads that as a half-cycle that never ends, so it
					// hangs instead of reporting an error.
					tape_stalls <= tape_stalls + 32'd1;
				end
				else begin
					fetch_hold <= 1'b1;
					// Advance the read pointer. A half is released the moment
					// its last byte is taken, which is what lets the prefetch
					// run a whole block ahead.
					play_ptr <= play_ptr + 9'd1;
					byte_pos <= byte_pos + 32'd1;
					if (play_ptr == 9'd511) begin
						half_valid[play_half] <= 1'b0;
						play_half             <= ~play_half;
					end

					case (state)
						S_MAGIC: if (!magic_byte || (buf_byte == 8'h00))
							state <= S_LEADER;

						S_LEADER: if (buf_byte == 8'h01) begin
							state   <= S_HEADER;
							hdr_cnt <= 5'd0;
						end

						S_HEADER: begin
							hdr_cnt <= hdr_cnt + 5'd1;
							if (hdr_cnt == 5'd7)  data_left[7:0]  <= buf_byte;
							if (hdr_cnt == 5'd8)  data_left[16:8] <= {1'b0, buf_byte};
							// Header byte 13 is the speed of the DATA, not of
							// the header, and on this machine it is a BOOLEAN:
							// zero means 300 baud, anything else means 1200.
							//
							// tapetool also defines 2 = 600 baud, and its own
							// comment calls that undocumented. The ROM settles
							// it - $A9E9 is `LD A,($00FE) / OR A / JR Z /
							// LD A,1 / LD ($00E9),A`, one branch and no 600
							// case - and the ROM is the machine, so it wins
							// over the tool. Implementing 600 would only
							// produce tapes this hardware decodes as 1200 and
							// therefore reads as noise; measured, session 10.
							if (hdr_cnt == 5'd13)
								speed_next <= (buf_byte == 8'd0) ? 2'd0 : 2'd2;
							// 16 header bytes then one checksum byte, all still
							// at 300 baud; only then does the new speed apply.
							if (hdr_cnt == 5'd16) begin
								state    <= S_DATA;
								speed    <= speed_next;
								blk_left <= (data_left > 17'd256) ? 9'd256
								                                  : data_left[8:0];
							end
						end

						// datalen bytes in blocks of up to 256, each block
						// followed by one checksum byte.
						S_DATA: begin
							if (blk_left != 9'd0) begin
								blk_left  <= blk_left - 9'd1;
								data_left <= data_left - 17'd1;
							end
							else if (data_left == 17'd0) begin
								// This program is done; anything after it is
								// the next one's leader, back at 300 baud.
								state <= S_LEADER;
								speed <= 2'd0;
							end
							else blk_left <= (data_left > 17'd256) ? 9'd256
							                                       : data_left[8:0];
						end

						default: ;
					endcase

					// Frame it: start bit, 8 data bits LSB first, two stop bits.
					// Signature bytes are consumed without being modulated -
					// the magic is container, not tape.
					if (!magic_byte) begin
						frame       <= {2'b11, buf_byte, 1'b0};
						cyc_len     <= CYC_1200;               // the start bit
						cycles_left <= (4'd4 >> speed);
						bit_speed   <= speed;   // whole byte at one rate
						bits_left   <= 4'd11;
						cyc_cnt     <= 14'd0;
						tape_bytes  <= tape_bytes + 32'd1;
					end
				end
			end
		end
	end
end

endmodule

`default_nettype wire
