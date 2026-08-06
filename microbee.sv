//============================================================================
//
//  MicroBee core for MiSTer — top level.
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
//
//  Ported from verilator/sim.v, which is the same machine wired to the
//  simulation harness and is the reference for anything ambiguous here. The two
//  must stay in step: the harness is what proves the core, so a signal that
//  exists only on this side is a signal nothing tests.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Ports not used by this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_MIX = 0;

assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////
//
// Status bit map. [0] and [122:121] are framework convention; the rest are
// ours. Keep this comment in step with CONF_STR - a stale bit map here is
// how two options end up sharing a bit.
//
//   [0]       reset
//   [3:2]     scandoubler FX
//   [6:5]     raw image geometry
//   [9:7]     model            (see rtl/microbee_models.v for the encoding)
//   [11:10]   phosphor
//   [14:12]   scale
//   [15]      boot ROM: disk / BASIC
//   [16]      keyboard: symbolic / positional
//   [17]      tape audio: on / off
//   [18]      rewind tape (momentary)
//   [19]      cold reset (momentary)
//   [122:121] aspect ratio
//
// Free: [1], [4], [20] and up. [6:5] stay RESERVED - a config saved by the
// session-4 build, when they were the raw-geometry option, must not come to mean
// something else.
//
//////////////////////////////////////////////////////////////////

