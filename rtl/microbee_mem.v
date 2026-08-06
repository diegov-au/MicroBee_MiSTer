//============================================================================
// microbee_mem - MicroBee DRAM-model memory map decode (port 0x50).
//
// Implements the Series-3 banked memory map as used by the 64K CIAB and the
// 128K SBC. These two machines differ *only* in fitted DRAM size (ubee512
// src/ubee512.c:579 model table - the `64k` and `128k` rows are identical
// apart from `ram`), and the 32K IC is the unbanked case with no port $50 at
// all. Both axes are runtime inputs (`ram_size`, `banked`) rather than
// parameters, because one core serves every model.
//
// The decode is taken from ubee512 src/memmap.c:1029 dram_map_configure(),
// set_video_banked_handler() and set_roms_dram_handler(), and independently
// cross-checked against FPGABee Hardware/FPGABeeCore/FpgaBeeCore.vhd:689-772.
// Both agree. (MAME's mbee128 derives the same map by reading an undumped PAL,
// which is why that driver is marked NOT_WORKING - it is a MAME artifact, not
// a hardware unknown.)
//
// Port 0x50 bits:
//   [1:0] DRAM block select ("blocksel"), bit 1 inverted when NOROMS is set
//   [2]   NOROMS  - 1 = all ROMs out of the map
//   [3]   VRAM    - 1 = video RAM disabled
//   [4]   VADD    - 1 = video at 0x8000-0x8FFF, 0 = video at 0xF000-0xFFFF
//   [5]   ROM3    - 1 = ROM3 at 0xE000 + ROM3x at 0xC000, 0 = ROM2 at 0xC000
//
// Decode precedence, highest first (matches ubee512's handler insertion order):
//   1. video RAM window
//   2. ROM1 at 0x8000-0xBFFF
//   3. ROM3/ROM3x or ROM2 at 0xC000-0xFFFF
//   4. DRAM
//
// On a 64K machine, setting p50[0] selects the second 32K block, which is not
// fitted: reads return 0x00 and writes are dropped (ubee512 memmap_read_lo_z /
// memmap_write_lo_z, added in v5.7.0 after testing against real hardware).
//
// Reset state is p50 = 0 => ROMs in, video at 0xF000, block 0, so the CPU
// starts executing ROM1 at 0x8000 (model table bootaddr).
//============================================================================

module microbee_mem (
	input             clk,
	input             reset,

	// The port-$50 map register is fitted (microbee_models `banked`). Low on the
	// 32K IC, which physically has no such port - see "Unbanked models" below.
	input             banked,

	// Fitted DRAM, from the model table. 0 = 32K, 1 = 64K, 2 = 128K.
	// Runtime, not a parameter - see "Fitted DRAM" below.
	input       [1:0] ram_size,

	// CPU bus
	input      [15:0] cpu_addr,
	input             cpu_mreq,     // active high
	input             cpu_rd,
	input             cpu_wr,

	// port 0x50 write strobe
	input             p50_wr,
	input       [7:0] p50_din,

	// opcode fetch from the top half of the map - drops the boot overlay
	input             m1_fetch_hi,

	// decoded selects (combinational, valid with cpu_addr)
	output            sel_vram,     // video RAM window (screen/PCG/attr/colour)
	output            sel_rom,      // ROM is the read source
	output            sel_dram,     // DRAM is the read source
	output            wr_dram,      // writes at this address land in DRAM
	output            dram_dead,    // DRAM addressed but not fitted -> read 0, drop write

	// translated addresses
	output     [11:0] vram_addr,    // offset within the 4K video window
	output     [14:0] rom_addr,     // offset within the 32K ROM space (ROM1/2/3)
	output     [17:0] dram_addr,    // physical DRAM byte address

	output reg  [7:0] port50
);

