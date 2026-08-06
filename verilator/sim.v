//============================================================================
// Simulation harness top for the MicroBee core.
//
// This is NOT the MiSTer `emu` - it is a simulation-only top that stands in
// for microbee.sv, exposing the signals the C++ harness drives and samples.
// The module is still called `emu` because sim_main.cpp and the Makefile's
// --top-module expect that name.
//
// Signal names mirror hps_io's so the C++ side stays portable:
//   ioctl_*     ROM download
//   sd_*/img_*  block device (M4)
//   ps2_key     keyboard (M3)
//
// All RAM/ROM lives inside microbee_core in BRAM (64K DRAM + 16K ROM + 4K
// char ROM + 4K video is well under the Cyclone V's budget), so unlike the
// Mac II harness this one needs no external memory model.
//============================================================================

`timescale 1ps / 1ps

module emu
(
	input         clk_sys,
	input         reset,

	// 0 = green, 1 = amber, 2 = white
	input   [1:0] phosphor,
	// Render in colour instead. Ignored on a model with no colour board.
	input         use_colour,
	input         piob7_vs,

	// Master clock select (--fast). 1 = clk_sys is 13.5 MHz, so the core divides
	// by 1/4/8 instead of 4/16/32 and a frame costs a quarter of the ticks.
	// Driven every edge by sim_main.cpp - see the note in microbee_core.v.
	input         sim_fast,

	// Machine selection (M6). The harness drives these from --model and
	// --boot-basic and holds the core in reset over a change, the same way
	// microbee.sv does from the OSD.
	input   [2:0] model,
	input         boot_basic,

	// Keyboard (M3). kbd_symbolic mirrors the OSD's Symbolic/Positional
	// option so both mappings are testable headlessly (--positional).
	input  [10:0] ps2_key,
	input         kbd_symbolic,

	// Video
	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_HB,
	output        VGA_VB,
	output        CE_PIXEL,

	// Audio (M5)
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,

	// ioctl (ROM download) - 8 bit
	input         ioctl_download,
	input         ioctl_wr,
	input  [24:0] ioctl_addr,
	input   [7:0] ioctl_dout,
	// 16 bits, matching hps_io. It was 8, which silently capped the harness at
	// ROM slot 3: the slot goes on the wire as N<<6, so slot 4 is 256 and wrapped
	// to 0 - loading WordBee over the CIAB boot ROM while hardware did the right
	// thing. See BUG-004.
	input  [15:0] ioctl_index,
	output        ioctl_wait,

	// Block device (M4)
	output [31:0] sd_lba[2],
	output  [1:0] sd_rd,
	output  [1:0] sd_wr,
	input   [1:0] sd_ack,
	input   [8:0] sd_buff_addr,
	input   [7:0] sd_buff_dout,
	output  [7:0] sd_buff_din[2],
	input         sd_buff_wr,
	input   [1:0] img_mounted,
	input  [63:0] img_size,

	// Cassette (M8-1). Block slot 1 is the tape - mounted with --tape, which
	// calls MountDisk(file, 1). tape_rewind is a one-shot from the C++ side and
	// stands in for the OSD's T[18]; tape_audio_en for O[17].
	input         tape_rewind,
	input         tape_audio_en,

	// Cold Boot, standing in for the OSD's T[19]. A one-shot from the C++ side
	// (--cold-boot N), exactly like tape_rewind. dram_clearing is brought out as
	// a PORT rather than read as an internal wire because sim.v marks nothing
	// public_flat - and a signal the harness cannot see is one the harness
	// cannot prove did anything.
	input         cold_boot,
	output        dram_clearing,
	output        tape_playing,
	output [31:0] tape_bytes,
	output [31:0] tape_stalls,
	output [31:0] tape_fetches,

	// Debug taps
	output [15:0] debug_pc,
	output  [7:0] debug_opcode,
	output        debug_fetch,
	output [15:0] debug_addr,
	output  [7:0] debug_din,
	output  [7:0] debug_dout,
	output        debug_mreq,
	output        debug_iorq,
	output        debug_rd,
	output        debug_wr,
	output  [7:0] debug_port50
);

//--------------------------------------------------------------------------
// Reset: hold the core in reset until the ROM download has finished, so the
// Z80 never fetches from an empty ROM.
//--------------------------------------------------------------------------
reg  [7:0] reset_cnt = 8'hFF;
reg        dl_seen   = 1'b0;
reg        dl_done   = 1'b0;
// Hold the machine in reset while a mounted image is being scanned. The .dsk
// scanner borrows the FDC's sector buffer, so the CPU must not issue any FDC
// command until it is done - see microbee_core.v at the wd1793 instance.
wire       disk_prepare;
// Cold Boot zeroes the DRAM array and the CPU must be held off while it does -
// same rule as the scanner above. It is much the longest of the three holds,
// ~131,000 cycles for 128K, and releases itself when the walk finishes.
// dram_clearing is a port, declared above.
wire       core_reset = reset | (reset_cnt != 0) | disk_prepare | dram_clearing;

always @(posedge clk_sys) begin
	if (reset) begin
		reset_cnt <= 8'hFF;
		dl_seen   <= 1'b0;
		dl_done   <= 1'b0;
	end
	else if (ioctl_download) begin
		dl_seen   <= 1'b1;
		reset_cnt <= 8'hFF;
	end
	else begin
		if (dl_seen) dl_done <= 1'b1;
		// Release reset once a download has completed. If the sim is run with
		// no ROM at all we still come out of reset so the harness isn't stuck.
		if (reset_cnt != 0) reset_cnt <= reset_cnt - 8'd1;
	end
end

assign ioctl_wait = 1'b0;

//--------------------------------------------------------------------------
// The machine
//--------------------------------------------------------------------------
wire       ce_pix;
wire       hs, vs, hb, vb;
wire [7:0] vid_r, vid_g, vid_b;

wire signed [15:0] core_audio;

// Must match microbee.sv - bank 2 is the Premium ROM (bn56), so 2 banks is not
// enough and the download would be silently rejected by dl_bank_ok.
//
// The master clock rate is chosen at run time by --fast, which pokes the core's
// sim_fast register directly (see sim_main.cpp). Default is the 54 MHz hardware
// configuration, so an unqualified run matches what gets synthesised.
microbee_core #(.RAM_MAX_KB(128), .ROM1_BANKS(3)) core
(
	.clk_sys        (clk_sys),
	.reset          (core_reset),

	.cold_boot      (cold_boot),
	.dram_clearing  (dram_clearing),

	.model          (model),
	.boot_basic     (boot_basic),

	.ioctl_download (ioctl_download),
	.ioctl_wr       (ioctl_wr),
	.ioctl_addr     (ioctl_addr),
	.ioctl_dout     (ioctl_dout),
	// The core decodes the bootN.rom slot from ioctl_index[15:6], which is how
	// MiSTer delivers it. Full 16 bits, so slots 4 and 5 (WordBee, Telcom) reach
	// the core exactly as hardware sends them.
	.ioctl_index    (ioctl_index),

	.ps2_key        (ps2_key),
	.kbd_symbolic   (kbd_symbolic),

	.sd_lba         (core_sd_lba),
	.sd_rd          (core_sd_rd),
	.sd_wr          (core_sd_wr),
	.sd_ack         (sd_ack[0]),
	.sd_buff_addr   (sd_buff_addr),
	.sd_buff_dout   (sd_buff_dout),
	.sd_buff_din    (core_sd_buff_din),
	.sd_buff_wr     (sd_buff_wr),
	.img_mounted    (img_mounted[0]),
	.img_readonly   (1'b0),
	.img_size       (img_size[31:0]),
	// ss80 is the CIAB's native format and the only raw one used so far; the
	// harness has no --geometry flag yet, so this matches the old hard-wired
	// value. .dsk images ignore it (they parse to var_size=1).
	// Same rule as microbee.sv: ds80 is the only raw format at 819,200 bytes,
	// so geometry is detected rather than selected. Keep the two in step.
	.disk_layout    (img_size[31:0] != 32'd819200),
	.disk_prepare   (disk_prepare),
	.disk_busy      (),
	.model_has_fdc  (),

	// Cassette on block slot 1. img_size is shared across slots and valid at
	// the img_mounted pulse, which is MiSTer's own convention - the tape module
	// latches it there.
	.tape_mounted   (img_mounted[1]),
	.tape_size      (img_size[31:0]),
	.tape_lba       (core_tape_lba),
	.tape_rd        (core_tape_rd),
	.tape_ack       (sd_ack[1]),
	.tape_buff_addr (sd_buff_addr),
	.tape_buff_dout (sd_buff_dout),
	.tape_buff_wr   (sd_buff_wr),
	.tape_rewind    (tape_rewind),
	.tape_audio_en  (tape_audio_en),
	.tape_playing   (tape_playing),
	.tape_bytes     (tape_bytes),
	.tape_stalls    (tape_stalls),
	.tape_fetches   (tape_fetches),

	.phosphor       (phosphor),
	.use_colour     (use_colour),
	.piob7_vs       (piob7_vs),
	.sim_fast       (sim_fast),
	.ce_pix         (ce_pix),
	.hsync          (hs),
	.vsync          (vs),
	.hblank         (hb),
	.vblank         (vb),
	// Aspect inputs for MiSTer's scaler; the harness renders 1:1 and ignores them.
	.active_w       (),
	.active_h       (),
	.R              (vid_r),
	.G              (vid_g),
	.B              (vid_b),
	.audio          (core_audio),

	.dbg_pc         (debug_pc),
	.dbg_opcode     (debug_opcode),
	.dbg_fetch      (debug_fetch),
	.dbg_addr       (debug_addr),
	.dbg_din        (debug_din),
	.dbg_dout       (debug_dout),
	.dbg_mreq       (debug_mreq),
	.dbg_iorq       (debug_iorq),
	.dbg_rd         (debug_rd),
	.dbg_wr         (debug_wr),
	.dbg_port50     (debug_port50)
);

assign VGA_R    = vid_r;
assign VGA_G    = vid_g;
assign VGA_B    = vid_b;
assign VGA_HS   = hs;
assign VGA_VS   = vs;
assign VGA_HB   = hb;
assign VGA_VB   = vb;
assign CE_PIXEL = ce_pix;

assign AUDIO_L = core_audio;
assign AUDIO_R = core_audio;

//--------------------------------------------------------------------------
// Block device. Slot 0 is the floppy, slot 1 the cassette. The tape is read
// only, so nothing drives sd_wr[1] and sd_buff_din[1] stays tied off.
//--------------------------------------------------------------------------
wire [31:0] core_sd_lba;
wire        core_sd_rd, core_sd_wr;
wire  [7:0] core_sd_buff_din;
wire [31:0] core_tape_lba;
wire        core_tape_rd;

assign sd_lba[0] = core_sd_lba;
assign sd_lba[1] = core_tape_lba;
assign sd_rd = {core_tape_rd, core_sd_rd};
assign sd_wr = {1'b0, core_sd_wr};
assign sd_buff_din[0] = core_sd_buff_din;
assign sd_buff_din[1] = 8'd0;

wire _unused = &{1'b0, img_size[63:32], dl_done, 1'b0};

endmodule