`include "build_id.v"
localparam CONF_STR = {
	"MicroBee;;",
	"-;",
	// Extensions are fixed THREE-character groups, concatenated - not a
	// comma-separated list. So this is DSK + SS8 + DS8, and a typo becomes a
	// silently wrong filter rather than an error.
	//
	// DS8 added session 9, with raw DS80 support (BUG-012). Without it the file
	// browser simply does not list .ds8 images, which is invisible from the
	// Verilator side: the harness takes --disk and never parses CONF_STR, so no
	// simulation covers this line. Note the extension plays no part in geometry
	// detection either - that is `img_size == 819200` - so the filter is purely
	// about what the user can see and pick.
	"S0,DSKSS8DS8,Mount Drive A:;",
	"-;",
	// Cassette (M8-1). LOAD only - SAVE is a separate milestone, so there is
	// one mount and no "new tape" to create. Playback starts by itself when the
	// machine enters its tape sampling loop, which is why there is no Play:
	// the real machine had no motor control either, and ubee512 offers only a
	// Rewind. Type LOAD in BASIC and the tape follows.
	//
	// Slot index and line position are independent - drive B: takes S2 at M8-2
	// and will be listed above this line.
	"S1,TAP,Mount Tape;",
	"T[18],Rewind Tape;",
	// Default On, and deliberately so: a load takes minutes against a static
	// screen, and the sound is the only sign the machine is working. Without it
	// users conclude it has hung. See the mix in rtl/microbee_core.v for why
	// this emulates the recorder rather than the machine's own speaker.
	"O[17],Tape Audio,On,Off;",
	"-;",
	// List position IS the encoding, and MiSTer saves the number rather than the
	// label, so a saved config breaks if anything moves. All four implemented
	// models are now listed, in the frozen microbee_models.v order.
	//
	// PREMIUM 128K is appended last (decided session 8): MODEL_P128K was already
	// 3'd3, so adding the label needed no renumbering and nothing at 0-2 moved.
	// Capability order - IC first - was declined because value 0 is also the
	// cold-start default, and leading with the IC would boot a new user
	// following the Readme into a machine with no FDC and a disk that will not
	// mount.
	"H0O[9:7],Model,CIAB STANDARD,CIAB PREMIUM,32K IC,PREMIUM 128K;",
	"H1O[15],Load BASIC ROM,No,Yes;",
	"O[11:10],Phosphor,Colour,Amber,Green,White;",
	"O[16],Keyboard,Symbolic,Positional;",
	"-;",
	"P1,Video;",
	"P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O[3:2],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%;",
	"P1O[14:12],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",
	"-;",
	// No F entries. bootN.rom is auto-loaded regardless of the menu - confirmed
	// by Apple-IIgs_MiSTer, which loads two boot ROMs and declares none.
	//
	// Shown only when the matching slot received no data, so a machine that
	// will not boot says why instead of presenting a bare flashing cursor.
	// Keep these short. The OSD clips a line at roughly 26 characters, and
	// "WARNING: boot0.rom not loaded" (29) lost its tail on hardware. There is no
	// room for the consequence as well as the filename - the Readme's symptom
	// table carries that.
	"H2-,WARNING: boot0.rom missing;",
	// Present but not what it should be - wrong order, truncated, or the wrong
	// images. Separate from "missing" because the fix is different.
	"H5-,WARNING: boot0.rom is wrong;",
	// The 32K IC's WordBee and Telcom. Shown only on that model - a CIAB user
	// has no use for either ROM, and a warning that is always true is a warning
	// nobody reads.
	"H3-,WARNING: boot1.rom missing;",
	"H4-,WARNING: boot2.rom missing;",
	"-;",
	// Both resets are R, so both close the OSD. The stock template's
	// "T[0],Reset;" / "R[0],Reset and close OSD;" pair was dropped in session 11:
	// two entries for one action is clutter, and with a second reset on the menu
	// the pair would have become four lines for two actions. Closing is the right
	// behaviour for both - you want to be looking at the machine when it comes
	// back, which is the same argument that makes Cold Reset an R.
	//
	// Apple-IIgs_MiSTer does exactly this: "R0,Warm Reset;" / "R1,Cold Reset;",
	// two R entries and no T. Status bit [0] is unchanged, so a saved config and
	// the framework's own use of the reset bit are both unaffected.
	"R[0],Reset;",
	// Cold Reset zeroes DRAM as well as resetting, which is the difference
	// between the RESET button and the power switch on a real machine. Reset
	// alone leaves BASIC's program in memory - normally you would type NEW, but
	// a machine-code game owns the machine and leaves no prompt to type it at,
	// so after loading one from tape the only way back to a usable BASIC was to
	// exit the core. On real hardware this is ESC held during RESET; we have no
	// RESET key to hold it with, so the OSD is where it goes.
	//
	// R, not T, so the OSD closes - the whole point is to be looking at the
	// machine when it comes back.
	//
	// R at a NON-ZERO bit is the part worth having evidence for, since R could
	// have been special-cased to reset at bit 0, and CONF_STR is the one surface
	// no simulation covers - it has already cost two hardware rounds (BUG-011,
	// BUG-014). Apple-IIgs_MiSTer settles it: it declares "R0,Warm Reset;" and
	// "R1,Cold Reset;", so R carries its bit number. Our own T[18] Rewind proves
	// the bracket syntax on this core. Between them the combination is covered.
	//
	// Named to match that core rather than "Cold Boot", because it sits directly
	// under Reset and the pair should read as a pair.
	"R[19],Cold Reset;",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire [127:0] status;
wire   [1:0] buttons;
wire  [10:0] ps2_key;
wire         forced_scandoubler;
wire  [21:0] gamma_bus;

wire         ioctl_download;
wire         ioctl_wr;
wire  [24:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire  [15:0] ioctl_index;

// Two slots: 0 is the floppy, 1 the cassette. The tape is read only, so
// sd_wr[1] and sd_buff_din[1] are tied off.
wire  [31:0] sd_lba[2];
wire   [1:0] sd_rd, sd_wr, sd_ack;
wire   [8:0] sd_buff_addr;
wire   [7:0] sd_buff_dout;
wire   [7:0] sd_buff_din[2];
wire         sd_buff_wr;
wire   [1:0] img_mounted;
wire         img_readonly;
wire  [63:0] img_size;

wire  [31:0] fdc_lba, tape_lba;
wire         fdc_rd, fdc_wr, tape_rd;
wire   [7:0] fdc_buff_din;

assign sd_lba[0]      = fdc_lba;
assign sd_lba[1]      = tape_lba;
assign sd_rd          = {tape_rd, fdc_rd};
assign sd_wr          = {1'b0,    fdc_wr};
assign sd_buff_din[0] = fdc_buff_din;
assign sd_buff_din[1] = 8'd0;

wire  [15:0] menumask;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask(menumask),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(1'b0),

	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

// 54.0 MHz: /4 -> 13.5MHz dot clock, /16 -> 3.375MHz Z80, /32 -> 1.6875MHz char clock.
wire clk_sys;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys)
);

/////////////////////   OSD SELECTIONS   /////////////////////////

wire [2:0] osd_model    = status[9:7];
wire       osd_basic    = status[15];

// Phosphor list: Colour, Amber, Green, White. microbee_video decodes the mono
// tubes as 0=green, 1=amber, 2=white, so the list order has to be translated.
//
// Do NOT renumber the core's encoding to avoid this: the Verilator harness's
// --phosphor flag shares it, and desyncing simulation from hardware is what let
// this bug reach a board in the first place.
//
// **Colour is first, so it is the power-on default**, which is what a Premium
// owner wants. On a machine with no colour hardware it falls back to amber -
// the tube most MicroBees shipped with, and what MAME does in the same case
// ("if colour chosen on mono bee, default to amber"). So the default is
// unchanged for every existing user: a standard CIAB still comes up amber.
//
// A Premium can also be run on a mono monitor by picking one, which is
// ubee512's behaviour - its `crtc.monitor` forces mono regardless of the model.
wire [1:0] osd_phos_sel = status[11:10];
wire       osd_use_colour = (osd_phos_sel == 2'd0);
wire [1:0] osd_phosphor = (osd_phos_sel == 2'd2) ? 2'd0    // Green
                        : (osd_phos_sel == 2'd3) ? 2'd2    // White
                        :                          2'd1;   // Amber, and the
                                                           // Colour fallback

// Raw images are ss80 only, so the layout is fixed: 1 = linear by track.
//
// The OSD offered ds40/ds80 from M6 until session 4, when they were removed -
// neither had ever been booted, there are no test images, and PLAN's risk list
// carries a DS80 track-0 quirk (data sectors numbered from 21) that would break
// exactly that path. Advertising an untested geometry costs a user a disk that
// looks corrupted; ss80 is the CIAB's native format and loses nothing.
//
// DS80 comes back with the Premium 128K (M7-4), where it is the native format
// and what most demos ship on. Status bits [6:5] are left RESERVED for it so a
// config saved by this build still decodes correctly when it returns.
// Raw geometry, detected from the image size rather than chosen in the OSD.
//
// The OSD used to carry a Raw geometry option because ss80 and ds40 are both
// 409,600 bytes, so size could not tell them apart. ds40 is not planned - no
// machine in scope needs it - and ds80 is 80 x 2 x 10 x 512 = 819,200, which is
// unique. So the option was removable, and removing it is strictly better: it
// deletes the failure where a user mounts an ss80 with the menu still set to
// ds80 and gets a disk that reads as garbage. Status bits [6:5] stay RESERVED so
// a config saved by an older build cannot come to mean something else.
//
// .dsk is unaffected - it is self-describing and ignores `layout`.
//
// img_size is SHARED across mount slots and is only valid at the matching
// img_mounted pulse, which is MiSTer's own convention. So this expression goes
// wrong the moment a tape is mounted - and it does not matter, because wd1793
// latches the layout at the disk's mount edge and never looks again. Do not
// "fix" it by widening img_size; fix it by keeping the latch.
wire       disk_layout  = (img_size[31:0] != 32'd819200);   // 1 = ss80 linear, 0 = ds80 interleaved

wire model_has_fdc;
wire model_has_romhi;

// Rewind is declared T[18], and MiSTer's T entries TOGGLE the bit rather than
// pulse it - so the momentary control the core wants has to be edge-detected
// here. Holding the level would pin the transport at the start of the tape.
wire tape_playing;
reg  tape_rewind = 1'b0;
reg  tape_rew_r  = 1'b0;
always @(posedge clk_sys) begin
	tape_rew_r  <= status[18];
	tape_rewind <= (status[18] != tape_rew_r);
end

// Cold Reset, R[19]. Same story as Rewind above - R and T entries both TOGGLE
// their bit rather than pulse it, so the core's one-shot is made here. Holding
// the level would restart the clear forever and never let the machine out of
// reset, which is why the core also ignores a re-trigger while it is clearing.
wire dram_clearing;
reg  cold_boot  = 1'b0;
reg  cold_bit_r = 1'b0;
always @(posedge clk_sys) begin
	cold_bit_r <= status[19];
	cold_boot  <= (status[19] != cold_bit_r);
end

// Which ROM slots actually received data. The bootN.rom number lives in
// ioctl_index[15:6] - see rtl/microbee_core.v and NOTES 12.
// Only three are tracked now, because only three exist. boot0.rom is one
// 36K bundle rather than four files, so "which image is missing" is not a
// question the core can answer - a short or mis-ordered bundle is a single
// failure. The Readme carries boot0.rom's SHA1 so it can be checked before it
// ever reaches the machine, which is stronger than anything worth building
// here in RTL: bn54 and bn56 share their first four bytes, so a signature
// check could not even catch the swap that matters most.
reg [2:0] rom_loaded = 3'b000;
always @(posedge clk_sys) begin
	if (ioctl_wr) begin
		case (ioctl_index[15:6])
			10'd0: rom_loaded[0] <= 1'b1;   // boot0.rom - the mandatory bundle
			10'd1: rom_loaded[1] <= 1'b1;   // boot1.rom - WordBee (32K IC)
			10'd2: rom_loaded[2] <= 1'b1;   // boot2.rom - Telcom  (32K IC)
			default: ;
		endcase
	end
end

// boot0.rom sanity check - six bytes at fixed offsets, plus the expected length.
//
// Cheap enough to be worth having (six comparators and a counter's worth of
// flags) and chosen to be genuinely discriminating rather than decorative. The
// interesting case is a hand-concatenated bundle in the WRONG ORDER, which is
// exactly 36,864 bytes like a correct one, so length alone is blind to it.
//
// bn54 and bn56 share their first four bytes (F3 11 00 60 - both start `DI`),
// so a first-byte signature could not tell them apart, and swapping those two
// is the mistake with real consequences: NOTES 2 records that mix-up costing a
// hardware round. Offset 5 is where they first differ - 0x00 in bn54, 0x40 in
// bn56 - so checking it at BOTH ends catches the swap in both directions.
//
// Measured from the images, not assumed:
//   0x0000 F3   bn54 `DI`
//   0x0005 00   bn54 specifically, not bn56
//   0x2004 7F   char ROM glyph 0, the hollow box's top row
//   0x3000 C3   BASIC's opening `JP $84C6`
//   0x7000 F3   bn56 `DI`
//   0x7005 40   bn56 specifically, not bn54
//
// The Readme carries boot0.rom's SHA1 as the authoritative check; this one
// exists so a bad bundle names itself on the machine instead of presenting as
// a blank screen.
reg [5:0] b0_sig = 6'd0;
reg       b0_len = 1'b0;
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index[15:6] == 10'd0)) begin
		case (ioctl_addr[15:0])
			16'h0000: b0_sig[0] <= (ioctl_dout == 8'hF3);
			16'h0005: b0_sig[1] <= (ioctl_dout == 8'h00);
			16'h2004: b0_sig[2] <= (ioctl_dout == 8'h7F);
			16'h3000: b0_sig[3] <= (ioctl_dout == 8'hC3);
			16'h7000: b0_sig[4] <= (ioctl_dout == 8'hF3);
			16'h7005: b0_sig[5] <= (ioctl_dout == 8'h40);
			default: ;
		endcase
		// Last byte of a correct 36K bundle. Catches truncation, and a short
		// file also leaves the later signature bits clear.
		if (ioctl_addr[15:0] == 16'h8FFF) b0_len <= 1'b1;
	end
end

wire boot0_ok = (&b0_sig) & b0_len;

// menumask[n] set => that CONF_STR line is hidden (the H prefix).
//   [0]   Model          - shown from M7-2, which is the first build with more
//                          than one machine to choose between.
//   [1]   Load BASIC ROM - meaningless on a model with no disk to boot from
//                          instead; the 32K IC at M7-3 always runs BASIC.
//   [2]   boot0 warning  - the mandatory bundle; without it nothing boots
//   [4:3] boot1/2 warning- the IC's option ROMs, shown only on the IC
//
// The BASIC option is deliberately NOT gated on its image having arrived. An
// earlier version did that, and on hardware the option hid itself because
// nothing had loaded - indistinguishable from the option not existing, which
// concealed the very failure you needed to see. The warning lines report that
// instead, which is the right way round.
assign menumask[0]    = 1'b0;
assign menumask[1]    = ~model_has_fdc;
assign menumask[2]    = rom_loaded[0];
// boot1/boot2 belong to the 32K IC alone, so the warning is hidden both when
// the image did arrive and when the selected machine has no socket for it.
assign menumask[3]    = rom_loaded[1] | ~model_has_romhi;
assign menumask[4]    = rom_loaded[2] | ~model_has_romhi;
// "wrong" only makes sense once something arrived - otherwise "missing" says it.
assign menumask[5]    = ~rom_loaded[0] | boot0_ok;
assign menumask[15:6] = 10'd0;

/////////////////////   RESET AND MODEL   ////////////////////////

// The memory map cannot move under a running Z80, so `model` and `boot_basic`
// are latched and the machine is held in reset across a change. Same reason the
// harness holds reset over a .dsk scan: disk_prepare streams the whole image
// through the FDC's sector buffer, and a CPU touching the controller meanwhile
// corrupts the scan (NOTES 10).
wire       disk_prepare;
wire       disk_busy;

reg  [2:0] model_r = 3'd0;
reg        basic_r = 1'b0;
reg  [7:0] rst_cnt = 8'hFF;

wire       rst_req = RESET | status[0] | buttons[1] | ioctl_download
                   | (osd_model != model_r) | (osd_basic != basic_r);

always @(posedge clk_sys) begin
	if (rst_req) begin
		rst_cnt <= 8'hFF;
		model_r <= osd_model;
		basic_r <= osd_basic;
	end
	else if (rst_cnt != 8'd0) rst_cnt <= rst_cnt - 8'd1;
end

// dram_clearing joins these for the same reason disk_prepare is here: the CPU
// must not be running while something else owns a memory it can reach. It is by
// far the longest of the three - ~131,000 cycles against rst_cnt's 255 - so a
// Cold Boot holds reset for the whole clear and releases on its own.
wire core_reset = (rst_cnt != 8'd0) | disk_prepare | dram_clearing;

/////////////////////////   CORE   ///////////////////////////////

wire       ce_pix;
wire       hs, vs, hb, vb;
wire [11:0] active_w, active_h;
wire [7:0] vid_r, vid_g, vid_b;
wire signed [15:0] core_audio;

// ROM1_BANKS(3): bank 0 = bn54 (CIAB), 1 = basic_5.22e (the IC and the BASIC
// option), 2 = bn56, which serves BOTH Premium machines. M7-4 adds no bank.
microbee_core #(.RAM_MAX_KB(128), .ROM1_BANKS(3)) core
(
	.clk_sys        (clk_sys),
	.reset          (core_reset),

	.cold_boot      (cold_boot),
	.dram_clearing  (dram_clearing),

	.model          (model_r),
	.boot_basic     (basic_r),

	.ioctl_download (ioctl_download),
	.ioctl_wr       (ioctl_wr),
	.ioctl_addr     (ioctl_addr),
	.ioctl_dout     (ioctl_dout),
	.ioctl_index    (ioctl_index),

	.ps2_key        (ps2_key),
	.kbd_symbolic   (~status[16]),

	.sd_lba         (fdc_lba),
	.sd_rd          (fdc_rd),
	.sd_wr          (fdc_wr),
	.sd_ack         (sd_ack[0]),
	.sd_buff_addr   (sd_buff_addr),
	.sd_buff_dout   (sd_buff_dout),
	.sd_buff_din    (fdc_buff_din),
	.sd_buff_wr     (sd_buff_wr),
	.img_mounted    (img_mounted[0]),
	.img_readonly   (img_readonly),
	.img_size       (img_size[31:0]),

	// Cassette. img_size is shared across slots and valid at the img_mounted
	// pulse - MiSTer's own convention - so the tape module latches it there.
	.tape_mounted   (img_mounted[1]),
	.tape_size      (img_size[31:0]),
	.tape_lba       (tape_lba),
	.tape_rd        (tape_rd),
	.tape_ack       (sd_ack[1]),
	.tape_buff_addr (sd_buff_addr),
	.tape_buff_dout (sd_buff_dout),
	.tape_buff_wr   (sd_buff_wr),
	.tape_rewind    (tape_rewind),
	.tape_audio_en  (~status[17]),
	.tape_playing   (tape_playing),
	.tape_bytes     (),
	.tape_stalls    (),
	.tape_fetches   (),
	.disk_layout    (disk_layout),
	.disk_prepare   (disk_prepare),
	.disk_busy      (disk_busy),

	.phosphor       (osd_phosphor),
	.use_colour     (osd_use_colour),
	// The model table owns this; the input is a harness override only, so it is
	// tied off here rather than exposed in the OSD. Setting it wrong is not
	// subtle - software watching PIO B7 for a frame tick interrupts forever.
	.piob7_vs       (1'b0),

	.ce_pix         (ce_pix),
	.hsync          (hs),
	.vsync          (vs),
	.hblank         (hb),
	.vblank         (vb),
	.active_w       (active_w),
	.active_h       (active_h),
	.R              (vid_r),
	.G              (vid_g),
	.B              (vid_b),
	.audio          (core_audio),

	.model_has_fdc  (model_has_fdc),
	.model_has_romhi(model_has_romhi),

	.dbg_pc         (),
	.dbg_opcode     (),
	.dbg_fetch      (),
	.dbg_addr       (),
	.dbg_din        (),
	.dbg_dout       (),
	.dbg_mreq       (),
	.dbg_iorq       (),
	.dbg_rd         (),
	.dbg_wr         (),
	.dbg_port50     ()
);

/////////////////////////   VIDEO   //////////////////////////////

// The MicroBee is a 15.625 kHz / 50 Hz machine, so the scandoubler is not
// optional for VGA or HDMI.
//
// The active area is NOT fixed - software reprograms the CRTC:
//   64x16 text  R1=64 R6=16 R9=15  ->  512 x 256   (ROM BASIC, arcade.dsk)
//   80x24 text  R1=80 R6=24 R9=10  ->  640 x 264   (CIAB menu, CP/M)
// A single CIAB boot crosses that boundary when the disk BIOS reprograms the
// CRTC on the way in. The total raster is 313 lines either way, which is what
// keeps both at 50 Hz.
//
// No new_vmode plumbing: hps_io measures the incoming h/v counts and re-notifies
// on a change by itself (`if(vid_hcnt != hcnt || vid_vcnt != vcnt || ...)`), and
// both MicroBee modes differ in both counts. It would only be needed for a mode
// change that left the active area identical, which this machine does not have.
assign CLK_VIDEO = clk_sys;   // = ce_pix * 4, which video_mixer requires

wire [2:0] fx = {1'b0, status[3:2]};
assign VGA_SL = fx[1:0];

wire vga_de;

video_mixer #(.LINE_LENGTH(700), .GAMMA(1)) video_mixer
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.ce_pix(ce_pix),

	.scandoubler(forced_scandoubler || |status[3:2]),
	.hq2x(status[3:2] == 2'b01),

	.gamma_bus(gamma_bus),

	.R(vid_r),
	.G(vid_g),
	.B(vid_b),

	// mc6545 drives positive-going sync and blank, which is what this wants.
	.HSync(hs),
	.VSync(vs),
	.HBlank(hb),
	.VBlank(vb),

	.HDMI_FREEZE(HDMI_FREEZE),
	.freeze_sync(),

	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_VS(VGA_VS),
	.VGA_HS(VGA_HS),
	.VGA_DE(vga_de)
);

// Aspect ratio.
//
// NOT 4:3. That describes the *monitor* showing the whole raster; what we emit is
// the active window, and MicroBee pixels are 1 wide : 2 tall - ubee512's
// doc/README.md documents a 2:1 display ratio as its default, and a 512x256
// source rendered 963x956 confirms it. So the picture's true shape is
//
//     active_width : active_height * 2
//
// which is 1:1 at 64x16 (512 x 256) and 40:33 at 80x24 (640 x 264). Declaring a
// fixed 4:3 made the picture about 33% too wide, most obviously at 64x16.
//
// Both figures change when software reprograms the CRTC, and the CIAB crosses
// between the two modes during a single boot, so this has to be computed rather
// than fixed. "Original" uses it; the other settings stay as the framework's.
wire [1:0] ar = status[122:121];
wire [11:0] ar_x = active_w;
wire [11:0] ar_y = {active_h[10:0], 1'b0};   // x2 - pixels are twice as tall as wide

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),

	.VGA_DE_IN(vga_de),
	.ARX((!ar) ? ar_x : (ar - 1'd1)),
	.ARY((!ar) ? ar_y : 12'd0),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(status[14:12])
);

/////////////////////////   AUDIO   //////////////////////////////

// Straight through. sys/audio_out.sv already runs this through an IIR filter and
// a DC_blocker on both channels, so the core's constant idle offset - a speaker
// driven from one port bit sits at a non-zero level - is removed there. A second
// blocker in the core would be redundant. AUDIO_S must be 1: this is signed.
assign AUDIO_L = core_audio;
assign AUDIO_R = core_audio;
assign AUDIO_S = 1;

/////////////////////////   LEDS   ///////////////////////////////

// Controller busy spans a whole command, which reads as drive activity; the
// individual block transfers are far too brief to see.
assign LED_DISK = {1'b0, disk_busy};
// Tape shares the user LED with the ROM download. Both mean "wait, something is
// happening", and a tape load is exactly the case where a user needs telling.
assign LED_USER = ioctl_download | tape_playing;

endmodule
