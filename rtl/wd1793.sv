// Vendored from MiSTer-devel/Specialist_MiSTer/rtl/wd1793.sv (GPL-2).
// Only change: wd1793_dpram reimplemented as inferred RAM so Verilator can
// simulate it - see the note at the bottom of this file.
`default_nettype none

// ====================================================================
//
//  WD1793, WD1772, WD1773 replica (with write capability)
//
//  Copyright (C) 2007,2008 Viacheslav Slavinsky
//  Copyright (C) 2016 Sorgelig
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module wd1793 #(parameter RWMODE=0, EDSK=1)
(
	input        clk_sys,     // sys clock
	input        ce,          // ce at CPU clock rate
	input        reset,	     // async reset
	input        io_en,
	input        rd,          // i/o read
	input        wr,          // i/o write
	input  [1:0] addr,        // i/o port addr
	input  [7:0] din,         // i/o data in
	output [7:0] dout,        // i/o data out
	output       drq,         // DMA request
	output       intrq,
	output       busy,

	input        wp,          // write protect

	input  [2:0] size_code,
	input        layout,      // 0 = Track-Side-Sector, 1 - Side-Track-Sector
	input        side,
	input        ready,

	// SD access (RWMODE == 1)
	input        img_mounted, // signaling that new image has been mounted
	input [31:0] img_size,    // size of image in bytes
	output       prepare,
	output[31:0] sd_lba,
	output reg   sd_rd,
	output reg   sd_wr,
	input        sd_ack,
	input  [8:0] sd_buff_addr,
	input  [7:0] sd_buff_dout,
	output [7:0] sd_buff_din,
	input        sd_buff_wr,

	// RAM access (RWMODE == 0)
	input        input_active,
	input [19:0] input_addr,
	input  [7:0] input_data,
	input        input_wr,
	output[19:0] buff_addr,	  // buffer RAM address
	output       buff_read,	  // buffer RAM read enable
	input  [7:0] buff_din     // buffer RAM data input
);

// Possible track configs:
// 0: 26 x 128  = 3.3KB
// 1: 16 x 256  = 4.0KB
// 2:  9 x 512  = 4.5KB
// 3:  5 x 1024 = 5.0KB
// 4: 10 x 512  = 5.0KB

assign dout      = q;
assign drq       = s_drq;
assign busy      = s_busy;
assign intrq     = s_intrq;
assign sd_lba    = scan_active ? scan_addr[19:9] : buff_a[19:9] + sd_block;
assign prepare   = EDSK ? scan_active : img_mounted;
assign buff_addr = {buff_a[19:9], 9'd0} + byte_addr;
assign buff_read = ((addr == A_DATA) && buff_rd);

reg   [7:0] sectors_per_track, edsk_spt = 0;
reg         buff_wr;
reg   [7:0] spt_addr;
wire [10:0] sector_size = 11'd128 << wd_size_code;
reg  [10:0] byte_addr;
reg  [19:0] buff_a;
reg   [1:0] wd_size_code;

wire  [7:0] buff_dout;
reg   [1:0] sd_block = 0;
reg         format;
generate
	if(RWMODE) begin
		wd1793_dpram sbuf
		(
			.clock(clk_sys),

			.address_a({sd_block, sd_buff_addr}),
			.data_a(sd_buff_dout),
			.wren_a(sd_buff_wr & sd_ack),
			.q_a(sd_buff_din),

			.address_b(scan_active ? {2'b00, scan_addr[8:0]} : byte_addr),
			.data_b(format ? 8'd0 : din),
			.wren_b(wre & buff_wr & (addr == A_DATA) & ~scan_active),
			.q_b(buff_dout)
		);
		// buff_wr and spt_addr are declared at module scope below instead of
		// inside these generate blocks: they are assigned from outside the
		// generate, which Verilator rejects under `default_nettype none.
	end else begin
		assign buff_dout   = 0;
		assign sd_buff_din = 0;
	end
endgenerate

reg         var_size /* verilator public_flat_rd */ = 0;
reg  [19:0] disk_size;
reg         layout_r;
wire [19:0] hs  = (layout_r & side) ? disk_size >> 1 : 20'd0;
wire  [7:0] dts = {disk_track[6:0], side} >> layout_r;

