//============================================================================
// microbee_video - character generator, PCG, and pixel shifter.
//
// Owns the three video memories, because the CPU's view of the $F000-$FFFF
// window is defined in terms of the same character-generator layout the
// display uses:
//
//   screen RAM  2K   $F000-$F7FF   character codes
//   PCG RAM     2K   $F800-$FFFF   programmable characters 128-255
//   char ROM    4K                 two 2K character sets
//
// Display lookup (MAME mbee_v.cpp crtc_update_row):
//   chr[7]==0 -> char ROM  {alt_charset, chr[6:0], ra[3:0]}
//   chr[7]==1 -> PCG RAM   {chr[6:0], ra[3:0]}
//
// alt_charset comes from CRTC R12[5:4]==2'b10 (m6545_data_w case 12, which
// re-copies chargen+$800 over the low half of the character generator).
//
// CPU read path (MAME video_low_r / video_high_r):
//   $F000-$F7FF  latchrom ? char ROM : screen RAM     (writes always screen RAM)
//   $F800-$FFFF  PCG RAM
// latchrom is port $0B bit 0 - the same signal that gates the keyboard scan.
//
// This is the standard (non-Premium) video: one PCG bank, monochrome. The
// Premium additions - attribute RAM, colour RAM, 8 PCG banks via port $1C -
// are a superset and land in M7.
//============================================================================

module microbee_video
(
	input             clk,
	input             ce_pix,       // 13.5 MHz
	input             ce_char,      // 1.6875 MHz

	// From the CRTC
	input      [13:0] MA,
	input       [4:0] RA,
	input             DE,
	input             CURSOR,
	input             alt_charset,

	// CPU port for the $F000-$FFFF window (12-bit offset within it)
	input      [11:0] cpu_addr,
	input       [7:0] cpu_din,
	output reg  [7:0] cpu_dout,
	input             cpu_wr,
	input             latchrom,     // port $0B bit 0

	// Premium (M7-2). See the port $1C notes in microbee_core.
	//   port1c[7]   extended graphics: attributes and PCG banks live
	//   port1c[4]   select attribute RAM into the $F000-$F7FF window
	//   port1c[3:0] PCG bank for the $F800-$FFFF window
	// port08_cram is port $08 bit 6 - selects colour RAM into $F800-$FFFF.
	// has_colour is the model flag; with it low this module behaves exactly as
	// it did before M7-2.
	input       [7:0] port1c,
	input             port08_cram,

	// has_colour = the colour board is FITTED. It gates CPU access to colour
	// RAM, the attribute RAM and the PCG banks - the machine's hardware.
	// use_colour = the display is a colour monitor. It gates only the final
	// pixel colour, so a Premium driving a mono tube still has working colour
	// RAM underneath, exactly as the real machine would. ubee512 makes the same
	// split: `modelx.colour` is the model, `crtc.monitor` is the screen.
	input             has_colour,
	input             use_colour,
	input             frame_tick,   // vsync, for the flash attribute

	// Character ROM download
	input             rom_wr,
	input      [11:0] rom_addr,
	input       [7:0] rom_din,

	// Phosphor: 0 = green, 1 = amber, 2 = white. Mono models only.
	input       [1:0] phosphor,

	// Pixel out
	output reg  [7:0] R,
	output reg  [7:0] G,
	output reg  [7:0] B
);

//--------------------------------------------------------------------------
// Memories
//--------------------------------------------------------------------------
// PCG RAM is 8 banks of 2K on Premium (ubee512 `pcg` = 8), one on a standard
// machine. Always synthesised at full size - 16K of BRAM is cheap, and a
// runtime-selected model cannot resize an array.
reg [7:0] scrram  [0:2047]  /* verilator public_flat_rw */;
reg [7:0] pcgram  [0:16383] /* verilator public_flat_rw */;
reg [7:0] charrom [0:4095];
reg [7:0] attram  [0:2047]  /* verilator public_flat_rw */;
reg [7:0] colram  [0:2047]  /* verilator public_flat_rw */;

wire in_pcg = cpu_addr[11];

// Premium features are live only when the model has the hardware AND software
// has asked for it. `extended` gates attributes and PCG banks; colour RAM is
// gated separately, because MAME reads it whenever port $08 bit 6 is set
// regardless of port $1C bit 7.
wire       extended = has_colour & port1c[7];
wire [2:0] cpu_bank = port1c[2:0];

