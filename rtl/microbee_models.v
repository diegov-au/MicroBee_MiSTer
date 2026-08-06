//============================================================================
// microbee_models - the per-model feature table.
//
// One place where "which machine are we" turns into flags, so a model question
// is answered by a table row rather than by an `if` somewhere in the decode.
// Mirrors ubee512's model table at src/ubee512.c:579, which is the definitive
// per-model feature matrix (`alphap`, `rom`, `bootaddr`, `ram`, `pcg`, `colour`,
// `lpen`, `piob7`).
//
// M6 emits only the fields that have a consumer today. The remaining ubee512
// columns land here as M7 needs them, so that the table stays the single point
// of truth rather than growing a second one:
//
//   alphap     no port+$10 mirrors  M7-2 (Premium only)  - built
//   colour     colour + attributes  M7-2                 - built
//   banked     port $50 present     M7-3                 - built (session 8)
//   has_paknet PAK/NET ROM sockets  M7-3
//   ram_size   32 / 64 / 128        M7-4                 - built (session 8)
//
// `ram_size` used to carry a note saying it could not be an output at all:
// microbee_mem generated two different decodes from a RAM_KB *parameter* and the
// DRAM array was sized from it. M7-4 removed that constraint - the array is sized
// to the build maximum and the decode is selected at run time - so it is now an
// ordinary table column like the rest.
//
// ROM banks
// ---------
// `rom_bank` selects which 16K ROM1 image the machine runs, within the banked
// ROM1 array in microbee_core. The banks are filled from separate ioctl indices,
// which on MiSTer are separate `bootN.rom` files auto-loaded at startup:
//
//   bank 0  ioctl index 0  boot0.rom  64K CIAB boot ROM   (bn54)
//   bank 1  ioctl index 2  boot2.rom  ROM BASIC           (basic_5.22e.rom)
//   bank 2  ioctl index 3  boot3.rom  Premium boot ROM    (bn56) - M7-2 AND M7-4
//
// Bank 2 serves both Premium machines. Measured in session 4: P64K.ROM, P128K.ROM and
// bn56.rom are byte-identical (SHA1 cfae2069...1e6f), so 64K and 128K Premium differ
// by fitted RAM and model flags, not by boot ROM. Bank 3 is therefore free.
//
// ioctl index 1 is the character ROM, which every model shares - which is why
// the bank numbering skips it rather than starting at index 1.
//
// Bank 1 does double duty: it is the 32K IC's own ROM1 *and* what the disk
// models' "Boot ROM: BASIC" option selects. One image, one file, two uses.
//============================================================================

