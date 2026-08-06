//============================================================================
// microbee_kbd - 64-switch key matrix scanned through the 6545 light pen.
//
// The MicroBee has no keyboard controller. The matrix is wired into the CRTC's
// light-pen input: whenever the CRTC presents a scan address whose bits [9:4]
// select a key that is held down, the light pen strobes and that address is
// latched into R16/R17. The BIOS reads R16/R17 to find out which key it was.
//
// Two things present scan addresses, and both are needed:
//
//   1. The natural walk of MA during display refresh. The display is 64x16 =
//      1024 characters, so MA[9:4] covers all 64 matrix positions exactly once
//      per frame. MAME scans only when MA[3:0]==0 ("only scan once per row
//      instead of 16 times", mbee_v.cpp oldkb_scan) - the same set of
//      addresses, just without re-testing each key 16 times.
//
//   2. An explicit strobe: the CPU writes a scan address to R18/R19 and then
//      touches R31. This is how the BIOS tests one specific key.
//
// Port $0B gates path 1 only; path 2 works regardless. That asymmetry is in
// both references (MAME mbee_v.cpp oldkb_scan vs crtc_update_addr; ubee512
// keystd.c keystd_checkall vs keystd_handler), so it is deliberate.
//
// Matrix index = scan_addr[9:4], i.e. address = index * 16. MAME decodes it as
// port=BIT(offs,7,3) / bit=BIT(offs,4,3), ubee512 as (addr >> 4) & 0x3F - the
// same thing. The full address is what gets latched, not the index.
//
// Matrix layout (MAME mbee.cpp INPUT_PORTS_START(oldkb), index = port*8+bit):
//
//    0 @    1 A    2 B    3 C    4 D    5 E    6 F    7 G
//    8 H    9 I   10 J   11 K   12 L   13 M   14 N   15 O
//   16 P   17 Q   18 R   19 S   20 T   21 U   22 V   23 W
//   24 X   25 Y   26 Z   27 [   28 \   29 ]   30 ^   31 DEL
//   32 0   33 1   34 2   35 3   36 4   37 5   38 6   39 7
//   40 8   41 9   42 :   43 ;   44 ,   45 -   46 .   47 /
//   48 ESC 49 BS  50 TAB 51 LF  52 CR  53 LOCK 54 BREAK 55 SPACE
//   56 UP  57 CTRL 58 DOWN 59 LEFT  60 -  61 -  62 RIGHT 63 SHIFT
//
// The base mapping is POSITIONAL: a PC key drives the MicroBee key in the same
// place, and the MicroBee ROM decides what character that produces. Faithful,
// but it means 15 of the 42 symbol-key combinations print something other than
// the keycap - measured, not assumed, by driving raw scan codes into BASIC
// 5.22e and reading screen RAM back (`--type-codes`).
//
// So `symbolic` adds a translation layer on top, the way ubee512 does: for the
// 21 symbol keys it looks up which MicroBee key produces the character on the
// PC keycap, and drives the Shift matrix position from that answer rather than
// from the real Shift key. Shift+2 then presses the MicroBee's '@' key with
// Shift RELEASED, and '@' comes out.
//
// What the layer deliberately does NOT touch, because software that reads the
// matrix directly must keep working - this is what the C64 maintainer objected
// to when a full PC map was proposed there:
//
//   - letters, Space, Enter, Esc, Tab, Backspace, Delete, cursor keys, Ctrl,
//     Lock and Break stay on their real matrix positions;
//   - Shift on its own is never synthesised. It is retargeted only while a
//     remapped symbol key is actually held down, and reverts the moment it is
//     released, so Shift-as-fire-button behaves normally.
//
// It assumes a US host layout, which is the one assumption the core cannot
// check: MiSTer hands cores raw PS/2 set-2 scan codes and never says what is
// printed on the keycaps. MiSTer's own remapping cannot substitute - it is
// system-wide and single-key-to-single-key with no macro support, so it cannot
// alter shift state, and Shift+2 -> '@' is exactly the case it cannot express.
//
// One combination is unreachable: no MicroBee key produces '_', so Shift+'-'
// is dead in symbolic mode. Silently printing '=' instead was the alternative,
// and a wrong character you do not notice is worse than a key that does
// nothing.
//
// In positional mode two MicroBee keys have no PC equivalent in the same place,
// so they follow MAME's choices: ':' sits on the PC ';' key and ';' on the PC
// quote key.
//============================================================================