// Which memory the CPU sees in each half of the window (MAME mbee_v.cpp
// video_low_r/w and video_high_r/w):
//
//   $F000-$F7FF  (port1c & $9F)==$90 -> attribute RAM   (d7 set, d4 set, bank 0)
//                latchrom            -> character ROM
//                otherwise           -> screen RAM
//                writes: d4 selects attribute RAM (Premium only), else screen
//
//   $F800-$FFFF  port $08 bit 6 and colour fitted -> colour RAM
//                otherwise                        -> PCG bank port1c[3:0]
//
// Note the asymmetry on attribute writes: `if (BIT(m_1c,4))` then discard
// unless `BIT(m_1c,7)`. So with d4 set and d7 clear the write goes NOWHERE -
// it is not redirected to screen RAM. That is deliberate in MAME ("non-premium
// attribute writes are discarded") and reproduced here.
wire sel_att_rd = extended & ((port1c & 8'h9F) == 8'h90);
wire sel_att_wr = port1c[4];
wire sel_col    = port08_cram & has_colour;

reg [7:0] cpu_scr_q, cpu_pcg_q, cpu_rom_q, cpu_att_q, cpu_col_q;

always @(posedge clk) begin
	if (cpu_wr) begin
		if (in_pcg) begin
			if (sel_col & ~latchrom) colram[cpu_addr[10:0]] <= cpu_din;
			else pcgram[{cpu_bank, cpu_addr[10:0]}] <= cpu_din;
		end
		else if (sel_att_wr) begin
			if (extended) attram[cpu_addr[10:0]] <= cpu_din;
		end
		else begin
			// Writes to the screen window always land in screen RAM even when
			// latchrom is redirecting reads to the character ROM.
			scrram[cpu_addr[10:0]] <= cpu_din;
		end
	end
	if (rom_wr) charrom[rom_addr] <= rom_din;

	cpu_scr_q <= scrram[cpu_addr[10:0]];
	cpu_pcg_q <= pcgram[{cpu_bank, cpu_addr[10:0]}];
	cpu_rom_q <= charrom[{alt_charset, cpu_addr[10:0]}];
	cpu_att_q <= attram[cpu_addr[10:0]];
	cpu_col_q <= colram[cpu_addr[10:0]];
end

reg in_pcg_r, latchrom_r, sel_att_rd_r, sel_col_r;
always @(posedge clk) begin
	in_pcg_r     <= in_pcg;
	latchrom_r   <= latchrom;
	sel_att_rd_r <= sel_att_rd;
	sel_col_r    <= sel_col;
end

always @(*) begin
	if (in_pcg_r)          cpu_dout = sel_col_r ? cpu_col_q : cpu_pcg_q;
	else if (sel_att_rd_r) cpu_dout = cpu_att_q;
	else if (latchrom_r)   cpu_dout = cpu_rom_q;
	else                   cpu_dout = cpu_scr_q;
end

//--------------------------------------------------------------------------
// Display fetch
//
// MA is stable for a whole character period (32 clk_sys), so a plain
// two-stage registered fetch settles long before the next ce_char. The
// shifter is loaded at ce_char with the byte for the character just fetched,
// which displays it one character later - DE and CURSOR are latched at the
// same instant so everything shifts together.
//--------------------------------------------------------------------------
// Flash counter. MAME toggles on bit 4 of a per-frame counter, so ~1.5 Hz at
// 50 Hz. Counted from vsync here.
reg [5:0] framecnt;
reg       frame_tick_r;
always @(posedge clk) begin
	frame_tick_r <= frame_tick;
	if (frame_tick & ~frame_tick_r) framecnt <= framecnt + 6'd1;
end

reg [7:0] scr_q, att_q, col_q;
reg [7:0] rom_q, pcg_q;
reg [7:0] col_q2, att_q2;
reg       chr_is_pcg;

// Attribute RAM supplies the PCG bank per cell (MAME: chr += (attr & 15) << 7,
// which is the same as indexing bank*2K within PCG RAM). Masked to 3 bits: the
// models we support fit 8 banks, not 16.
wire [2:0] pcg_bank = extended ? att_q[2:0] : 3'd0;

always @(posedge clk) begin
	// Stage 1 - everything indexed by the character address
	scr_q <= scrram[MA[10:0]];
	att_q <= attram[MA[10:0]];
	col_q <= colram[MA[10:0]];

	// Stage 2 - the glyph, plus the per-cell data carried alongside it
	rom_q      <= charrom[{alt_charset, scr_q[6:0], RA[3:0]}];
	pcg_q      <= pcgram[{pcg_bank, scr_q[6:0], RA[3:0]}];
	chr_is_pcg <= scr_q[7];
	col_q2     <= col_q;
	att_q2     <= att_q;
end

wire [7:0] gfx_raw = chr_is_pcg ? pcg_q : rom_q;

// Attribute effects, all Premium-only:
//   [6] inverse video, XORed with the cursor's own inversion
//   [7] flash - MAME substitutes character $20, we blank the glyph instead.
//       Identical on screen (space is blank in every MicroBee font) and it
//       avoids a second fetch, including under inverse where both give solid.
wire attr_inv   = extended & att_q2[6];
wire attr_flash = extended & att_q2[7] & framecnt[4];
wire [7:0] gfx  = attr_flash ? 8'h00 : gfx_raw;
wire       inv  = CURSOR ^ attr_inv;

//--------------------------------------------------------------------------
// Shifter
//--------------------------------------------------------------------------
reg [7:0] shifter;
reg       de_r;
reg [3:0] fg_r, bg_r;

always @(posedge clk) begin
	if (ce_char) begin
		// The cursor shows as an inverted character cell.
		shifter <= inv ? ~gfx : gfx;
		de_r    <= DE;
		// Colour RAM: low nibble foreground, high nibble background
		// (ubee512 vdu.c, the MODCOL2 branch).
		fg_r    <= col_q2[3:0];
		bg_r    <= col_q2[7:4];
	end
	else if (ce_pix) begin
		shifter <= {shifter[6:0], 1'b0};
	end
end

wire pixel = de_r & shifter[7];

//--------------------------------------------------------------------------
// Phosphor colour
//
// The 64K CIAB has no colour board fitted (ubee512 model table: colour=0), so
// the display is monochrome and the tube determines the colour. Values are
// MAME's mono palette entries 97-99 (mbee_v.cpp standard_palette).
//--------------------------------------------------------------------------
localparam [23:0] PH_GREEN = 24'h00FF00;
localparam [23:0] PH_AMBER = 24'hF7AA00;
localparam [23:0] PH_WHITE = 24'hFFFFFF;

reg [23:0] mono_fg;
always @(*) begin
	case (phosphor)
		2'd0:    mono_fg = PH_GREEN;
		2'd1:    mono_fg = PH_AMBER;
		default: mono_fg = PH_WHITE;
	endcase
end

//--------------------------------------------------------------------------
// Premium palette
//
// The Alpha Plus board does NOT generate colours. Sheet 1 of 8501-2-01 shows
// IC32 (HCT574) driving five lines - S, R, G, B, H - to both the TTL COLOUR
// and ANALOG COLOUR connectors: sync plus 4-bit RGBI. There is no palette RAM,
// no PROM and no per-gun DAC on the board. The monitor decides what those four
// bits look like, so the correct palette is a CGA-style RGBI monitor's.
//
// These values are ubee512's `col_table_p` (vdu.c), whose own comment says they
// "have been determined from the Alpha+ circuit diagram" - the same drawing.
// Levels are the CGA set: $55 low, $AA half, $FF full.
//
// Index is IBGR: [0] red, [1] green, [2] blue, [3] intensity.
//
// Brown (3) is deliberately $AA5500 rather than $AAAA00. That is the standard
// RGBI monitor behaviour - low-intensity yellow looks bad, so monitors pull the
// green down - and since the colour is entirely the monitor's interpretation
// here, it belongs in this table.
//
// Do NOT take this from MAME's premium_palette. It zeroes the unset guns on
// 9-15, so light red comes out $FF0000 where an RGBI monitor gives $FF5555,
// and its `for (i = 0; i < 7; i++)` never assigns index 7 at all.
reg [23:0] pal;
always @(*) begin
	case (fg_sel)
		4'h0: pal = 24'h000000;  // black
		4'h1: pal = 24'hAA0000;  // red
		4'h2: pal = 24'h00AA00;  // green
		4'h3: pal = 24'hAA5500;  // brown
		4'h4: pal = 24'h0000AA;  // blue
		4'h5: pal = 24'hAA00AA;  // magenta
		4'h6: pal = 24'h00AAAA;  // cyan
		4'h7: pal = 24'hAAAAAA;  // light grey
		4'h8: pal = 24'h555555;  // dark grey
		4'h9: pal = 24'hFF5555;  // light red
		4'hA: pal = 24'h55FF55;  // light green
		4'hB: pal = 24'hFFFF55;  // yellow
		4'hC: pal = 24'h5555FF;  // light blue
		4'hD: pal = 24'hFF55FF;  // light magenta
		4'hE: pal = 24'h55FFFF;  // light cyan
		default: pal = 24'hFFFFFF; // white
	endcase
end

// Which nibble the pixel selects, and what a mono machine does instead.
wire [3:0] fg_sel = pixel ? fg_r : bg_r;

wire [23:0] rgb_colour = de_r ? pal : 24'h000000;
wire [23:0] rgb_mono   = pixel ? mono_fg : 24'h000000;
wire [23:0] rgb        = (has_colour & use_colour) ? rgb_colour : rgb_mono;

always @(*) begin
	R = rgb[23:16];
	G = rgb[15:8];
	B = rgb[7:0];
end

endmodule