module microbee_models
(
	input      [2:0] model,

	// Boot the ROM BASIC image instead of the model's own ROM1. Only meaningful
	// on a disk model; the 32K IC already runs BASIC.
	input            boot_basic,

	output reg [1:0] rom_bank,
	output reg       has_fdc,

	// The port-$50 memory-map register is fitted (ubee512's `banked`). False on
	// the 32K IC, which physically has no such port: the 8328 PAK core board has
	// no 74LS174 map latch and no $50 decode at all, so a write there must be
	// swallowed by the address decoder rather than move anything.
	//
	// This has to be a model flag rather than "the IC never writes $50 anyway".
	// The IC's map was correct only because port50 happened to stay 0, so a
	// stray OUT (&50),n from BASIC moved our map where real hardware would
	// ignore it entirely. See microbee_mem.
	output reg       banked,

	// Fitted DRAM (ubee512's `ram`). The encoding is shared with microbee_mem,
	// which selects its low-window decode from it at run time:
	//
	//   2'd0 = 32K   unbanked, $0000-$7FFF only          - the IC
	//   2'd1 = 64K   two 32K blocks, the upper half of
	//                the block select is not fitted      - 64k, p64k
	//   2'd2 = 128K  all four blocks fitted              - p128k
	//
	// This was a `RAM_KB` *parameter* on microbee_mem until M7-4. It generated
	// two different decodes and sized the DRAM array, so per-model selection was
	// not expressible - which is why the IC ran with 64K fitted and why M7-4 is
	// where its 32K finally lands. The array is now sized to the build maximum
	// (128K) and the decode chosen from this field.
	output reg [1:0] ram_size,

	// ROM images fitted in the upper ROM window, $C000-$EFFF. True only on the
	// 32K IC, whose standard fit is BASIC 16K + WordBee 8K + Telcom 4K = 28K,
	// exactly $8000-$EFFF with video at $F000 (NOTES 5).
	//
	// It has to be a model flag rather than "read the ROM if one was loaded":
	// the CIAB has no ROM2/ROM3 fitted and its $C000-$FFFF window must keep
	// reading 0. Gating on the model is what keeps the frozen CIAB baseline
	// (STATUS) exactly where it is when boot4/boot5.rom are present.
	output reg       has_romhi,

	// PIO port B bit 7 source (ubee512's `piob7` field).
	//   0 = MODPB7_PUP, a pull-up that always reads 1 - the 64K CIAB
	//   1 = MODPB7_VS,  vsync, where ROM-BASIC models get their 50 Hz tick
	// Getting this wrong is not subtle: software monitoring bit 7 for a frame
	// tick sees a permanently-true condition and interrupts forever (NOTES 8
	// measured 268,580 acknowledgements in 400 frames).
	output reg       piob7_vs,

	// Alpha+ port map (ubee512 `alphap`). 0 = the low ports are mirrored at
	// port+$10; 1 = they are not, and $1C-$1F is the Premium video latch.
	output reg       alphap,

	// Colour + attribute RAM and 8 PCG banks fitted (ubee512 `colour`
	// MODCOL2 + `pcg` 8). Kept separate from `alphap` because ubee512 has them
	// as separate columns and they genuinely diverge - `1024k` is alphap=1
	// with colour=0, pcg=1 - even though every model WE support has them
	// agreeing.
	output reg       colour
);

//--------------------------------------------------------------------------
// The table
//--------------------------------------------------------------------------
// Only model 0 is implemented and offered in the OSD as of M6. The remaining
// rows are the M7 targets and are listed so the encoding is fixed now - the
// OSD's 3-bit field and the harness's --model share this numbering, and
// renumbering later would silently change what a saved config selects.
//
// Numbering follows M7's build order, and 0 stays where it was so a config
// saved by an M6 build still selects the same machine.
//
// Standard 128K was dropped in session 4 (PLAN M7-4): these four are the
// representative set, and plain 128k is p128k with the colour hardware taken
// out - reachable later by clearing flags, not worth an encoding now.
localparam MODEL_CIAB64 = 3'd0;   // M7-1  Series-3 banked, disk        (target)
localparam MODEL_P64K   = 3'd1;   // M7-2  Premium: colour + attributes
localparam MODEL_IC32   = 3'd2;   // M7-3  unbanked, ROM BASIC, no disk
localparam MODEL_P128K  = 3'd3;   // M7-4  Premium, banked 128K

// Transcribed from ubee512 src/ubee512.c:579, re-fetched and re-read in session
// 4 rather than recalled. The relevant columns:
//
//   model   ALPHAP  boot    FDC   RAM  PCG  COLOUR   LPEN  PIOB7
//   64k        0    0x8000  AT     64   1   0          1   MODPB7_PUP
//   p64k       1    0x8000  AT     64   8   MODCOL2    1   MODPB7_PUP
//   p128k      1    0x8000  AT    128   8   MODCOL2    1   MODPB7_PUP
//   ic         0    0x8000  (rom)  32   1   0          1   MODPB7_PUP
//
// p64k and p128k are identical apart from RAM, which is why one bn56 image and
// one Premium video implementation serve both.
reg [1:0] tbl_rom_bank;
reg       tbl_has_fdc;
reg       tbl_banked;
reg [1:0] tbl_ram_size;
reg       tbl_has_romhi;
reg       tbl_piob7_vs;
reg       tbl_alphap;
reg       tbl_colour;