module microbee_kbd
(
	input             clk,
	input             reset,

	// MiSTer hps_io format: [10] strobe (toggles per event), [9] pressed,
	// [8] extended (E0 prefix), [7:0] PS/2 set 2 scan code.
	input      [10:0] ps2_key,

	// 1 = symbol keys produce what the (US) keycap says, synthesising Shift.
	// 0 = pure positional, what the hardware itself does.
	input             symbolic,

	// Scan sources
	input             ce_char,
	input      [13:0] MA,
	input             DE,
	input             latchrom,       // port $0B bit 0 - gates the natural scan
	input      [13:0] update_addr,    // R18/R19
	input             update_strobe,  // 1-clk pulse on an R31 access

	// To the CRTC light pen
	output reg        lpen_set /* verilator public_flat_rw */,
	output reg [13:0] lpen_din
);

//--------------------------------------------------------------------------
// PS/2 decode
//--------------------------------------------------------------------------
reg        ps2_prev;
wire       ps2_stb  = ps2_key[10] ^ ps2_prev;
wire       pressed  = ps2_key[9];
wire       extended = ps2_key[8];
wire [7:0] code     = ps2_key[7:0];

always @(posedge clk) ps2_prev <= ps2_key[10];

reg [5:0] idx;
reg       idx_valid;

always @(*) begin
	idx       = 6'd0;
	idx_valid = 1'b1;

	case ({extended, code})
		// Letters
		9'h01C: idx = 6'd1;    // A
		9'h032: idx = 6'd2;    // B
		9'h021: idx = 6'd3;    // C
		9'h023: idx = 6'd4;    // D
		9'h024: idx = 6'd5;    // E
		9'h02B: idx = 6'd6;    // F
		9'h034: idx = 6'd7;    // G
		9'h033: idx = 6'd8;    // H
		9'h043: idx = 6'd9;    // I
		9'h03B: idx = 6'd10;   // J
		9'h042: idx = 6'd11;   // K
		9'h04B: idx = 6'd12;   // L
		9'h03A: idx = 6'd13;   // M
		9'h031: idx = 6'd14;   // N
		9'h044: idx = 6'd15;   // O
		9'h04D: idx = 6'd16;   // P
		9'h015: idx = 6'd17;   // Q
		9'h02D: idx = 6'd18;   // R
		9'h01B: idx = 6'd19;   // S
		9'h02C: idx = 6'd20;   // T
		9'h03C: idx = 6'd21;   // U
		9'h02A: idx = 6'd22;   // V
		9'h01D: idx = 6'd23;   // W
		9'h022: idx = 6'd24;   // X
		9'h035: idx = 6'd25;   // Y
		9'h01A: idx = 6'd26;   // Z

		// Symbols. '@' takes the PC grave key (the MicroBee '@' key produces
		// @ and `, so the keycaps line up); '^' takes the PC '=' key, the only
		// symbol key left over.
		9'h00E: idx = 6'd0;    // ` -> @
		9'h054: idx = 6'd27;   // [
		9'h05D: idx = 6'd28;   // backslash
		9'h05B: idx = 6'd29;   // ]
		9'h055: idx = 6'd30;   // = -> ^
		9'h04C: idx = 6'd42;   // ; -> :   (MAME KEYCODE_COLON)
		9'h052: idx = 6'd43;   // ' -> ;   (MAME KEYCODE_QUOTE)
		9'h041: idx = 6'd44;   // ,
		9'h04E: idx = 6'd45;   // -
		9'h049: idx = 6'd46;   // .
		9'h04A: idx = 6'd47;   // /

		// Digits
		9'h045: idx = 6'd32;   // 0
		9'h016: idx = 6'd33;   // 1
		9'h01E: idx = 6'd34;   // 2
		9'h026: idx = 6'd35;   // 3
		9'h025: idx = 6'd36;   // 4
		9'h02E: idx = 6'd37;   // 5
		9'h036: idx = 6'd38;   // 6
		9'h03D: idx = 6'd39;   // 7
		9'h03E: idx = 6'd40;   // 8
		9'h046: idx = 6'd41;   // 9

		// Control keys
		9'h076: idx = 6'd48;   // Esc
		9'h066: idx = 6'd49;   // Backspace
		9'h00D: idx = 6'd50;   // Tab
		9'h16C: idx = 6'd51;   // Home      -> Linefeed
		9'h05A: idx = 6'd52;   // Enter
		9'h058: idx = 6'd53;   // Caps Lock -> Lock
		9'h169: idx = 6'd54;   // End       -> Break
		9'h029: idx = 6'd55;   // Space
		9'h171: idx = 6'd31;   // Delete

		// Modifiers - left and right drive the same matrix position
		9'h014: idx = 6'd57;   // Left Ctrl
		9'h114: idx = 6'd57;   // Right Ctrl
		9'h012: idx = 6'd63;   // Left Shift
		9'h059: idx = 6'd63;   // Right Shift

		// Cursor keys. These positions only exist on Premium keyboards, but
		// they are real matrix slots on the old keyboard too, so a ROM that
		// knows about them will find them here.
		9'h175: idx = 6'd56;   // Up
		9'h172: idx = 6'd58;   // Down
		9'h16B: idx = 6'd59;   // Left
		9'h174: idx = 6'd62;   // Right

		default: idx_valid = 1'b0;
	endcase
