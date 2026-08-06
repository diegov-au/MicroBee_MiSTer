//============================================================================
// microbee_core - the MicroBee machine itself.
//
// Instantiated by both the Verilator harness (verilator/sim.v) and the MiSTer
// top level (microbee.sv), so everything MiSTer-specific stays outside.
//
// Target: 64K CIAB (Computer-in-a-Book). Fitted DRAM is per-model at run time
// since M7-4; RAM_MAX_KB only sizes the array. The 128K SBC, which
// per ubee512's model table differs only in fitted DRAM.
//
// Clocking: clk_sys is 54.0 MHz on hardware.
//   ce_cpu = /16 -> 3.375 MHz Z80   (13.5MHz xtal / 4, per MAME mbeeic)
//   ce_pix = /4  -> 13.5  MHz dot clock
//   ce_char= /32 -> 1.6875 MHz character clock (6545)
//
// The 13.5 MHz dot clock is the real machine's crystal (schematic G1). 54 MHz
// exists only because MiSTer's scandoubler derives a 4x pixel clock by measuring
// the ce_pix period and shifting it right by two (sys/scandoubler.v). Our
// simulation harness has no scandoubler, so it can clock at 13.5 MHz and
// evaluate the design a quarter as many times - see sim_fast below.
// (Do not start a comment line with the word "Verilator": it is parsed as a
// metacomment pragma and fails the build.)
//
// M1 scope: CPU + memory map + ROM download + debug taps. Video, keyboard,
// FDC, PIO and audio are stubbed and land in M2-M5.
//============================================================================

module microbee_core #(
	// The DRAM array is sized to the BUILD MAXIMUM, not to a machine. Which
	// machine is running selects the decode at run time (microbee_mem's
	// `ram_size`, from the model table), so one array serves 32K, 64K and 128K.
	// 128 is what M7-4 needs; nothing should lower it while p128k is selectable.
	parameter RAM_MAX_KB = 128,
	// 16K ROM1 images held at once, one per selectable machine. Bank 0 is the
	// CIAB boot ROM and bank 1 the ROM BASIC image, so M6 needs two; M7 raises
	// this as it adds models. See microbee_models.v for the bank map.
	parameter ROM1_BANKS = 2
) (
	input             clk_sys,
	input             reset,

	// Cold Boot - a ONE-SHOT, one clk_sys cycle. Zeroes the whole DRAM array,
	// which is the difference between a reset and a power cycle on this machine:
	// a reset leaves BASIC's program and pointers exactly where they were, so a
	// machine-code game that has taken the machine over leaves no prompt to type
	// NEW at. The real MicroBee reaches the same state with ESC held during
	// RESET; we have no RESET key to hold, so it is an OSD entry.
	//
	// The caller must hold the machine in reset for the duration - assert its
	// core reset from `dram_clearing` below, the same way `disk_prepare` is
	// handled. A re-trigger while a clear is running is ignored rather than
	// restarting it, so a caller that mistakenly supplies a LEVEL stalls for one
	// clear instead of pinning the machine in reset forever.
	input             cold_boot,
	// High while the DRAM array is being zeroed. ~2.4 ms at 54 MHz for 128K.
	output            dram_clearing,

	// ROM download. The bootN.rom slot number is ioctl_index[15:6] - see the
	// decode below, and NOTES 12 for why the low bits are the wrong place to
	// look. Slot 0 -> ROM1 bank 0, 1 -> char ROM, 2.. -> ROM1 banks 1..
	input             ioctl_download,
	input             ioctl_wr,
	input      [24:0] ioctl_addr,
	input       [7:0] ioctl_dout,
	input      [15:0] ioctl_index,

	// Keyboard (scanned through the CRTC light pen)
	input      [10:0] ps2_key,

	// 1 = symbol keys produce what the US keycap says; 0 = pure positional.
	// Safe to change while running - it only affects the next key event.
	input             kbd_symbolic,

	// Which machine. Latch this at reset in the caller and hold the core in
	// reset across a change - the memory map cannot move under a running Z80.
	input       [2:0] model,

	// Boot the ROM BASIC image instead of the model's own ROM1. Same rule.
	input             boot_basic,

	// Force vsync onto PIO port B bit 7 regardless of the model. This is a
	// harness override for isolating that variable (--piob7-vsync); on MiSTer
	// tie it low and let the model table decide.
	input             piob7_vs,

`ifdef SIMULATION
	// Harness master-clock select (--fast): 1 = clk_sys is the 13.5 MHz dot
	// rate, 0 = the 54 MHz hardware rate. A real input rather than an internal
	// reg because Verilator constant-folds a reg that has an initial value and
	// no Verilog driver, even with public_flat_rw - which silently produced a
	// build where the C++ reported 13.5 MHz while the dividers never changed.
	// Driven every edge from sim_main.cpp, exactly like model and piob7_vs.
	input             sim_fast,
`endif

	// Floppy - block device interface to hps_io / SimBlockDevice
	output     [31:0] sd_lba,
	output            sd_rd,
	output            sd_wr,
	input             sd_ack,
	input       [8:0] sd_buff_addr,
	input       [7:0] sd_buff_dout,
	output      [7:0] sd_buff_din,
	input             sd_buff_wr,
	input             img_mounted,
	input             img_readonly,
	input      [31:0] img_size,

	// Cassette (M8-1) - its own block device, mounted separately from the
	// floppy. LOAD only; nothing writes back, so there is no sd_wr here.
	input             tape_mounted,
	input      [31:0] tape_size,
	output     [31:0] tape_lba,
	output            tape_rd,
	input             tape_ack,
	input       [8:0] tape_buff_addr,
	input       [7:0] tape_buff_dout,
	input             tape_buff_wr,
	input             tape_rewind,   // one-shot
	input             tape_audio_en,
	output            tape_playing,
	output     [31:0] tape_bytes,
	output     [31:0] tape_stalls,
	output     [31:0] tape_fetches,

	// Raw-image geometry. 1 = ss80, sectors linear by track; 0 = ds40/ds80,
	// which interleave sides. Size alone cannot tell ss80 from ds40 - both are
	// 409600 bytes - so this has to be supplied out of band.
	//
	// It has no effect on a .dsk: those parse to var_size=1, where the sector
	// address comes from the image's own table (`buff_a = edsk_offset`) and the
	// layout term is not used at all.
	input             disk_layout,
	// High while a mounted image is being scanned. The caller must keep the
	// machine in reset for the duration - see the note at the wd1793 instance.
	output            disk_prepare,

	// Controller busy - spans a whole command, so it is what a drive-activity
	// LED wants rather than the individual block transfers.
	output            disk_busy,

	// Video
	input       [1:0] phosphor,     // 0 = green, 1 = amber, 2 = white

	// Render in colour rather than on a phosphor. Only does anything on a model
	// with the colour hardware fitted - a mono machine ignores it, which is why
	// the caller can leave it high without checking the model.
	input             use_colour,
	output            ce_pix,
	output            hsync,
	output            vsync,
	output            hblank,
	output            vblank,

	// Active area in pixels, for the caller's VIDEO_ARX/ARY. Changes at runtime
	// when software reprograms the CRTC, so a fixed aspect cannot be right.
	// 12 bits: rows x row height reaches 127 x 32 = 4064 if software programs
	// something extreme, which does not fit in 11.
	output     [11:0] active_w,
	output     [11:0] active_h,
	output      [7:0] R,
	output      [7:0] G,
	output      [7:0] B,

	// Audio - the PIO's port B bit 6 speaker (M5)
	output signed [15:0] audio,

	// From the model table, so the caller can hide disk options on a machine
	// that has no controller rather than duplicating the table.
	output            model_has_fdc,
	// ROMs fitted in the upper window ($C000-$EFFF) - the 32K IC only. Exported
	// so microbee.sv can gate its boot4/boot5 warnings without keeping a second
	// copy of the model table.
	output            model_has_romhi,

	// Debug taps for the Verilator harness
	output     [15:0] dbg_pc,
	output      [7:0] dbg_opcode,
	output            dbg_fetch,     // 1 on the cycle an opcode fetch completes
	output     [15:0] dbg_addr,
	output      [7:0] dbg_din,
	output      [7:0] dbg_dout,
	output            dbg_mreq,
	output            dbg_iorq,
	output            dbg_rd,
	output            dbg_wr,
	output      [7:0] dbg_port50
);