always @* begin
	case (model)
		MODEL_P64K: begin
			tbl_rom_bank = 2'd2;
			tbl_has_fdc  = 1'b1;
			tbl_banked   = 1'b1;
			tbl_ram_size = 2'd1;   // 64K
			tbl_has_romhi= 1'b0;
			tbl_piob7_vs = 1'b0;
			tbl_alphap   = 1'b1;
			tbl_colour   = 1'b1;
		end
		MODEL_IC32: begin
			tbl_rom_bank = 2'd1;
			tbl_has_fdc  = 1'b0;
			// No port $50 at all - the one model where it is absent. Its map is
			// pinned in microbee_mem rather than left to depend on port50
			// happening to stay 0.
			tbl_banked   = 1'b0;
			// 32K, the second of M7-3's two unbuilt spec items. It could not be
			// set before M7-4 because RAM_KB was a generate parameter; per-model
			// selection IS this milestone. The IC ran with 64K fitted until now,
			// which was invisible - $8000-$EFFF is ROM and the extra RAM is
			// unreachable without the banking the IC does not have - but wrong.
			tbl_ram_size = 2'd0;
			// WordBee and Telcom, from slots 4 and 5. The only model with them.
			tbl_has_romhi= 1'b1;
			// ubee512 gives `ic` MODPB7_PUP, not MODPB7_VS. This row said vs=1
			// with the reasoning "ROM BASIC keeps time from vsync" - true of
			// pc85/pc/ppc85, which ARE MODPB7_VS, but not of the IC. Corrected
			// in session 4 against the re-fetched table; never shipped, since
			// no model but 0 has been selectable.
			tbl_piob7_vs = 1'b0;
			tbl_alphap   = 1'b0;
			tbl_colour   = 1'b0;
		end
		MODEL_P128K: begin
			tbl_rom_bank = 2'd2;   // same bn56 image as Premium 64K
			tbl_has_fdc  = 1'b1;
			tbl_banked   = 1'b1;
			tbl_ram_size = 2'd2;   // 128K - the whole point of the model
			tbl_has_romhi= 1'b0;
			tbl_piob7_vs = 1'b0;
			tbl_alphap   = 1'b1;
			tbl_colour   = 1'b1;
		end
		// MODEL_CIAB64 and every unimplemented encoding fall here, so an
		// out-of-range selection boots the target machine rather than a
		// machine with no ROM.
		default: begin
			tbl_rom_bank = 2'd0;
			tbl_has_fdc  = 1'b1;
			tbl_banked   = 1'b1;
			tbl_ram_size = 2'd1;   // 64K
			tbl_has_romhi= 1'b0;
			tbl_piob7_vs = 1'b0;   // MODPB7_PUP
			tbl_alphap   = 1'b0;
			tbl_colour   = 1'b0;
		end
	endcase
end

//--------------------------------------------------------------------------
// "Boot ROM: BASIC" override
//--------------------------------------------------------------------------
// Swaps ROM1 for the BASIC image and takes the vsync tick with it. The tick is
// not optional: BASIC monitors PIO B7 for its 50 Hz interrupt, so leaving the
// CIAB's pull-up in place would make the monitored condition permanently true.
//
// Worth being clear about what this models. On real hardware PIO B7 is wired to
// a pull-up on a CIAB whatever ROM sits in the socket, so this is a MicroBee
// with a BASIC ROM fitted *and* the vsync link made - essentially a PC85, not a
// configuration that shipped. It is a convenience that makes the core useful
// without a disk image; the faithful ROM-BASIC machine is MODEL_IC32.
// alphap and colour are NOT overridden - they describe the fitted hardware, and
// putting a different ROM in the socket does not add or remove a colour board.
always @* begin
	rom_bank = boot_basic ? 2'd1 : tbl_rom_bank;
	has_fdc  = tbl_has_fdc;
	// Not overridden either: a CIAB with a BASIC ROM in its socket still has the
	// port-$50 latch on its board. `banked` describes the fitted hardware, and so
	// does `ram_size` - swapping the ROM does not unsolder DRAM.
	banked   = tbl_banked;
	ram_size = tbl_ram_size;
	// Deliberately NOT overridden by boot_basic, for the same reason as alphap
	// and colour: putting a BASIC ROM in a CIAB's socket does not fit WordBee
	// and Telcom in the upper window. "Boot ROM: BASIC" is a CIAB running BASIC,
	// not an IC.
	has_romhi= tbl_has_romhi;
	piob7_vs = tbl_piob7_vs | boot_basic;
	alphap   = tbl_alphap;
	colour   = tbl_colour;
end

endmodule