//--------------------------------------------------------------------------
// Port 0x50 register
//--------------------------------------------------------------------------
// Boot overlay
// ------------
// The Z80 resets to $0000 but the boot ROM lives at $8000, so reset must also
// make ROM1 readable low. Two independent ROMs corroborate this:
//
//   bn54 (CIAB)     entry code is entirely position-independent and copies a
//                   5-byte stub (`OUT ($50),A / JP $E000`) to $FFFB, jumping
//                   there *before* its first ever port-0x50 write - precisely
//                   so the map can change out from under it safely.
//   PC/PC85 BASIC   starts with a jump table whose first entry is JP $84C6,
//                   i.e. it escapes into $8000-space on the very first
//                   instruction.
//
// Neither MAME nor ubee512 model this; both just force PC=$8000 at reset
// (MAME machine_reset() set_pc(m_size), ubee512 z80api_reset()). That shortcut
// isn't available in hardware, so the overlay has to be real.
//
// INFERRED: the exact clear condition isn't documented anywhere I could find.
// We drop the overlay on the first opcode fetch from the top half of the map,
// which is the point at which every known ROM has escaped into its own window,
// and also on any port-0x50 write. For bn54 the first such fetch is $FFFB -
// immediately before its OUT ($50) - so behaviour there is unchanged. For a
// ROM-model BASIC, which never touches port 0x50, this is what hands $0000-
// $7FFF back to RAM.
reg boot_overlay /* verilator public_flat_rw */;

always @(posedge clk) begin
	if (reset) begin
		port50       <= 8'h00;
		boot_overlay <= 1'b1;
	end
	else begin
		// `banked`: an unbanked machine has no $50 latch to clock, so the write
		// does not land AND does not drop the overlay either - a write to a port
		// that is not decoded is not an event. The IC gets out of the overlay the
		// other way, on its first high opcode fetch: BASIC's entry is a jump table
		// whose first entry is JP $84C6.
		if (banked & p50_wr) begin
			port50       <= p50_din;
			boot_overlay <= 1'b0;
		end
		if (m1_fetch_hi) boot_overlay <= 1'b0;
	end
end

//--------------------------------------------------------------------------
// Unbanked models - the 32K IC
//--------------------------------------------------------------------------
// The IC has no port $50 at all (PLAN M7-3; the 8328 PAK core board carries no
// map latch, where the 8312 disk board has IC31, a 74LS174 clocked by the $50
// decode - NOTES 6). Its map is fixed: 32K DRAM at $0000-$7FFF, ROM1 at $8000,
// PAK at $C000, NET at $E000, video at $F000.
//
// That is what `p50 = 0` already produces, which is why the IC has booted
// correctly since M7-3 - but it was correct only because nothing happened to
// write the register. `OUT (&50),n` typed at the BASIC prompt moved our map
// where real hardware would ignore the write entirely; measured before the fix,
// `OUT 80,255` left port50=FF and killed the machine dead.
//
// So it is pinned twice over, deliberately: the register cannot be written
// above, and every decode below reads `p50` rather than `port50`. Either alone
// would do; both together mean a future edit has to defeat two things to
// reintroduce this.
wire [7:0] p50 = banked ? port50 : 8'h00;

wire noroms = p50[2];
wire novram = p50[3];
wire vadd   = p50[4];
wire rom3   = p50[5];

// blocksel = p50[1:0], with bit 1 inverted when no ROMs are mapped.
// (memmap.c dram_map_configure(): `if (port50h & BANK_NOROMS) blocksel_x ^= 2`,
//  FpgaBeeCore.vhd:772: `(port_50(1) xor port_50(2)) & port_50(0)`)
wire [1:0] blocksel = {p50[1] ^ noroms, p50[0]};

//--------------------------------------------------------------------------
// Window decode
//--------------------------------------------------------------------------
wire [3:0] page = cpu_addr[15:12];

// 1. Video RAM: 0x8000-0x8FFF when VADD, else 0xF000-0xFFFF.
assign sel_vram = ~novram & ((vadd & (page == 4'h8)) | (~vadd & (page == 4'hF)));