end

//--------------------------------------------------------------------------
// Symbolic remap
//
// sym_id numbers the 21 symbol keys in the order they appear on a US board.
// The target table below was built from measurement: every one of these keys
// was driven by raw scan code into BASIC and the resulting character read out
// of screen RAM, so `tgt_idx`/`tgt_shift` is what the ROM actually does, not
// what the ASCII-63 pattern suggests it ought to.
//--------------------------------------------------------------------------
localparam SYM_NONE = 5'd31;

reg [4:0] sym_id;

always @(*) begin
	if (extended) sym_id = SYM_NONE;
	else case (code)
		8'h0E: sym_id = 5'd0;    // `
		8'h16: sym_id = 5'd1;    // 1
		8'h1E: sym_id = 5'd2;    // 2
		8'h26: sym_id = 5'd3;    // 3
		8'h25: sym_id = 5'd4;    // 4
		8'h2E: sym_id = 5'd5;    // 5
		8'h36: sym_id = 5'd6;    // 6
		8'h3D: sym_id = 5'd7;    // 7
		8'h3E: sym_id = 5'd8;    // 8
		8'h46: sym_id = 5'd9;    // 9
		8'h45: sym_id = 5'd10;   // 0
		8'h4E: sym_id = 5'd11;   // -
		8'h55: sym_id = 5'd12;   // =
		8'h54: sym_id = 5'd13;   // [
		8'h5B: sym_id = 5'd14;   // ]
		8'h5D: sym_id = 5'd15;   // backslash
		8'h4C: sym_id = 5'd16;   // ;
		8'h52: sym_id = 5'd17;   // '
		8'h41: sym_id = 5'd18;   // ,
		8'h49: sym_id = 5'd19;   // .
		8'h4A: sym_id = 5'd20;   // /
		default: sym_id = SYM_NONE;
	endcase
end

// Physical Shift, tracked separately from matrix position 63 because the
// remap has to be able to disagree with it.
reg shift_l, shift_r;
wire shift_real = shift_l | shift_r;