localparam DRAM_BYTES = RAM_MAX_KB * 1024;
localparam DRAM_AW    = (RAM_MAX_KB == 128) ? 17 : 16;

//--------------------------------------------------------------------------
// Clock enables
//--------------------------------------------------------------------------
reg [4:0] clkdiv = 0;
always @(posedge clk_sys) clkdiv <= clkdiv + 1'd1;

// SYNTHESIS PATH IS BELOW THE `else`, AND IS THE ORIGINAL SOURCE VERBATIM.
// Quartus never defines SIMULATION, so it compiles exactly the three lines that
// built the stable alpha - not a rewrite that happens to be equivalent. Keep it
// that way: if the enables ever need to change, change them there and let the
// simulation branch follow, never the other way round.
`ifdef SIMULATION
// The harness picks its master clock at run time (--fast) so one binary covers
// both rates. Masks rather than bit slices, because the 13.5 MHz case needs
// ce_pix to collapse to a constant 1 and a part-select cannot express that.
// 3 / 15 / 31 reproduce clkdiv[1:0], clkdiv[3:0] and clkdiv[4:0] exactly.
wire [4:0] MASK_PIX  = sim_fast ? 5'd0 : 5'd3;
wire [4:0] MASK_CPU  = sim_fast ? 5'd3 : 5'd15;
wire [4:0] MASK_CHAR = sim_fast ? 5'd7 : 5'd31;

wire ce_cpu   = (clkdiv & MASK_CPU)  == 5'd0;   // dot / 4 -> 3.375 MHz Z80
wire ce_char  = (clkdiv & MASK_CHAR) == 5'd0;   // dot / 8 -> 1.6875 MHz char clock
assign ce_pix = (clkdiv & MASK_PIX)  == 5'd0;   // dot clock itself
`else
wire ce_cpu   = (clkdiv[3:0] == 4'd0);   // 3.375 MHz Z80
wire ce_char  = (clkdiv[4:0] == 5'd0);   // 1.6875 MHz character clock
assign ce_pix = (clkdiv[1:0] == 2'd0);   // 13.5 MHz dot clock
`endif

//--------------------------------------------------------------------------
// Model feature table
//--------------------------------------------------------------------------
// Combinational; the caller is responsible for holding the core in reset while
// `model` or `boot_basic` changes.
wire model_piob7_vs;
wire model_alphap;
wire model_colour;
wire model_banked;
wire [1:0] model_ram_size;

microbee_models models
(
	.model      (model),
	.boot_basic (boot_basic),
	.rom_bank   (rom1_bank),
	.has_fdc    (model_has_fdc),
	.banked     (model_banked),
	.ram_size   (model_ram_size),
	.has_romhi  (model_has_romhi),
	.piob7_vs   (model_piob7_vs),
	.alphap     (model_alphap),
	.colour     (model_colour)
);

// The harness override is an OR, not a replacement, so --piob7-vsync can force
// the vsync tick on a model whose table row says pull-up.
wire piob7_vs_eff = piob7_vs | model_piob7_vs;

//--------------------------------------------------------------------------
// Z80
//--------------------------------------------------------------------------
wire [15:0] cpu_addr;
wire  [7:0] cpu_dout;
reg   [7:0] cpu_din;
wire        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;

tv80s_ce cpu
(
	.reset_n (~reset),
	.clk     (clk_sys),
	.cen     (ce_cpu),
	.wait_n  (1'b1),
	.int_n   (pio_int_n),
	.nmi_n   (1'b1),
	.busrq_n (1'b1),
	.m1_n    (m1_n),
	.mreq_n  (mreq_n),
	.iorq_n  (iorq_n),
	.rd_n    (rd_n),
	.wr_n    (wr_n),
	.rfsh_n  (rfsh_n),
	.halt_n  (),
	.busak_n (),
	.A       (cpu_addr),
	.di      (cpu_din),
	.dout    (cpu_dout)
);

// Refresh cycles assert mreq_n too; exclude them from real memory accesses.
wire mem_rd = ~mreq_n & ~rd_n & rfsh_n;
wire mem_wr = ~mreq_n & ~wr_n & rfsh_n;
wire m1_fetch = ~m1_n & ~mreq_n & ~rd_n & rfsh_n;
wire io_rd  = ~iorq_n & ~rd_n & m1_n;   // m1_n excludes interrupt acknowledge
wire io_wr  = ~iorq_n & ~wr_n & m1_n;

// One strobe per I/O cycle. iorq/wr stay asserted for several T-states, so
// gating on ce_cpu alone would fire two or three times - which matters for
// side effects like the CRTC's R31 update strobe.
reg io_wr_d, io_rd_d;
always @(posedge clk_sys) begin
	io_wr_d <= io_wr;
	io_rd_d <= io_rd;
end
wire io_wr_stb = io_wr & ~io_wr_d;
wire io_rd_stb = io_rd & ~io_rd_d;

//--------------------------------------------------------------------------
// I/O port decode
//
// This is a "standard" (non-Alpha+) model, so ports are also mirrored at
// port+0x10 (ubee512 z80.c z80_ports_set(), the else branch). Only the low
// 8 bits of the address are decoded.
//--------------------------------------------------------------------------
wire [7:0] pa = cpu_addr[7:0];

// Standard (non-Alpha+) models mirror the low ports at port+0x10, so pa[4] is
// a don't-care across $00-$1F (ubee512 z80.c z80_ports_set, else branch).
//
// Alpha+ models do NOT mirror, which is what frees $1C-$1F for the Premium
// video latch. `mirr` is the qualifier: on a standard machine it is always
// true, so pa[4] stays a don't-care and the decode below is unchanged.
//
// The two references disagree on the detail and it is worth knowing which we
// followed. ubee512 (z80.c, the `if (modelx.alphap)` branch) drops the whole
// $10-$1F mirror block and maps $1C-$1F to vdu_lvdat. MAME's mbeeppc_io keeps
// .mirror(0xff10) on the PIO, $08, $0A, $0B and even $0D, removing it only
// from $0C so that $1C can be the latch. We follow **ubee512**, as we did for
// the CRTC auto-increment question - our model table mirrors its structure.
// Both agree on the part that matters: $1C is the video latch on Alpha+ and
// aliases the CRTC on standard.
wire port_lo = (pa[7:5] == 3'b000);                // $00-$1F
wire mirr    = ~model_alphap | ~pa[4];             // the mirrorable window

wire crtc_sel   = port_lo & mirr & (pa[3:2] == 2'b11);  // $0C-$0F (+$1C-$1F if standard)
wire latch_sel  = port_lo & mirr & (pa[3:0] == 4'hB);   // $0B (+$1B if standard)
wire pio_sel    = port_lo & mirr & (pa[3:2] == 2'b00);  // $00-$03 (+$10-$13 if standard)
wire port50_sel = (pa[7:3] == 5'b01010);                // $50-$57

// Premium video latch, Alpha+ only. ubee512 maps all four of $1C-$1F to it.
wire vlatch_sel = port_lo & model_alphap & pa[4] & (pa[3:2] == 2'b11);

// Port $08 - the colour latch. Present on every colour machine, not just
// Alpha+, which is why it is inside the mirrorable window.
wire port08_sel = port_lo & mirr & (pa[3:0] == 4'h8);

// FDC. $40-$47 is the WD2793 itself ($44-$47 mirrors $40-$43), $48-$4B is the
// board's own drive/side/density latch. Unlike the low ports these are NOT
// mirrored at +$10 - ubee512 gives the FDC exactly 12 ports (z80.c
// z80_ports_fdc_r), and $50 is the memory-map register, so they cannot be.
//
// Gated on the model, so a machine with no disk controller does not answer at
// all. That matters more than it looks: the CIAB boot ROM decides which BIOS to
// load from whether the sector register at $46 holds a written value (NOTES 2),
// so "no FDC" has to mean genuinely absent, not present-and-idle.
wire fdc_sel    = model_has_fdc & (pa[7:4] == 4'h4) & ~pa[3];   // $40-$47
wire fdc_ext_sel= model_has_fdc & (pa[7:2] == 6'b010010);       // $48-$4B

// Port $0B bit 0: latches the character ROM into the screen-RAM read window,
// and gates the keyboard scan (M3).
reg latchrom;
always @(posedge clk_sys) begin
	if (reset) latchrom <= 1'b0;
	else if (io_wr_stb & latch_sel) latchrom <= cpu_dout[0];
end

//--------------------------------------------------------------------------
// Port $1C - the Premium video latch (MAME mbee_v.cpp port1c_w)
//--------------------------------------------------------------------------
//   d7      extended graphics: 1 = attributes and PCG banks are live
//   d5      bankswitch the BASIC ROM  (ROM models only; not used here)
//   d4      select attribute RAM into the $F000-$F7FF window
//   d3:d0   PCG bank for the $F800-$FFFF window
//
// MAME's write rule, which is not the obvious one:
//
//     if (premium && BIT(data,7)) m_1c = data;
//     else                        m_1c = data & 0x30;
//
// So unless d7 is being set on a Premium machine, only d4 and d5 survive - the
// bank bits are discarded. That keeps a standard machine from ever selecting a
// PCG bank it does not have, and it is why `port1c` resets to 0.
reg [7:0] port1c;
always @(posedge clk_sys) begin
	if (reset) port1c <= 8'h00;
	else if (io_wr_stb & vlatch_sel)
		port1c <= (model_colour & cpu_dout[7]) ? cpu_dout : (cpu_dout & 8'h30);
end

//--------------------------------------------------------------------------
// Port $08 - the colour latch (MAME mbee_v.cpp port08_w)
//--------------------------------------------------------------------------
//   d6      select colour RAM into the $F800-$FFFF window
//   d3:d1   background colour modifier, standard colour board only
//
// MAME masks the write with $4E, keeping exactly bits 6, 3, 2 and 1. The
// MB1217 drawing agrees from the other direction: IC12, a 74LS175 clocked by
// PORT08, latches four bits - D6, D3, D2 and D1.
//
// Only d6 matters to us. d3:d1 belong to the MODCOL1 standard colour board,
// which is a different machine from the Premium we implement.
reg [7:0] port08;
always @(posedge clk_sys) begin
	if (reset) port08 <= 8'h00;
	else if (io_wr_stb & port08_sel) port08 <= cpu_dout & 8'h4E;
end

//--------------------------------------------------------------------------
// Memory map
//--------------------------------------------------------------------------
wire        sel_vram, sel_rom, sel_dram, wr_dram, dram_dead;
wire [11:0] vram_addr;
wire [14:0] rom_addr;
wire [17:0] dram_addr;
wire  [7:0] port50;

microbee_mem memmap
(
	.clk       (clk_sys),
	.reset     (reset),
	.banked    (model_banked),
	.ram_size  (model_ram_size),
	.cpu_addr  (cpu_addr),
	.cpu_mreq  (~mreq_n),
	.cpu_rd    (~rd_n),
	.cpu_wr    (~wr_n),
	.p50_wr      (io_wr_stb & port50_sel),
	.p50_din     (cpu_dout),
	.m1_fetch_hi (m1_fetch & cpu_addr[15]),
	.sel_vram  (sel_vram),
	.sel_rom   (sel_rom),
	.sel_dram  (sel_dram),
	.wr_dram   (wr_dram),
	.dram_dead (dram_dead),
	.vram_addr (vram_addr),
	.rom_addr  (rom_addr),
	.dram_addr (dram_addr),
	.port50    (port50)
);

//--------------------------------------------------------------------------
// DRAM
//--------------------------------------------------------------------------
// public_flat_rw lets the Verilator harness read memory for its disassembler
// and memory viewer. Marking the few signals the harness needs is ~4x faster
// than building the whole design with --public-flat-rw, which forces every
// signal to be stored and blocks optimisation.
reg [7:0] dram [0:DRAM_BYTES-1] /* verilator public_flat_rw */;
reg [7:0] dram_q;

// Cold Boot walks the array once, writing zero. It runs at clk_sys rather than
// ce_cpu - there is no CPU to be in step with, the caller is holding it in
// reset - so the whole 128K takes 131,072 cycles, about 2.4 ms. Instant to a
// user, and short enough that no timeout anywhere notices.
//
// Only DRAM. NOT the ROM store, and NOT the video window: this models the power
// switch, not an unmount, and on a real machine screen and PCG RAM come up with
// whatever was in them. BASIC clears the screen itself on the way in, so the
// visible result is the same and the faithful behaviour is the cheaper one.
reg [DRAM_AW-1:0] cold_addr   = {DRAM_AW{1'b0}};
reg               cold_active = 1'b0;

always @(posedge clk_sys) begin
	if (cold_boot & ~cold_active) begin
		cold_active <= 1'b1;
		cold_addr   <= {DRAM_AW{1'b0}};
	end
	else if (cold_active) begin
		cold_addr <= cold_addr + 1'd1;
		// cold_addr is exactly the array's address width, so all-ones is the last
		// byte. Clearing on it means the write below has already been issued for
		// that address on this same edge.
		if (&cold_addr) cold_active <= 1'b0;
	end
end

assign dram_clearing = cold_active;

// The write port now has two sources, so the write address is no longer the
// same expression as the read address and this infers a SIMPLE DUAL PORT rather
// than a single-port RAM. Same M10K blocks and the same 1,048,576 bits - but
// that is the kind of claim this project checks rather than asserts, so compare
// block memory against the previous build's figure in STATUS.
wire [DRAM_AW-1:0] dram_wa = cold_active ? cold_addr : dram_addr[DRAM_AW-1:0];
wire        [7:0]  dram_wd = cold_active ? 8'h00     : cpu_dout;
wire               dram_we = cold_active | (mem_wr & wr_dram & ~dram_dead & ce_cpu);

always @(posedge clk_sys) begin
	if (dram_we) dram[dram_wa] <= dram_wd;
	dram_q <= dram[dram_addr[DRAM_AW-1:0]];
end

//--------------------------------------------------------------------------
// ROM store
//
// Separate ioctl indices so ROMs can be swapped independently:
//   index 0  ROM1, up to 16K at $8000-$BFFF
//   index 1  character ROM, 4K (two 2K character sets)
//
// ROM1 is a 16K window; images smaller than that (the CIAB's 8K bn54) leave
// the tail zeroed, matching ubee512, which keeps rom1[] as a flat 16K buffer
// read as `rom1[addr & 0x3FFF]` (src/memmap.c:1256) - a reference known to
// boot these images - rather than mirroring the 8K device.
//
// A 16K image is exactly what the ROM-model BASIC needs: BASIC_A at $8000
// and BASIC_B at $A000, concatenated.
//--------------------------------------------------------------------------
// ROM1 holds one 16K image per selectable machine, all resident at once, so the
// model switch is a mux rather than a reload. Banks are filled from separate
// ioctl indices - on MiSTer, separate bootN.rom files auto-loaded at startup:
//
//   ioctl 0 -> bank 0    ioctl 2 -> bank 1    ioctl 3 -> bank 2   ...
//
// Index 1 is the character ROM, shared by every model, which is why the bank
// numbering steps over it.
reg [7:0] rom1 [0:(ROM1_BANKS*16384)-1] /* verilator public_flat_rw */;
reg [7:0] rom1_q;

// The N in bootN.rom arrives in ioctl_index[15:6], NOT in the low bits.
//
// Established from Apple-IIgs_MiSTer, which auto-loads two boot ROMs and has no
// F entries at all:
//
//   // ROM3 loaded at FC0000 via boot.rom  (ioctl_index[15:6]==0)
//   // ROM1 loaded at F80000 via boot1.rom (ioctl_index[15:6]==1)
//
// So boot0/boot1/boot2.rom arrive as ioctl_index 0, 64 and 128. Two earlier
// decodes here were wrong, both recorded in NOTES 12 because each looked right:
//
//   ioctl_index == 8'd1     boot1.rom is 64, never matched - no character ROM,
//                           which presents as a working machine with an
//                           invisible display
//   ioctl_index[5:0] == 1   worse: all three files have [5:0] == 0, so every
//                           ROM was written into bank 0 and overwrote the boot
//                           ROM. The machine stopped booting entirely
//
// The low bits are the *menu* index, used by F and S entries. Auto-loaded boot
// ROMs are a different namespace and must be decoded from the high bits.
wire  [9:0] dl_slot = ioctl_index[15:6];

// There are only FOUR auto-loaded slots. Main_MiSTer/user_io.cpp loops
// `for (... i < 4; i++)` over boot%d.rom, so boot4.rom and boot5.rom are never
// opened - which cost a hardware round to find (BUG-011). The map below fits
// everything into what exists:
//
//   slot 0  boot0.rom  the MANDATORY bundle, 36K, four images concatenated
//   slot 1  boot1.rom  WordBee 8K -> ROM hi $0000 -> CPU $C000-$DFFF   32K IC
//   slot 2  boot2.rom  Telcom  4K -> ROM hi $2000 -> CPU $E000-$EFFF   32K IC
//   slot 3  boot3.rom  free
//
// Read that as one fixed bundle plus a three-slot optional-ROM pool. Slot 0
// holds images that have not changed since the 1980s and never will, so it is
// built once; slots 1-3 are where anything a user chooses between lives. The
// optional ROMs keep their own slots deliberately - they are what a user
// legitimately omits, so they must fail independently of each other.
//
// Bundle layout, natural concatenation with no padding so building it is one
// `cat` (see the boot0.rom rule in verilator/Makefile, which is where the order
// is defined - do not retype it):
//
//   0x0000-0x1FFF   8K  bn54.rom         -> ROM1 bank 0   CIAB
//   0x2000-0x2FFF   4K  charrom.bin      -> char ROM      every model
//   0x3000-0x6FFF  16K  basic_5.22e.rom  -> ROM1 bank 1   BASIC
//   0x7000-0x8FFF   8K  bn56.rom         -> ROM1 bank 2   Premium
//
// The order is chosen so truncation degrades gracefully: a bundle cut short
// after 12K still gives a working standard CIAB *with* text, rather than a
// machine with no font.
wire        dl_s0 = ioctl_download & (dl_slot == 10'd0);

wire        dl_bn54  = dl_s0 &                            (ioctl_addr < 25'h2000);
wire        dl_char  = dl_s0 & (ioctl_addr >= 25'h2000) & (ioctl_addr < 25'h3000);
wire        dl_basic = dl_s0 & (ioctl_addr >= 25'h3000) & (ioctl_addr < 25'h7000);
wire        dl_bn56  = dl_s0 & (ioctl_addr >= 25'h7000) & (ioctl_addr < 25'h9000);

wire        dl_rom1  = dl_bn54 | dl_basic | dl_bn56;

// One subtractor rather than three: pick the sub-image's base and offset from it.
wire [15:0] dl_base  = dl_char  ? 16'h2000
                     : dl_basic ? 16'h3000
                     : dl_bn56  ? 16'h7000
                     :            16'h0000;
wire [15:0] dl_off   = ioctl_addr[15:0] - dl_base;

wire  [1:0] dl_bank  = dl_basic ? 2'd1 : dl_bn56 ? 2'd2 : 2'd0;

// Upper ROM window. Both images share one array because the CPU sees them as one
// contiguous 12K run, so the download offset is just where each one starts.
wire        dl_wordbee = ioctl_download & (dl_slot == 10'd1) & (ioctl_addr < 25'h2000);
wire        dl_telcom  = ioctl_download & (dl_slot == 10'd2) & (ioctl_addr < 25'h1000);
wire        dl_romhi   = dl_wordbee | dl_telcom;
wire [13:0] dl_romhi_a = dl_telcom ? {1'b1, ioctl_addr[12:0]}     // $2000 + n
                                   : {1'b0, ioctl_addr[12:0]};

// Width the comparison to 3 bits: ROM1_BANKS can be 4, which truncates to 0 in
// two bits and would reject every bank.
wire        dl_bank_ok = dl_rom1 & ({1'b0, dl_bank} < ROM1_BANKS[2:0]);

// Which bank the machine actually runs, from the model table.
wire  [1:0] rom1_bank;

always @(posedge clk_sys) begin
	if (ioctl_wr & dl_bank_ok) rom1[{dl_bank, dl_off[13:0]}] <= ioctl_dout;
	rom1_q <= rom1[{rom1_bank, rom_addr[13:0]}];
end

// The upper ROM window, $C000-$FFFF, which microbee_mem addresses as
// rom_addr[14]=1. Sized to the full 16K the address space can reach rather than
// the 12K actually fitted, so no in-range CPU address can index past the end.
// 4K of spare BRAM against an out-of-bounds read is a trade worth making.
reg [7:0] romhi [0:16383] /* verilator public_flat_rw */;
reg [7:0] romhi_q;

always @(posedge clk_sys) begin
	if (ioctl_wr & dl_romhi) romhi[dl_romhi_a] <= ioctl_dout;
	romhi_q <= romhi[rom_addr[13:0]];
end

// ROM2/ROM3 are absent on every CIAB-family machine, and their windows read as
// zero there (ubee512 leaves rom2[]/rom3[] zeroed when no image is configured).
// The 32K IC is the one model with them fitted - WordBee at $C000 and Telcom at
// $E000 - so the window is gated on the model, NOT on whether an image happened
// to be downloaded. A CIAB with boot4/boot5.rom present must still read zero, or
// the frozen baseline in STATUS moves.
wire [7:0] rom_data = rom_addr[14] ? (model_has_romhi ? romhi_q : 8'h00)
                                   : rom1_q;

//--------------------------------------------------------------------------
// CRTC + video
//--------------------------------------------------------------------------
wire [13:0] crtc_ma;
wire  [4:0] crtc_ra;
wire        crtc_de, crtc_cursor, crtc_alt_charset;
wire  [7:0] crtc_cols;
wire  [6:0] crtc_rows;
wire  [4:0] crtc_row_h;
wire        crtc_hs, crtc_vs, crtc_hb, crtc_vb;
wire  [7:0] crtc_dout;
wire [13:0] crtc_update_addr;
wire        crtc_update_strobe;

mc6545 crtc
(
	.clk           (clk_sys),
	.reset         (reset),
	.ce            (ce_char),

	.cs            (crtc_sel),
	.rs            (pa[0]),          // even = address/status, odd = data
	.we            (io_wr_stb),
	.re            (io_rd_stb),
	.din           (cpu_dout),
	.dout          (crtc_dout),

	.MA            (crtc_ma),
	.RA            (crtc_ra),
	.DE            (crtc_de),
	.HSYNC         (crtc_hs),
	.VSYNC         (crtc_vs),
	.CURSOR        (crtc_cursor),
	.HBLANK        (crtc_hb),
	.VBLANK        (crtc_vb),
	.alt_charset   (crtc_alt_charset),

	.disp_cols     (crtc_cols),
	.disp_rows     (crtc_rows),
	.disp_row_h    (crtc_row_h),

	.update_addr   (crtc_update_addr),
	.update_strobe (crtc_update_strobe),
	.lpen_set      (kbd_lpen_set),
	.lpen_din      (kbd_lpen_din)
);

//--------------------------------------------------------------------------
// Keyboard
//
// The key matrix hangs off the CRTC's light pen rather than a keyboard
// controller, so it is scanned by the display address walk and by the R31
// transparent-address strobe. Port $0B gates the first of those.
//--------------------------------------------------------------------------
wire        kbd_lpen_set;
wire [13:0] kbd_lpen_din;

microbee_kbd kbd
(
	.clk           (clk_sys),
	.reset         (reset),
	.ps2_key       (ps2_key),
	.symbolic      (kbd_symbolic),

	.ce_char       (ce_char),
	.MA            (crtc_ma),
	.DE            (crtc_de),
	.latchrom      (latchrom),
	.update_addr   (crtc_update_addr),
	.update_strobe (crtc_update_strobe),

	.lpen_set      (kbd_lpen_set),
	.lpen_din      (kbd_lpen_din)
);

wire [7:0] vram_data;

microbee_video video_inst
(
	.clk         (clk_sys),
	.ce_pix      (ce_pix),
	.ce_char     (ce_char),

	.MA          (crtc_ma),
	.RA          (crtc_ra),
	.DE          (crtc_de),
	.CURSOR      (crtc_cursor),
	.alt_charset (crtc_alt_charset),

	.cpu_addr    (vram_addr),
	.cpu_din     (cpu_dout),
	.cpu_dout    (vram_data),
	.cpu_wr      (mem_wr & sel_vram & ce_cpu),
	.latchrom    (latchrom),

	.port1c      (port1c),
	.port08_cram (port08[6]),
	.has_colour  (model_colour),
	.use_colour  (use_colour),
	.frame_tick  (crtc_vs),

	.rom_wr      (ioctl_wr & dl_char),
	// dl_off, not ioctl_addr: the char ROM sits at 0x2000 inside the boot0.rom
	// bundle, so the raw download address is 4K high.
	.rom_addr    (dl_off[11:0]),
	.rom_din     (ioctl_dout),

	.phosphor    (phosphor),
	.R           (R),
	.G           (G),
	.B           (B)
);

//--------------------------------------------------------------------------
// Sync and blanking, delayed one character period to match the pixel stream
//--------------------------------------------------------------------------
// microbee_video loads the shifter and de_r together at ce_char, so each
// character is displayed one character period *after* it is fetched. The CRTC's
// own HBLANK is not delayed, so the raw timing runs 8 pixels ahead of the pixels
// it describes.
//
// That is invisible to anything which simply blanks on HBLANK - both agree the
// picture is black there. It is very visible to anything that *measures* the
// active window from the HBLANK edges, which is exactly what MiSTer's
// scandoubler does (`if(!hb && hb_in) hde_end <= hcnt[31:1]`): it starts 8
// pixels early, so the window gains 8 black pixels at the left and loses the
// final character column at the right. On hardware that showed up as a missing
// right-hand border on two unrelated programs.
//
// Delay all four together so their relationships are unchanged and the whole
// picture simply sits 8 pixels later.
reg [7:0] hs_sr, vs_sr, hb_sr, vb_sr;
always @(posedge clk_sys) if (ce_pix) begin
	hs_sr <= {hs_sr[6:0], crtc_hs};
	vs_sr <= {vs_sr[6:0], crtc_vs};
	hb_sr <= {hb_sr[6:0], crtc_hb};
	vb_sr <= {vb_sr[6:0], crtc_vb};
end

assign hsync  = hs_sr[7];
assign vsync  = vs_sr[7];
assign hblank = hb_sr[7];
assign vblank = vb_sr[7];

//--------------------------------------------------------------------------
// Active area, for the caller's aspect ratio
//--------------------------------------------------------------------------
// MicroBee pixels are 1 wide : 2 tall (ubee512 doc/README.md documents a 2:1
// display ratio by default), so the correct display aspect is
// active_width : active_height * 2 - which the caller computes. Both figures
// change when software reprograms the CRTC between 64x16 and 80x24.
assign active_w = {1'b0, crtc_cols, 3'd0};                 // characters * 8
assign active_h = {5'd0, crtc_rows} * ({7'd0, crtc_row_h} + 12'd1);

//--------------------------------------------------------------------------
// Floppy - WD2793
//
// The CIAB's controller is the Applied Technology one (ubee512 MODFDC_AT).
// Port $48 write: [1:0] drive select, [2] side, [3] density (1 = MFM/double).
// Port $48 read:  bit 7 = intrq | drq, everything else 0. There is no
// interrupt line - the BIOS polls that bit.
//
// Geometry is ss80: 80 tracks, single sided, 10 x 512 sectors, laid out
// linearly by track. size_code=4 is exactly 10x512, and layout=1 makes the
// address {track,side}>>1 = track, which is the linear order. layout=0 would
// give the ds40/ds80 side interleave instead.
//--------------------------------------------------------------------------
reg [7:0] fdc_ext;
always @(posedge clk_sys) begin
	if (reset) fdc_ext <= 8'h00;
	else if (io_wr_stb & fdc_ext_sel) fdc_ext <= cpu_dout;
end

wire       fdc_side  = fdc_ext[2];

// Drive select is a 2-bit number decoded 1-of-4 by a 74LS139 on the controller
// (NOTES 6, drawing 8317-4-01), so exactly one drive line is ever asserted. We
// model ONE drive, which is a faithful machine - single-drive was a factory
// configuration and is what both CP/Ms default to - so selecting any other
// drive must find nothing there.
//
// READY (2793 pin 32) is a real drive signal via an LS04, not something the
// controller synthesises, so an empty drive bay never returns it and the BIOS
// sees NOT READY. Tying ready to disk_mounted alone served drive 0's media to
// whatever the BIOS asked for, so B: silently mirrored A: (BUG-013): DIR B:
// listed A:'s files and PIP B:=A:*.* copied a disk onto itself.
wire       fdc_drive0 = (fdc_ext[1:0] == 2'b00);

wire [7:0] fdc_dout;
wire       fdc_drq, fdc_intrq;

// EDSK=1 even though we mount a raw ss80 image. The scanner reads block 0,
// sees the "EXTENDED CPC DSK" signature is absent, clears var_size and aborts
// itself (scan_active <= var_size) - which is the designed fallback to fixed
// geometry, and is the single sd_rd seen at startup. EDSK=0 is NOT equivalent:
// it leaves the mount path incomplete and the FDC never reads anything.
wd1793 #(.RWMODE(1), .EDSK(1)) fdc
(
	.clk_sys       (clk_sys),
	.ce            (ce_cpu),
	.reset         (reset),
	// Levels, not the one-shot strobes used for the CRTC. wd1793 does its own
	// edge detection on rd/wr under `ce`, and acts on the FALLING edge - a
	// single 54MHz strobe would almost never coincide with ce_cpu, and would
	// never present an edge pair. io_en does the chip select (rde = rd & io_en).
	.io_en         (fdc_sel),
	.rd            (io_rd),
	.wr            (io_wr),
	.addr          (pa[1:0]),
	.din           (cpu_dout),
	.dout          (fdc_dout),
	.drq           (fdc_drq),
	.intrq         (fdc_intrq),
	.busy          (disk_busy),

	.wp            (img_readonly),
	.size_code     (3'd4),          // 10 x 512, every MicroBee raw format
	.layout        (disk_layout),   // 1 = ss80 linear by track, 0 = ds40/ds80
	.side          (fdc_side),
	.ready         (disk_mounted & fdc_drive0),

	.img_mounted   (img_mounted),
	.img_size      (img_size),
	// The .dsk scanner streams the whole image through the sector buffer to
	// build its geometry table, and it reads that buffer at block 0
	// ({2'b00, scan_addr[8:0]}). Any FDC command running at the same time moves
	// sd_block, so incoming scan blocks land in a different quarter of the
	// buffer than the scanner reads - it then parses garbage, picks up absurd
	// sector counts and runs the table off the end. So the machine has to be
	// held off until the scan finishes; that is what `prepare` is for.
	.prepare       (disk_prepare),
	.sd_lba        (sd_lba),
	.sd_rd         (sd_rd),
	.sd_wr         (sd_wr),
	.sd_ack        (sd_ack),
	.sd_buff_addr  (sd_buff_addr),
	.sd_buff_dout  (sd_buff_dout),
	.sd_buff_din   (sd_buff_din),
	.sd_buff_wr    (sd_buff_wr),

	.input_active  (1'b0),
	.input_addr    (20'd0),
	.input_data    (8'd0),
	.input_wr      (1'b0),
	.buff_addr     (),
	.buff_read     (),
	.buff_din      (8'd0)
);

reg disk_mounted = 1'b0;
always @(posedge clk_sys) if (img_mounted) disk_mounted <= |img_size;

//--------------------------------------------------------------------------
// Z80 PIO (M5) - ports $00-$03, mirrored at $10-$13
//
// Port A is the Centronics printer, unconnected here. Port B carries the
// speaker, cassette and RS232 (ubee512 src/pio.h):
//
//   0 cassette in   1 cassette out   2 DTR   3 CTS
//   4 RS232 RX      5 RS232 TX       6 SPEAKER
//   7 model-dependent - on the 64K CIAB this is MODPB7_PUP, a pull-up that
//     always reads 1. Models that put vsync here get a 50 Hz interrupt from
//     it; the CIAB does not, which is why nothing depends on PIO interrupts
//     during boot.
//--------------------------------------------------------------------------
wire [7:0] pio_dout;
wire [7:0] pio_b_out;
wire       pio_int_n;
wire [7:0] pio_vec;
wire       pio_vec_oe;

// Interrupt acknowledge is M1 together with IORQ, which is the one cycle where
// iorq is asserted and m1_n is low - the same condition io_rd/io_wr exclude.
wire intack /* verilator public_flat_rd */ = ~m1_n & ~iorq_n;

// RETI is ED 4D. Watch the opcode stream for the pair so the PIO can drop its
// in-service latch; without it a second interrupt would never be delivered.
reg  ed_seen;
always @(posedge clk_sys) begin
	if (reset) ed_seen <= 1'b0;
	else if (ce_cpu && m1_fetch) ed_seen <= (cpu_din == 8'hED);
end
wire reti = ce_cpu & m1_fetch & ed_seen & (cpu_din == 8'h4D);

// Cassette in (M8-1). The tape module generates the Kansas City waveform from a
// .tap image and drives this bit; its start trigger watches how fast the CPU is
// reading port B, which is why the strobe below is tapped here.
wire cass_in;
wire pb_rd_stb = io_rd_stb & pio_sel & (pa[1:0] == 2'b10);

microbee_tape tape
(
	.clk_sys      (clk_sys),
	.ce           (ce_pix),        // must be 13.5 MHz - see microbee_tape.v
	.reset        (reset),

	.img_mounted  (tape_mounted),
	.img_size     (tape_size),
	.sd_lba       (tape_lba),
	.sd_rd        (tape_rd),
	.sd_ack       (tape_ack),
	.sd_buff_addr (tape_buff_addr),
	.sd_buff_dout (tape_buff_dout),
	.sd_buff_wr   (tape_buff_wr),

	.rewind       (tape_rewind),
	.pb_rd        (pb_rd_stb),

	.cass_in      (cass_in),
	.playing      (tape_playing),
	.tape_bytes   (tape_bytes),
	.tape_stalls  (tape_stalls),
	.tape_fetches (tape_fetches)
);

z80pio pio
(
	.clk     (clk_sys),
	.ce      (ce_cpu),
	.reset   (reset),

	.cs      (pio_sel),
	.addr    (pa[1:0]),
	.rd      (io_rd_stb),
	.wr      (io_wr_stb),
	.din     (cpu_dout),
	.dout    (pio_dout),

	.iei     (1'b1),
	.ieo     (),
	.int_n   (pio_int_n),
	.intack  (intack),
	.reti    (reti),
	.int_vec (pio_vec),
	.vec_oe  (pio_vec_oe),

	.a_out   (),
	.a_in    (8'hFF),
	.b_out   (pio_b_out),
	.b_in    ({piob7_vs_eff ? crtc_vb : 1'b1, // 7 PUP or vsync, per model
	          1'b0,                          // 6 speaker (output)
	          1'b0,                          // 5 RS232 TX (output)
	          1'b0,                          // 4 RS232 RX - idle, nothing attached
	          // 3 RS232 CTS - HIGH, meaning "clear to send".
	          //
	          // This was 1'b0 and it hung the machine. The ROM's serial transmit
	          // routine spins at $A884 (`IN A,($02) / BIT 3,A / JR Z,-4`) until
	          // CTS is high, so with it tied low ANY byte sent to the serial
	          // device wedges the Z80 for good - keyboard dead, no error.
	          //
	          // It only bites when something redirects BASIC's output vector to
	          // the serial device, which is why it lay hidden: a tape that loads
	          // over BASIC's workspace does exactly that. Micro Defender loads at
	          // $0400 and hangs; tapes loading at $0900 leave the vector alone
	          // and are fine.
	          //
	          // ubee512 is the reference and it returns CTS set unconditionally -
	          // src/serial.c, five sites, each commented "CTS always true for
	          // now". Nothing is attached to our RS232, so "always ready" is both
	          // what the reference does and the only value that cannot deadlock.
	          1'b1,                          // 3 RS232 CTS
	          1'b0,                          // 2 RS232 DTR (output)
	          1'b0,                          // 1 cassette out (output)
	          cass_in})                      // 0 cassette in
);

wire speaker  = pio_b_out[6];
wire cass_out = pio_b_out[1];

// One-bit speaker into a signed sample. Kept well below full scale: this is a
// square wave straight off a port bit, and at full amplitude it is unpleasant.
//
// Tape mixes in alongside it at an EIGHTH of that level, gated on the OSD option
// and on the tape actually running. It has been judged on hardware twice and come
// down each time - half was too loud (session 10), then a quarter still was
// (session 11) - because the tape is meant to be reassurance that something is
// happening, not the main event, and it plays for minutes at a time.
//
// Be honest about what this is: a real MicroBee's tape audio came out of the
// RECORDER, not the computer's speaker. Mixing it into our output emulates
// sitting next to the deck, not the machine's wiring. It earns its place
// because a load takes minutes against a static screen and the sound is the
// only sign the machine is working - without it users think it has hung. That
// is why the OSD default is On.
wire signed [15:0] spk_level  = speaker ? 16'sd6000 : -16'sd6000;
wire signed [15:0] tape_level = (tape_playing & tape_audio_en)
                              ? (cass_in ? 16'sd750 : -16'sd750) : 16'sd0;

assign audio = spk_level + tape_level;

//--------------------------------------------------------------------------
// I/O read mux - unmapped ports float high
//--------------------------------------------------------------------------
// $1C and $08 read back their latches (MAME port1c_r / port08_r). $08 is only
// answered on a colour machine - on a mono one it is not fitted, and an
// unmapped port must float high.
wire [7:0] io_data = crtc_sel     ? crtc_dout :
                     pio_sel      ? pio_dout  :
                     fdc_sel      ? fdc_dout  :
                     fdc_ext_sel  ? {fdc_intrq | fdc_drq, 7'd0} :
                     vlatch_sel   ? port1c    :
                     (port08_sel & model_colour) ? port08 :
                                    8'hFF;

//--------------------------------------------------------------------------
// CPU data in
//--------------------------------------------------------------------------
always @(*) begin
	if (intack)         cpu_din = pio_vec_oe ? pio_vec : 8'hFF;
	else if (io_rd)     cpu_din = io_data;
	else if (sel_vram)  cpu_din = vram_data;
	else if (sel_rom)   cpu_din = rom_data;
	else if (dram_dead) cpu_din = 8'h00;
	else                cpu_din = dram_q;
end

//--------------------------------------------------------------------------
// Debug taps
//
// An opcode fetch is M1 with mreq and rd asserted and refresh inactive. We
// latch on the CPU clock enable so the harness sees one event per fetch.
//--------------------------------------------------------------------------
reg [15:0] pc_r;
reg  [7:0] op_r;
reg        fetch_r;

always @(posedge clk_sys) begin
	fetch_r <= 1'b0;
	if (ce_cpu) begin
		if (m1_fetch) begin
			pc_r    <= cpu_addr;
			op_r    <= cpu_din;
			fetch_r <= 1'b1;
		end
	end
end

assign dbg_pc     = pc_r;
assign dbg_opcode = op_r;
assign dbg_fetch  = fetch_r;
assign dbg_addr   = cpu_addr;
assign dbg_din    = cpu_din;
assign dbg_dout   = cpu_dout;
assign dbg_mreq   = ~mreq_n;
assign dbg_iorq   = ~iorq_n;
assign dbg_rd     = ~rd_n;
assign dbg_wr     = ~wr_n;
assign dbg_port50 = port50;

wire _unused = &{1'b0, mem_rd, 1'b0};

endmodule