// 2/3. ROM windows. ROM1 covers 0x8000-0xBFFF; the top 16K is either ROM2
// (0xC000-0xFFFF) or ROM3 at 0xE000 with ROM3x mirrored into 0xC000-0xDFFF.
wire in_rom1 = (cpu_addr[15:14] == 2'b10);   // 0x8000-0xBFFF
wire in_romhi = (cpu_addr[15:14] == 2'b11);  // 0xC000-0xFFFF
wire sel_rom_raw = ~noroms & (in_rom1 | in_romhi);

// Boot overlay: ROM1 also readable at 0x0000-0x3FFF until the first port-0x50
// write. Reads only - writes there still reach DRAM, which the boot ROM relies
// on for its LDIR into low memory.
wire in_overlay = boot_overlay & (cpu_addr[15:14] == 2'b00);

// Video wins over ROM.
assign sel_rom  = (sel_rom_raw | in_overlay) & ~sel_vram;
assign sel_dram = ~sel_vram & ~sel_rom;
assign wr_dram  = ~sel_vram & ~sel_rom_raw;

//--------------------------------------------------------------------------
// Address translation
//--------------------------------------------------------------------------
assign vram_addr = cpu_addr[11:0];

// ROM space is laid out as three 16K images in one 48K region, but the CPU
// only ever sees 32K of it at a time:
//   0x0000-0x3FFF ROM1  (bn54/bn56 boot ROM, 8K image mirrored into 16K)
//   0x4000-0x7FFF ROM2 or ROM3/ROM3x
assign rom_addr = (in_rom1 | in_overlay) ? {1'b0, cpu_addr[13:0]}
                          : {1'b1, rom3 ? {1'b1, cpu_addr[12:0]}   // ROM3 / ROM3x
                                        : cpu_addr[13:0]};          // ROM2

// DRAM is a set of 32K blocks.
//   $8000-$FFFF  ALWAYS block 0   (memmap.c memmap_read_hi: `block00[addr & 0x7FFF]`)
//   $0000-$7FFF  block[blocksel]  (memmap.c memmap_read_lo: `block_ptrs[blocksel_x]`)
//
// So the high window is fixed and the low window is the banked one. The boot
// ROM depends on this: it copies 4K to $6000 with blocksel=0, then sets NOROMS
// (making blocksel=2) and jumps to $E000. $6000 low and $E000 high are the same
// physical bytes - block 0 offset $6000 - which is how the loader survives the
// bank switch.
//
//--------------------------------------------------------------------------
// Fitted DRAM - runtime, not a parameter (M7-4)
//--------------------------------------------------------------------------
// This was a `generate` on a RAM_KB parameter until M7-4, producing two whole
// different decodes (gen_map_64k / gen_map_full) from a build-time constant. One
// core serves every model, so a parameter could not express "128K on p128k, 64K
// on the CIAB, 32K on the IC" - which is why the IC ran with 64K fitted right
// through M7-3. The array in microbee_core is now sized to the build maximum and
// the decode selected here from the model table.
//
//   ram_size  low window $0000-$7FFF
//   --------  --------------------------------------------------------------
//   0  32K    block 0 always. The IC is unbanked and p50 is pinned to 0, so
//             blocksel cannot move anyway - this is belt and braces. Its high
//             window is never DRAM at all: $8000-$BFFF is ROM1, $C000-$EFFF the
//             PAK/NET ROMs and $F000-$FFFF video, so sel_dram is false there.
//   1  64K    block 0 or 1. Only blocksel[1] is decoded; blocksel[0] selects the
//             32K that is not fitted, which reads 0 and swallows writes
//             (ubee512 memmap_read_lo_z / memmap_write_lo_z, added in v5.7.0
//             after testing against real hardware).
//   2  128K   all four blocks, blocksel straight through.
//
// The high window $8000-$FFFF is ALWAYS block 0 on every size (memmap.c
// memmap_read_hi: `block00[addr & 0x7FFF]`), which is what lets the CIAB boot
// ROM survive its own bank switch - see the note above.
localparam RAM_32K  = 2'd0;
localparam RAM_64K  = 2'd1;
localparam RAM_128K = 2'd2;

// Block index for the low window. Written so the 64K case is bit-identical to
// the decode it replaces: {1'b0, 1'b0, blocksel[1]} was {2'b00, blocksel[1]}.
reg [1:0] lo_block;
always @* begin
	case (ram_size)
		RAM_128K: lo_block = blocksel;
		RAM_64K:  lo_block = {1'b0, blocksel[1]};
		default:  lo_block = 2'b00;              // RAM_32K
	endcase
end

assign dram_addr = cpu_addr[15] ? {3'b000, cpu_addr[14:0]}
                                : {1'b0, lo_block, cpu_addr[14:0]};

// Only the 64K machine has an unfitted half to fall into. 128K has all four
// blocks; 32K cannot move blocksel off 0.
assign dram_dead = (ram_size == RAM_64K) & sel_dram & ~cpu_addr[15] & p50[0];

// Silence unused-input warnings; these exist so callers can gate on the same
// signals the real bus does without extra plumbing.
wire _unused = &{1'b0, cpu_mreq, cpu_rd, cpu_wr, 1'b0};

endmodule