always @(posedge clk) begin
	if (reset) {shift_l, shift_r} <= 2'b00;
	else if (ps2_stb && !extended) begin
		if (code == 8'h12) shift_l <= pressed;
		if (code == 8'h59) shift_r <= pressed;
	end
end

// Which MicroBee key, and which Shift state, yields the character printed on
// this keycap. Matrix indices: 0 '@', 30 '^', 32-41 '0'-'9', 42 ':', 43 ';',
// 44 ',', 45 '-', 46 '.', 47 '/', 27 '[', 28 '\', 29 ']'.
reg [5:0] tgt_idx;
reg       tgt_shift;
reg       tgt_valid;

always @(*) begin
	tgt_idx   = 6'd0;
	tgt_shift = 1'b0;
	tgt_valid = 1'b1;

	case ({shift_real, sym_id})
		// Unshifted. Everything except `, =, ; and ' is already positional.
		{1'b0, 5'd0 }: begin tgt_idx = 6'd0;  tgt_shift = 1'b1; end // ` = Shift+@
		{1'b0, 5'd1 }: tgt_idx = 6'd33;                             // 1
		{1'b0, 5'd2 }: tgt_idx = 6'd34;                             // 2
		{1'b0, 5'd3 }: tgt_idx = 6'd35;                             // 3
		{1'b0, 5'd4 }: tgt_idx = 6'd36;                             // 4
		{1'b0, 5'd5 }: tgt_idx = 6'd37;                             // 5
		{1'b0, 5'd6 }: tgt_idx = 6'd38;                             // 6
		{1'b0, 5'd7 }: tgt_idx = 6'd39;                             // 7
		{1'b0, 5'd8 }: tgt_idx = 6'd40;                             // 8
		{1'b0, 5'd9 }: tgt_idx = 6'd41;                             // 9
		{1'b0, 5'd10}: tgt_idx = 6'd32;                             // 0
		{1'b0, 5'd11}: tgt_idx = 6'd45;                             // -
		{1'b0, 5'd12}: begin tgt_idx = 6'd45; tgt_shift = 1'b1; end // = is Shift+-
		{1'b0, 5'd13}: tgt_idx = 6'd27;                             // [
		{1'b0, 5'd14}: tgt_idx = 6'd29;                             // ]
		{1'b0, 5'd15}: tgt_idx = 6'd28;                             // backslash
		{1'b0, 5'd16}: tgt_idx = 6'd43;                             // ; sits on 43
		{1'b0, 5'd17}: begin tgt_idx = 6'd39; tgt_shift = 1'b1; end // ' is Shift+7
		{1'b0, 5'd18}: tgt_idx = 6'd44;                             // ,
		{1'b0, 5'd19}: tgt_idx = 6'd46;                             // .
		{1'b0, 5'd20}: tgt_idx = 6'd47;                             // /

		// Shifted.
		{1'b1, 5'd0 }: begin tgt_idx = 6'd30; tgt_shift = 1'b1; end // ~ = Shift+^
		{1'b1, 5'd1 }: begin tgt_idx = 6'd33; tgt_shift = 1'b1; end // !
		{1'b1, 5'd2 }: tgt_idx = 6'd0;                              // @ - Shift dropped
		{1'b1, 5'd3 }: begin tgt_idx = 6'd35; tgt_shift = 1'b1; end // #
		{1'b1, 5'd4 }: begin tgt_idx = 6'd36; tgt_shift = 1'b1; end // $
		{1'b1, 5'd5 }: begin tgt_idx = 6'd37; tgt_shift = 1'b1; end // %
		{1'b1, 5'd6 }: tgt_idx = 6'd30;                             // ^ - Shift dropped
		{1'b1, 5'd7 }: begin tgt_idx = 6'd38; tgt_shift = 1'b1; end // & = Shift+6
		{1'b1, 5'd8 }: begin tgt_idx = 6'd42; tgt_shift = 1'b1; end // * = Shift+:
		{1'b1, 5'd9 }: begin tgt_idx = 6'd40; tgt_shift = 1'b1; end // ( = Shift+8
		{1'b1, 5'd10}: begin tgt_idx = 6'd41; tgt_shift = 1'b1; end // ) = Shift+9
		{1'b1, 5'd11}: tgt_valid = 1'b0;                            // _ unreachable
		{1'b1, 5'd12}: begin tgt_idx = 6'd43; tgt_shift = 1'b1; end // + = Shift+;
		{1'b1, 5'd13}: begin tgt_idx = 6'd27; tgt_shift = 1'b1; end // {
		{1'b1, 5'd14}: begin tgt_idx = 6'd29; tgt_shift = 1'b1; end // }
		{1'b1, 5'd15}: begin tgt_idx = 6'd28; tgt_shift = 1'b1; end // |
		{1'b1, 5'd16}: tgt_idx = 6'd42;                             // : - Shift dropped
		{1'b1, 5'd17}: begin tgt_idx = 6'd34; tgt_shift = 1'b1; end // " = Shift+2
		{1'b1, 5'd18}: begin tgt_idx = 6'd44; tgt_shift = 1'b1; end // <
		{1'b1, 5'd19}: begin tgt_idx = 6'd46; tgt_shift = 1'b1; end // >
		{1'b1, 5'd20}: begin tgt_idx = 6'd47; tgt_shift = 1'b1; end // ?

		default: tgt_valid = 1'b0;
	endcase
end

wire remap = symbolic & (sym_id != SYM_NONE);

//--------------------------------------------------------------------------
// Matrix state
//--------------------------------------------------------------------------
reg [63:0] keys;

// Per-symbol-key bookkeeping. The release must clear the position the PRESS
// asserted, not the one the current Shift state would pick - otherwise
// releasing Shift before the key strands a matrix bit down forever.
reg [20:0] sym_down;
reg [20:0] sym_wants_shift;
reg  [5:0] sym_tgt [0:20];

integer i;

always @(posedge clk) begin
	if (reset) begin
		keys            <= 64'd0;
		sym_down        <= 21'd0;
		sym_wants_shift <= 21'd0;
		for (i = 0; i < 21; i = i + 1) sym_tgt[i] <= 6'd0;
	end
	else if (ps2_stb) begin
		if (remap) begin
			if (pressed) begin
				if (tgt_valid) begin
					keys[tgt_idx]              <= 1'b1;
					sym_tgt[sym_id[4:0]]       <= tgt_idx;
					sym_wants_shift[sym_id]    <= tgt_shift;
					sym_down[sym_id]           <= 1'b1;
				end
			end
			else if (sym_down[sym_id]) begin
				keys[sym_tgt[sym_id[4:0]]] <= 1'b0;
				sym_down[sym_id]           <= 1'b0;
			end
		end
		else if (idx_valid) keys[idx] <= pressed;
	end
end

// Shift is the one position the remap overrides, and only while a remapped key
// is down. On its own it is the physical key, so software reading the matrix
// for Shift-as-fire sees exactly what the user is holding.
wire        sym_active = |sym_down;
wire        sym_shift  = |(sym_down & sym_wants_shift);
wire [63:0] matrix     = (symbolic & sym_active) ? {sym_shift, keys[62:0]} : keys;

//--------------------------------------------------------------------------
// Scan
//
// The R31 strobe wins when both fire on the same clock - it is the CPU asking
// a direct question, and the natural scan will come round again next frame.
//--------------------------------------------------------------------------
// Public so the harness can count the two scan paths separately - either one
// working alone would hide the other being broken.
wire        natural /* verilator public_flat_rd */;
assign      natural   = ce_char & DE & ~latchrom & (MA[3:0] == 4'd0);
wire        scan_en   = update_strobe | natural;
wire [13:0] scan_addr = update_strobe ? update_addr : MA;

always @(posedge clk) begin
	if (reset) begin
		lpen_set <= 1'b0;
		lpen_din <= 14'd0;
	end
	else begin
		lpen_set <= 1'b0;
		if (scan_en && matrix[scan_addr[9:4]]) begin
			lpen_set <= 1'b1;
			lpen_din <= scan_addr;
		end
	end
end

endmodule