// DS80 sector numbering - the one format whose sector IDs are not positions.
//
// On a DS80 image the reserved system cylinders number their sectors from 1 and
// every data cylinder from 2 on numbers from 21 (ubee512 disk.c:759). The
// arithmetic path below derives the LBA from track/side/sector, so without this
// it would map data tracks 20 sectors low.
//
// The boundary counts CYLINDERS, not tracks: two cylinders on a two-headed disk
// is the "4 reserved system tracks" the ubee512 changelog describes, and
// disk_track is the cylinder ("real heads position"). Confirmed against real
// hardware images in session 8 - arcade.dsk and wordstar.dsk both carry 1..10 on
// cylinders 0-1 and 21..30 from cylinder 2, on both sides. See NOTES 2.
//
// 819,200 bytes is unique among the raw formats we accept, so it identifies
// itself; ss80 and ds40 are both 409,600. Gated on ~var_size because a .dsk
// container carries real sector IDs in its track headers and takes the scanner
// path instead - which is why arcade.dsk has always worked. sectors_per_track is
// shared between the two paths, so every use of it below had to become
// base-relative rather than assuming 1.
wire        ds80    = ~var_size & (disk_size == 20'd819200);
wire  [7:0] secbase = (ds80 & (disk_track >= 8'd2)) ? 8'd21 : 8'd1;
wire  [7:0] sectop  = secbase + sectors_per_track - 8'd1;
always @* begin
	case({var_size,size_code})
				0: buff_a = hs + {{1'b0, dts, 4'b0000} + {dts, 3'b000} + {dts, 1'b0} + wdreg_sector - 1'd1,  7'd0};
				1: buff_a = hs + {{dts, 4'b0000}                                     + wdreg_sector - 1'd1,  8'd0};
				2: buff_a = hs + {{dts, 3'b000}  + dts                               + wdreg_sector - 1'd1,  9'd0};
				3: buff_a = hs + {{dts, 2'b00}   + dts                               + wdreg_sector - 1'd1, 10'd0};
			// secbase, not 1: this is the 10x512 case, and DS80 is the only raw
			// format that lands here with sector IDs based anywhere but 1. For
			// ss80 secbase is 1 and this is the expression it replaces.
				4: buff_a = hs + {{dts, 3'b000}  +{dts, 1'b0}                        + wdreg_sector - secbase,  9'd0};
		default: buff_a = edsk_offset;
	endcase
	case({var_size,size_code})
				0: sectors_per_track = 26;
				1: sectors_per_track = 16;
				2: sectors_per_track = 9;
				3: sectors_per_track = 5;
				4: sectors_per_track = 10;
		default: sectors_per_track = edsk_spt;
	endcase
	case({var_size,size_code})
				0: wd_size_code = 0;
				1: wd_size_code = 1;
				2: wd_size_code = 2;
				3: wd_size_code = 3;
				4: wd_size_code = 2;
		default: wd_size_code = edsk_sizecode;
	endcase
end

reg   [1:0] blk_size;
always @* begin
	case(wd_size_code)
		0: blk_size = 0;
		1: blk_size = 0;
		2: blk_size = buff_a[8:0] ? 2'd1 : 2'd0;
		3: blk_size = buff_a[8:0] ? 2'd2 : 2'd1;
	endcase
end


// Register addresses
localparam A_COMMAND         = 0;
localparam A_STATUS          = 0;
localparam A_TRACK           = 1;
localparam A_SECTOR          = 2;
localparam A_DATA            = 3;

// States
typedef enum 
{
	STATE_IDLE,

	STATE_SEARCH,
	STATE_SEARCH_1,

	STATE_WAIT_READ,
	STATE_WAIT_READ_1,
	STATE_WAIT_READ_2,

	STATE_READ,
	STATE_READ_1,
	STATE_READ_2,
	STATE_READ_3,

	STATE_WAIT_WRITE,
	STATE_WAIT_WRITE_1,
	STATE_WAIT_WRITE_2,

	STATE_WRITE,
	STATE_WRITE_1,
	STATE_WRITE_2,

	STATE_ABORT,
	STATE_WAIT,
	STATE_WAIT_2,
	STATE_ENDCOMMAND
} io_state_t;


// common status bits
wire        s_readonly = (wp | !RWMODE);
reg			s_crcerr;
reg			s_headloaded, s_seekerr, s_index;  // mode 1
reg			s_lostdata, s_wrfault; 			     // mode 2,3

// Command mode 0/1 for status register
reg 			cmd_mode;

// DRQ/BUSY are always going together
reg	[1:0]	s_drq_busy;
wire			s_drq  = s_drq_busy[1];
wire			s_busy = s_drq_busy[0];
reg         s_intrq;

reg   [7:0] wdreg_track;
reg   [7:0] wdreg_sector;
reg   [7:0] wdreg_data;
wire  [7:0] wdreg_status = cmd_mode == 0 ?
	{~ready, s_readonly, s_headloaded, s_seekerr | ~ready, s_crcerr, !disk_track, s_index, s_busy}:
	{~ready, s_readonly, s_wrfault,    s_seekerr | ~ready, s_crcerr, s_lostdata,  s_drq,   s_busy};

reg   [7:0] read_addr[6];
reg   [7:0] q;
always @* begin
	case (addr)
		A_STATUS: q = wdreg_status;
		A_TRACK:  q = wdreg_track;
		A_SECTOR: q = wdreg_sector;
		A_DATA:   q = (state == STATE_IDLE) ? wdreg_data : buff_rd ? (RWMODE ? buff_dout : buff_din) : read_addr[byte_addr[2:0]];
	endcase
end

reg         buff_rd;
reg         step_direction; // last step direction

reg   [7:0] disk_track;		 // "real" heads position
reg  [10:0]	data_length;	 // this many bytes to transfer during read/write ops
io_state_t  state = STATE_IDLE;

// Reusable expressions
wire  [7:0] next_track  = (din[6] ? din[5] : step_direction) ? disk_track - 1'd1 : disk_track + 1'd1;
wire [10:0]	next_length = data_length - 1'b1;

// Watchdog
reg         watchdog_set;
wire        watchdog_bark = (wd_timer == 0);
reg  [15:0] wd_timer;
always @(posedge clk_sys) begin
	if(ce) begin
		if(watchdog_set) wd_timer <= 4096;
			else if(wd_timer != 0) wd_timer <= wd_timer - 1'b1;
	end
end

always @(posedge clk_sys) begin
	integer cnt;
	if(ce) begin
		if(ready) begin
			if(cnt) cnt <= cnt - 1;
				else cnt <= 35000;
		end else cnt <= 0;
		s_index <= (cnt < 100);
	end
end

wire        rde = rd & io_en;
wire        wre = wr & io_en;
always @(posedge clk_sys) begin
	reg old_wr, old_rd;

	reg [2:0] cur_addr;
	reg       read_data;
	reg       write_data;
	reg       rw_type;
	integer   wait_time;
	reg [3:0] read_timer;
	reg [9:0] seektimer;
	reg [7:0] ra_sector;
	// The ID actually under the head, ra_sector clamped into THIS track's
	// numbering. See the READ ADDRESS handler for why free-running is not
	// enough (BUG-012).
	reg [7:0] ra_now;
	reg       multisector;
	reg       write;
	reg [5:0] ack;
	reg       sd_busy;
	reg       old_mounted;
	reg [3:0] scan_state;
	reg [1:0] scan_cnt;
	reg [1:0] blk_max;

	if(RWMODE) begin
		old_mounted <= img_mounted;
		if(old_mounted && ~img_mounted) begin
			if(EDSK) begin
				scan_active<= 1;
				scan_addr  <= 0;
				scan_state <= 0;
				scan_wr    <= 0;
				sd_block   <= 0;
			end
			disk_size <= img_size[19:0];
			layout_r  <= layout;
		end
	end else begin
		scan_active <= input_active;
		scan_addr   <= input_addr;
		scan_wr     <= input_wr;
		if(scan_active & ~input_active) begin
			disk_size <= input_addr + 1'd1;
			layout_r  <= layout;
		end
	end

	if(reset & ~scan_active) begin
		read_data <= 0;
		write_data <= 0;
		multisector <= 0;
		step_direction <= 0;
		disk_track <= 0;
		wdreg_track <= 0;
		wdreg_sector <= 0;
		wdreg_data <= 0;
		data_length <= 0;
		byte_addr <=0;
		buff_rd <= 0;
		if(RWMODE) buff_wr <= 0;
		state <= STATE_IDLE;
		cmd_mode <= 0;
		{s_headloaded, s_seekerr, s_crcerr, s_intrq} <= 0;
		{s_wrfault, s_lostdata} <= 0;
		s_drq_busy <= 0;
		watchdog_set <= 0;
		seektimer <= 'h3FF;
		{ack, sd_wr, sd_rd, sd_busy} <= 0;
		ra_sector <= 1;
	end else if(ce) begin

		ack <= {ack[4:0], sd_ack};
		if(ack[5:4] == 'b01) {sd_rd,sd_wr} <= 0;
		if(ack[5:4] == 'b10) sd_busy <= 0;

		if(RWMODE & scan_active) begin
			if(scan_addr >= img_size) scan_active <= 0;
			else begin
				case(scan_state)
					0:	begin
							sd_rd   <= 1;
							sd_busy <= 1;
							scan_wr <= 0;
							scan_state <= 1;
						end
					1: if(!sd_busy) begin
							scan_wr    <= 1;
							scan_cnt   <= 1;
							scan_state <= 2;
						end
					2: begin
							scan_cnt <= scan_cnt + 1'd1;
							if(!scan_cnt) begin
								scan_wr <= ~scan_wr;
								if(scan_wr) begin
									scan_addr <= scan_addr + 1'b1;
									if(&scan_addr[8:0]) begin
										scan_active <= var_size;
										scan_state  <= 0;
									end
								end
							end
						end
				endcase
			end
		end

		old_wr <=wre;
		old_rd <=rde;

		if((!old_rd && rde) || (!old_wr && wre)) cur_addr <= addr;

		//Register read operations
		if(old_rd && !rde && (cur_addr == A_STATUS)) s_intrq <= 0;

		//end of data reading
		if(old_rd && !rde && (cur_addr == A_DATA)) read_data <=1;

		//end of data writing
		if(old_wr && !wre && (cur_addr == A_DATA)) write_data <=1;

		case (state)
			/* Idle state or buffer to host transfer */
			STATE_IDLE:; // do nothing

			STATE_SEARCH:
				begin
					if(!ready) begin
						s_seekerr <= 1;
						state <= STATE_ENDCOMMAND;
					end else begin
						seektimer <= seektimer - 1'b1;
						if(!seektimer) begin
							byte_addr <= 0;
							if(var_size) begin
								if(~format) edsk_addr <= edsk_start;
								spt_addr  <= (side ? spt_size>>1 : 8'd0) + disk_track;
								state     <= STATE_SEARCH_1;
							end else begin
								// The sector-range check applies to READ/WRITE SECTOR
								// only. READ ADDRESS (rw_type == 0) has already
								// synthesised its ID field from the fixed geometry in
								// the command decode, and must not be rejected for the
								// sector register still being 0 - the MicroBee BIOS
								// issues READ ADDRESS to identify the disk *before* it
								// ever writes a sector number.
								// Base-relative. With secbase 1 this is the original
								// `!wdreg_sector || > sectors_per_track`; on a DS80 data
								// track the valid range is 21..30, and the old form would
								// have rejected every one of them.
								if(rw_type && ((wdreg_sector < secbase) || (wdreg_sector > sectop))) begin
									if(~format) s_seekerr <= 1;
									state <= STATE_ENDCOMMAND;
								end else begin
									state <= rw_type ? STATE_WAIT_READ : STATE_READ;
								end
							end
						end
					end
				end
			STATE_SEARCH_1:
				begin
					if(rw_type & (edsk_track == disk_track) &
									 (edsk_side == side) &
									 (format | (edsk_sector == wdreg_sector))) begin
						state <= STATE_WAIT_READ;
					end
					else
					if(~rw_type & (edsk_track == disk_track) &
									  (edsk_side == side)) begin
						read_addr[0] <= edsk_trackf;
						read_addr[1] <= edsk_sidef;
						read_addr[2] <= edsk_sector;
						read_addr[3] <= edsk_sizecode;
						state        <= STATE_READ;
					end
					else
					if(edsk_next == edsk_start) begin
						if(~format) s_seekerr <= 1;
						state <= STATE_ENDCOMMAND;
					end
					else
					begin
						edsk_addr <= edsk_next;
					end
				end
			// read before write in case if sector not aligned or smaller than 512b
			STATE_WAIT_READ:
				begin
					data_length <= sector_size;
					byte_addr   <= buff_a[8:0];
					blk_max     <= blk_size;
					sd_block    <= 0;
					state       <= RWMODE ? STATE_WAIT_READ_1 : write ? STATE_WRITE : STATE_READ;
				end
			STATE_WAIT_READ_1:
				begin
					sd_busy <= 1;
					sd_rd   <= 1;
					state   <= STATE_WAIT_READ_2;
				end
			STATE_WAIT_READ_2:
				begin
					if(!sd_busy) begin
						sd_block <= sd_block + 1'd1;
						state <= write ? STATE_WRITE : STATE_READ;
						if(sd_block < blk_max) state <= STATE_WAIT_READ_1;
					end
				end

			STATE_READ:
				begin
					watchdog_set <= 1;
					read_timer <= 15;
					state <= STATE_READ_1;
				end
			STATE_READ_1:
				begin
					read_timer <= read_timer - 1'b1;
					if(!read_timer) begin
						read_data <= 0;
						watchdog_set <= 0;
						s_lostdata <= 0;
						s_drq_busy <= 2'b11;
						state <= STATE_READ_2;
					end
				end
			STATE_READ_2:
				begin
					if(watchdog_bark | (read_data & s_drq)) begin
						// reset drq until next byte is read, nothing is lost
						s_drq_busy <= 2'b01;
						s_lostdata <= watchdog_bark;

						if(next_length == 0) begin
							// either read the next sector, or stop if this is track end
							if(multisector) begin
								wdreg_sector <= wdreg_sector + 1'b1;
								state <= STATE_SEARCH;
							end else begin
								state <= STATE_ENDCOMMAND;
							end
						end else begin
							byte_addr <= byte_addr + 1'd1;
							data_length <= next_length;
							state <= STATE_READ;
						end
					end
				end

			STATE_WAIT_WRITE:
				begin
					if(!ready) begin
						s_wrfault <= 1;
						state <= STATE_ENDCOMMAND;
					end else begin
						sd_block <= 0;
						state <= STATE_WAIT_WRITE_1;
					end
				end
			STATE_WAIT_WRITE_1:
				begin
					sd_busy <= 1;
					sd_wr   <= 1;
					state   <= STATE_WAIT_WRITE_2;
				end
			STATE_WAIT_WRITE_2:
				begin
					if(!sd_busy) begin
						sd_block <= sd_block + 1'd1;
						if(sd_block < blk_max) state <= STATE_WAIT_WRITE_1;
						else begin
							if(format && var_size && !edsk_next) begin
								state <= STATE_ENDCOMMAND;
							end else if(multisector) begin
								edsk_addr <= edsk_next;
								wdreg_sector <= wdreg_sector + 1'b1;
								state <= STATE_SEARCH;
							end else begin
								state <= STATE_ENDCOMMAND;
							end
						end
					end
				end
			STATE_WRITE:
				begin
					watchdog_set <= 1;
					read_timer <= 15;
					state <= STATE_WRITE_1;
				end
			STATE_WRITE_1:
				begin
					read_timer <= read_timer - 1'b1;
					if(!read_timer) begin
						write_data <= 0;
						watchdog_set <= 0;
						s_lostdata <= 0;
						s_drq_busy <= 2'b11;
						state <= STATE_WRITE_2;
					end
				end
			STATE_WRITE_2:
				begin
					if(watchdog_bark | (write_data & s_drq)) begin
						s_drq_busy <= 2'b01;
						s_lostdata <= watchdog_bark;

						if(!next_length) state <= STATE_WAIT_WRITE;
						else begin
							byte_addr <= byte_addr + 1'd1;
							data_length <= next_length;
							state <= STATE_WRITE;
						end
					end
				end

			// Abort current operation ($D0)
			STATE_ABORT:
				begin
					data_length <= 0;
					{s_wrfault,s_seekerr,s_crcerr,s_lostdata} <= 0;
					state <= STATE_ENDCOMMAND;
				end

			STATE_WAIT:
				begin
					wait_time <= 4000;
					state <= STATE_WAIT_2;
				end
			STATE_WAIT_2:
				begin
					if(wait_time) wait_time <= wait_time - 1;
						else state <= STATE_ENDCOMMAND;
				end

			// End any command.
			STATE_ENDCOMMAND:
				begin
					format  <= 0;
					buff_rd <= 0;
					if(RWMODE) buff_wr <=0;
					state <= STATE_IDLE;
					s_drq_busy <= 2'b00;
					seektimer <= 'h3FF;
					s_intrq <= 1;
				end
		endcase

		/* Register write operations */
		if (!old_wr & wre) begin
			case (addr)
				A_COMMAND:
					begin
						s_intrq <= 0;
						if((state == STATE_IDLE) | (din[7:4] == 'hD)) begin
							cmd_mode <= din[7];
							case (din[7:4])
							'h0: 	// RESTORE
								begin
									// head load as specified, index, track0
									s_headloaded <= din[3];
									wdreg_track <= 0;
									disk_track <= 0;

									// some programs like it when FDC gets busy for a while
									s_drq_busy <= 2'b01;
									state <= STATE_WAIT;
								end
							'h1:	// SEEK
								begin
									// set real track to datareg
									disk_track <= wdreg_data;
									// ...and the TRACK REGISTER with it. The WD179x
									// datasheet has SEEK update the track register to
									// the sought track, and ubee512 does the same
									// (src/fdc.c FDC_SEEK: `ctrl_rtrack = ctrl_rdata`,
									// which is what fdc_track_r returns). Upstream
									// left it stale.
									//
									// This matters because the MicroBee BIOS gates its
									// seeks on that register - $EE0D reads it, compares
									// against the wanted track and skips the seek when
									// they match. With a stale register the BIOS can
									// believe the head is already in place and read a
									// completely different track, which is what broke
									// DIR: every read stayed on the boot tracks and
									// CP/M was handed data instead of directory
									// entries.
									wdreg_track  <= wdreg_data;
									s_headloaded <= din[3];

									// get busy
									s_drq_busy <= 2'b01;
									state <= STATE_WAIT;
								end
							'h2,	// STEP
							'h3,	// STEP & UPDATE
							'h4,	// STEP-IN
							'h5,	// STEP-IN & UPDATE
							'h6,	// STEP-OUT
							'h7:	// STEP-OUT & UPDATE
								begin
									// if direction is specified, store it for the next time
									if (din[6] == 1) step_direction <= din[5]; // 0: forward/in

									// perform step
									disk_track <= next_track;

									// update TRACK register too if asked to
									if (din[4]) wdreg_track <= next_track;

									s_headloaded <= din[3];

									// some programs like it when FDC gets busy for a while
									s_drq_busy <= 2'b01;
									state <= STATE_WAIT;
								end
							'h8, 'h9, // READ SECTORS
							'hA, 'hB, // WRITE SECTORS
							'hF:	    // WRITE TRACK
								begin
									// seek data
									// 5: 0: read, 1: write
									// 4: m: 0: one sector, 1: until the track ends
									// 3: S: SIDE
									// 2: E: some 15ms delay
									// 1: C: check side matching?
									// 0: 0

									s_drq_busy <= 2'b01;
									{s_wrfault,s_seekerr,s_crcerr,s_lostdata} <= 0;

									{write,buff_rd} <= din[5] ? 2'b10 : 2'b01;
									if(RWMODE) buff_wr <= din[5];

									if(din[6]) wdreg_sector <= 1;

									format      <= din[6];
									multisector <= din[4];
									rw_type     <= 1;
									write_data  <= 0;
									read_data   <= 0;
									edsk_start  <= 0;
									edsk_addr   <= 0;
									state       <= STATE_SEARCH;

									if(s_readonly & din[5]) begin
										s_wrfault <= 1;
										state <= STATE_WAIT;
									end
								end
							'hC:	// READ ADDRESS
								begin
									// track, side, sector, sector size code, 2-byte checksum (crc?)
									s_drq_busy <= 2'b01;
									{s_wrfault,s_seekerr,s_crcerr,s_lostdata} <= 0;

									{write,buff_rd} <= 0;
									if(RWMODE) buff_wr <=0;

									format      <= 0;
									multisector <= 0;
									rw_type     <= 0;
									read_data   <= 0;
									edsk_start  <= edsk_next;
									data_length <= 6;

									// Rotate within this track's own numbering, and CLAMP into
									// it rather than only wrapping at the top.
									//
									// On a DS80 disk the reserved cylinders number 1..10 and
									// the data cylinders 21..30, so the base changes under a
									// free-running counter as the head steps. Wrapping alone
									// only catches a value that has run off the TOP; stepping
									// from cylinder 1 to cylinder 2 leaves ra_sector at 1..10,
									// which is BELOW the new base, so the wrap never fires and
									// READ ADDRESS reports IDs that do not exist on that
									// track.
									//
									// That is not cosmetic, because the BIOS discovers the
									// numbering by issuing READ ADDRESS and then asks for what
									// it was told. Measured (BUG-012): with a stale base it
									// requested sector 2 on a track numbered 21..30 and got
									// `CP/M Err On A: Bad Sector`; the same disk's .dsk
									// container, which carries real IDs and takes the scanner
									// path, asked for sector 22 at the same PC and booted.
									ra_now = (ra_sector < secbase || ra_sector > sectop)
									         ? secbase : ra_sector;

									read_addr[0] <= disk_track;
									read_addr[1] <= {7'b0, side};
									read_addr[2] <= ra_now;
									read_addr[3] <= wd_size_code;
									read_addr[4] <= 0;
									read_addr[5] <= 0;

									if(ra_now >= sectop) ra_sector <= secbase;
										else ra_sector <= ra_now + 1'd1;
									state <= STATE_SEARCH;
								end
							'hD:	// FORCE INTERRUPT
								begin
									// A force interrupt with no condition bits ($D0)
									// terminates the current command but leaves the
									// status reporting the command it interrupted -
									// so an aborted Type II read still shows LOST
									// DATA in bit 2 rather than reverting to Type I,
									// where bit 2 is TRACK00. ubee512 models this by
									// restoring `lastcmd` (src/fdc.c fdc_cmd_w) and
									// keying fdc_status_r off it.
									//
									// The MicroBee boot ROM depends on this. It ends
									// each system load with $D0 then tests
									// `status & $9C` ($EF7B-$EF80 in bn54); sitting on
									// track 0, a Type I status reads back $24, the
									// TRACK00 bit lands inside the mask, and the ROM
									// abandons the load with "System unreadable".
									// Note this must *hold* cmd_mode, not set it from
									// din[7] as the common path above does.
									if(din[3:0] != 0) cmd_mode <= 0;
									else              cmd_mode <= cmd_mode;
									if(state != STATE_IDLE) state <= STATE_ABORT;
										else {s_wrfault,s_seekerr,s_crcerr,s_lostdata, s_drq_busy} <= 0;
								end
							'hE:	// READ TRACK
								begin
									{s_wrfault,s_crcerr,s_lostdata} <= 0;
									s_seekerr  <= 1;
									s_drq_busy <= 2'b01;
									state <= STATE_WAIT;
								end
							endcase
						end
					end

				A_TRACK:  if (!s_busy) wdreg_track <= din;
				// ra_sector models the sector ID rotating under the head, which is
				// what READ ADDRESS reports. Upstream slaves it to the sector
				// register, but on real hardware the two are unrelated - and the
				// MicroBee boot ROM writes 0 to the sector register as a scratch
				// value during its FDC presence test ($E673), which would make the
				// next READ ADDRESS report sector 0. No formatted disk has a sector
				// 0, so the ROM mis-identifies the disk. Only track sector numbers
				// that could actually exist on the media.
				A_SECTOR: if (!s_busy) begin
								wdreg_sector <= din;
								if (din >= secbase && din <= sectop) ra_sector <= din;
							end
				A_DATA:   wdreg_data <= din;
			endcase
		end
	end
end

reg        scan_active = 0;
reg [19:0] scan_addr;
reg        scan_wr;

reg  [1:0] edsk_sizecode = 0;      // sector size: 0=128K, 1=256K, 2=512K, 3=1024K
reg        edsk_side = 0;          // Side number (0 or 1)
reg  [6:0] edsk_track = 0;         // Track number
reg  [7:0] edsk_sector = 0;        // Sector number 0..15
reg [19:0] edsk_offset = 0;
reg  [7:0] edsk_trackf = 0, edsk_sidef = 0;

reg [10:0] edsk_addr, edsk_start;

reg [10:0] edsk_size /* verilator public_flat_rd */ = 0;
wire[10:0] edsk_next = ((edsk_addr + 1'd1) >= edsk_size) ? 11'd0 : edsk_addr + 1'd1;

reg  [7:0] spt_size /* verilator public_flat_rd */ = 0;
// Scan diagnostics - how many bytes the parser actually saw, and the geometry
// it latched out of the header. Cheap, and it turns "the table is wrong" into a
// specific number.
reg [19:0] dbg_bytes /* verilator public_flat_rd */ = 0;
reg [15:0] dbg_tsize /* verilator public_flat_rd */ = 0;
reg  [9:0] dbg_hdrs  /* verilator public_flat_rd */ = 0;   // track headers seen
reg [31:0] dbg_sum   /* verilator public_flat_rd */ = 0;   // checksum of bytes parsed

generate
	if(EDSK) begin
		wire [7:0] scan_data = RWMODE ? buff_dout : input_data;
		reg [53:0] edsk[1992];
		reg  [7:0] spt[166];

		always @(posedge clk_sys) begin
			{edsk_track,edsk_side,edsk_trackf,edsk_sidef,edsk_sector,edsk_sizecode,edsk_offset} <= edsk[edsk_addr];
			edsk_spt <= spt[spt_addr];
		end

		reg  [7:0] tpos;
		reg  [7:0] tsize;
		reg  [7:0] tsizes[166];
		always @(posedge clk_sys) tsize <= tsizes[tpos];

		// Two accepted container formats. Everything from byte 256 on - the
		// track info blocks and per-sector tables - is byte-identical between
		// them, so only the 256-byte header needs telling apart:
		//
		//              standard .dsk            EXTENDED .dsk
		//   sig @ 0     "MV - CPCEMU Disk"      "EXTENDED CPC DSK"
		//   tracks @48  same                    same
		//   sides  @49  same                    same
		//   trk size    ONE 16-bit LE @ 0x32,   one byte per track @ 0x34+,
		//               uniform for all tracks  each x 256
		//
		// Anything matching neither leaves var_size clear and falls through to
		// the fixed-geometry path, which is how raw images (.ss80 and friends)
		// keep working.
		wire[127:0] edsk_sig = "EXTENDED CPC DSK";
		wire[127:0] std_sig  = "MV - CPCEMU Disk";
		wire[127:0] sig_pos  = edsk_sig >> (8'd120-(scan_addr[7:0]<<3));
		wire[127:0] ssig_pos = std_sig  >> (8'd120-(scan_addr[7:0]<<3));

		always @(posedge clk_sys) begin
			reg old_active, old_wr;
			reg [13:0] hdr_pos, bcnt;
			reg  [7:0] idStatus;
			reg  [6:0] track;
			reg        side;
			reg  [7:0] sector;
			reg  [1:0] sizecode;
			reg  [7:0] crc1;
			reg  [7:0] crc2;
			reg  [7:0] sectors;
			reg [15:0] track_size, track_pos;
			reg [19:0] offset, offset1;
			reg  [7:0] size_lo;
			reg [10:0] secpos;
			reg  [7:0] trackf, sidef;
			reg        ext_ok, std_ok, std_dsk;

			old_active <= scan_active;
			if(scan_active & ~old_active) begin
				edsk_size <=0;
				spt_size  <=0;
				track_pos <=0;
				var_size  <=1;
				ext_ok    <=1;
				std_ok    <=1;
				std_dsk   <=0;
				dbg_bytes <=0;
				dbg_sum   <=0;
				dbg_hdrs  <=0;
			end

			old_wr <= scan_wr;
			if(scan_wr & ~old_wr & scan_active) begin
				dbg_bytes <= dbg_bytes + 1'd1;
				dbg_sum   <= dbg_sum + scan_data;
				// Test both signatures over the first 16 bytes, then commit at
				// byte 16 once every comparison has been made.
				if(scan_addr[19:0] < 16) begin
					if(sig_pos[7:0]  != scan_data) ext_ok <= 0;
					if(ssig_pos[7:0] != scan_data) std_ok <= 0;
				end
				if(scan_addr[19:0] == 16) begin
					var_size <= ext_ok | std_ok;
					std_dsk  <= std_ok;
				end
				if(var_size) begin
					if( scan_addr == 48) spt_size <= scan_data; else
					if((scan_addr == 49) & (scan_data == 2)) spt_size <= spt_size << 1; else
					// Standard: one uniform 16-bit little-endian track size.
					if( std_dsk & (scan_addr == 50)) track_size[7:0]  <= scan_data; else
					if( std_dsk & (scan_addr == 51)) begin
						track_size[15:8] <= scan_data;
						dbg_tsize[15:8]  <= scan_data;
						track_pos <= 0;
						tpos <= 1;
					end else
					// EXTENDED: first track size here, the rest in a table.
					if(~std_dsk & (scan_addr == 52)) begin
						track_size <= {scan_data, 8'd0};
						track_pos  <= 0;
						tpos <= 1;
					end else
					if((scan_addr  > 52) & (scan_addr < 218)) begin
						if(~std_dsk) tsizes[scan_addr - 52] <= scan_data;
						spt[scan_addr - 52] <= 0;
					end else
					if((scan_addr >= 256) && track_size) begin
						track_pos <= track_pos + 1'd1;
						case(track_pos)
							00: offset  <= scan_addr + 9'd256;
							16: track   <= scan_data[6:0];
							17: side    <= scan_data[0];
							21: sectors <= scan_data;
							22: begin
									spt[(side ? (spt_size >> 1) : 8'd0) + track] <= sectors;
									dbg_hdrs <= dbg_hdrs + 1'd1;
								end
							default:
								if((track_pos >= 24) && sectors) begin
									case(track_pos[2:0])
										0: begin
												trackf  <= scan_data;
												secpos  <= edsk_size;
												offset1 <= offset;
											end
										1: sidef   <= scan_data;
										2: sector  <= scan_data;
										3: sizecode<= scan_data[1:0];
										6: size_lo <= scan_data;
										7: begin
												// EXTENDED gives every sector an
												// explicit byte length here.
												// Standard .dsk leaves these two
												// bytes zero and the length is
												// implied by the size code, so
												// testing for non-zero would skip
												// every sector and leave the table
												// empty.
												if(std_dsk) begin
													edsk[secpos] <= {track,side,trackf,sidef,sector,sizecode,offset1};
													edsk_size <= edsk_size + 1'd1;
													offset <= offset + (20'd128 << sizecode);
												end
												else if({scan_data, size_lo}) begin
													edsk[secpos] <= {track,side,trackf,sidef,sector,sizecode,offset1};
													edsk_size <= edsk_size + 1'd1;
													offset <= offset + {scan_data, size_lo};
												end
												sectors <= sectors - 1'd1;
											end
										default:;
									endcase
								end
						endcase
						if(track_pos >= (track_size - 1'd1)) begin
							// EXTENDED images give every track its own size;
							// standard ones are uniform, so hold what byte
							// 0x32 set rather than loading the (unwritten)
							// per-track table.
							if(~std_dsk) track_size <= {tsize, 8'd0};
							track_pos  <= 0;
							tpos <= tpos + 1'd1;
						end
					end
				end
			end
		end
	end
endgenerate

endmodule

//============================================================================
// Dual-port buffer RAM.
//
// The upstream Specialist_MiSTer version instantiates Altera's altsyncram
// directly, which Verilator cannot simulate. This is an inferred true
// dual-port RAM with the same interface and read-during-write behaviour
// (read-old-data on the written port), which Quartus maps onto the same M10K
// blocks on Cyclone V.
//============================================================================
module wd1793_dpram #(parameter DATAWIDTH=8, ADDRWIDTH=11)
(
	input                  clock,

	input  [ADDRWIDTH-1:0] address_a,
	input  [DATAWIDTH-1:0] data_a,
	input                  wren_a,
	output [DATAWIDTH-1:0] q_a,

	input  [ADDRWIDTH-1:0] address_b,
	input  [DATAWIDTH-1:0] data_b,
	input                  wren_b,
	output [DATAWIDTH-1:0] q_b
);

reg [DATAWIDTH-1:0] mem [0:(2**ADDRWIDTH)-1];
reg [DATAWIDTH-1:0] q_a_r, q_b_r;

always @(posedge clock) begin
	if (wren_a) mem[address_a] <= data_a;
	q_a_r <= mem[address_a];
end

always @(posedge clock) begin
	if (wren_b) mem[address_b] <= data_b;
	q_b_r <= mem[address_b];
end

assign q_a = q_a_r;
assign q_b = q_b_r;

endmodule
