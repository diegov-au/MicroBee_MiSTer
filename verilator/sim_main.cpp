//============================================================================
// Verilator harness for the MicroBee core.
//
// Derived from the Mac II harness that shipped with this template: the
// sim/* library, the ImGui/SDL loop, the screenshot path and the DUT binding
// pattern are kept; the ~3400 lines of 68k/Mac instrumentation are gone.
//
// Usage:
//   ./obj_dir/Vemu --rom boot.rom [--headless] [--trace file] [--stop-at-pc N]
//                  [--stop-at-frame N] [--screenshot-frame N] [--max-ticks N]
//
// The ROM image is boot ROM (8K) followed by char ROM (4K), loaded at ioctl
// index 0. See rtl/microbee_core.v for the layout.
//============================================================================

#include <verilated.h>
#include <queue>
#include <utility>
#include "Vemu.h"
#include "Vemu__Syms.h"

#include "imgui.h"
#include "implot.h"
#ifndef _MSC_VER
#include <stdio.h>
#include <SDL.h>
#include <SDL_opengl.h>
#else
#define WIN32
#include <dinput.h>
#endif

#define VERILATOR_MAJOR_VERSION (VERILATOR_VERSION_INTEGER / 1000000)
#if VERILATOR_MAJOR_VERSION >= 5
#define VERTOPINTERN top->rootp
#else
#define VERTOPINTERN top
#endif

#include "sim_console.h"
#include "sim_bus.h"
#include "sim_blkdevice.h"
#include "sim_video.h"
#include "sim_audio.h"
#include "sim_input.h"
#include "sim_clock.h"
#include "sim/z80_dasm.h"

#include "../imgui/imgui_memory_editor.h"
#include "../imgui/ImGuiFileDialog.h"

#include <string>
#include <vector>
#include <algorithm>
#include <cstring>
using namespace std;

#ifndef _MSC_VER
extern SDL_Window* window;
#endif

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "sim/stb_image_write.h"

//----------------------------------------------------------------------------
// Simulation control
//----------------------------------------------------------------------------
int  initialReset = 48;
bool run_enable   = true;
int  batchSize    = 150000;
bool single_step  = false;
bool multi_step   = false;
int  multi_step_amount = 1024;

bool headless = false;
// Machine selection. These mirror microbee.sv's OSD fields exactly, so what the
// harness proves is what hardware runs. 0 = 64K CIAB; see rtl/microbee_models.v
// for the encoding, which the OSD's 3-bit field shares.
int model = 0;
int boot_basic = 0;

// Which ROM1 bank the selected machine runs, and which bootN.rom slot fills it.
// Mirrors rtl/microbee_models.v - if that table changes, this must follow, or
// the harness will quietly test a different machine than hardware runs.
//
//   model            bank   slot   image
//   0 64k              0      0    bn54
//   1 p64k             2      3    bn56
//   2 ic                1      2    basic_5.22e
//   3 p128k            2      3    bn56
//   --boot-basic       1      2    basic_5.22e (overrides the model's own)
static unsigned rom_bank_for_model()
{
	if (boot_basic) return 1u;
	if (model == 1 || model == 3) return 2u;
	if (model == 2) return 1u;
	return 0u;
}

static unsigned rom_slot_for_model()
{
	switch (rom_bank_for_model()) {
		case 1:  return 2u;
		case 2:  return 3u;
		default: return 0u;
	}
}

// Mirrors has_romhi in rtl/microbee_models.v: ROM images fitted in the upper
// window, $C000-$EFFF. Only the 32K IC has them (WordBee + Telcom). Deliberately
// NOT keyed off boot_basic, exactly as the RTL is - a CIAB running BASIC from
// slot 2 is still a CIAB, with nothing in the upper sockets.
static bool model_has_romhi()
{
	return model == 2;
}
int phosphor = 1;                // default amber, as most MicroBees shipped
// Render in colour where the model has the hardware. Mirrors the OSD, whose
// Phosphor list is Colour,Amber,Green,White with Colour first and therefore
// default. A mono machine ignores it and shows `phosphor` instead.
int use_colour = 1;
// Symbol keys give what a US keycap says. Mirrors the OSD default, and it also
// decides which table --type uses - if the two disagree the harness types
// something other than what was asked for.
bool kbd_symbolic = true;
// PIO port B bit 7. Default 0 = pull-up, which is the 64K CIAB (MODPB7_PUP).
// ROM-BASIC models put vsync here and take their 50 Hz timer tick from it, so
// running one of those ROMs without --piob7-vsync leaves the monitored bit
// permanently true and the machine interrupts continuously.
int piob7_vs = 0;
// SimAudio has no playback path - it can only write samples to a file. So this
// is the only way to get a clean, uninterrupted recording.
const char* audio_file = NULL;

//----------------------------------------------------------------------------
// Audio playback and scope
//
// The sim runs roughly 22x slower than real time, so continuous real-time audio
// is impossible: SDL wants 44100 samples per *wall* second and we produce that
// many per *emulated* second. Rather than let the device underrun continuously
// (which just clicks), buffer the stream and play it in chunks - unpause once a
// cushion has accumulated, pause again when it drains. The result is correct
// pitch and timbre in short bursts with gaps between them, which is exactly
// what is needed to check a beep by ear.
//
// For an uninterrupted recording use --audio-file instead.
//----------------------------------------------------------------------------
// Live playback is impossible: the sim generates about 1/22 of the samples real
// time needs, so the data simply does not exist fast enough. Two earlier attempts
// both failed audibly and are worth recording so they are not retried -
//
//   pause on underrun, resume on a cushion -> stepped between the idle DC level
//     and zero a few times a second: slow clicking even when silent
//   pad the shortfall with silence      -> chopped a continuous tone into
//     fragments at the GUI frame rate: clicking instead of a tone
//
// So: log the samples and play them back on demand, at real speed. Playback is
// delayed rather than live, and in exchange it is continuous and correct.
// Master clock. Defaults to the 54 MHz the hardware PLL produces, so a plain
// run matches what gets synthesised. --fast drops it to 13.5 MHz - the real
// machine's crystal and the fastest rate this design actually needs - which is
// 4x cheaper to simulate because Verilator's cost is per evaluation, not per
// nanosecond. See the note above the enables in microbee_core.v.
//
// Anything converting ticks to real time must derive from this, never from a
// literal: at 13.5 MHz a "54 MHz tick count" is four times too long.
static const int CLK_SYS_HZ_HW   = 54000000;
static const int CLK_SYS_HZ_FAST = 13500000;
bool fast_clock = false;
int  clk_sys_hz = CLK_SYS_HZ_HW;

static const int AUDIO_RATE = 44100;
int AUDIO_DIV = CLK_SYS_HZ_HW / AUDIO_RATE;   // clk_sys per sample; --fast rescales
static const int AUDIO_CAP_SECS = 60;                  // buffer limit

SDL_AudioDeviceID audio_dev = 0;
int      audio_div_cnt      = 0;
uint64_t audio_samples_made = 0;

// Capture buffer: fills while the machine runs, played on demand, then cleared
// so the next thing can be captured cleanly. Deliberately linear rather than a
// ring - "play what is in the buffer" is much easier to reason about than "play
// the last N seconds of a wrapping history".
vector<int16_t> audio_buf;
bool     audio_capture   = true;
uint64_t audio_sound_cnt = 0;   // samples in the buffer that are not silence
int      audio_quiet_run = 0;   // consecutive silent samples at the tail

// One-pole DC blocker, playback only.
//
// The speaker is a single port bit, so an idle machine presents a constant
// -6000 rather than silence. That is inaudible by itself, but it made every
// pause/resume of the audio device a step from -6000 to 0 and back - which is
// what produced a slow clicking, like a geiger counter, whenever nothing was
// playing. Removing DC means an idle machine really is silent, so the queue can
// be padded with zeros and the device never has to stop.
//
// Deliberately NOT applied to --audio-file: that stays the core's raw output so
// it remains useful for analysis.
static int32_t dc_state = 0;
static int16_t audio_dcblock(int16_t x)
{
	dc_state += (((int32_t)x << 8) - dc_state) >> 9;   // ~14 Hz at 44 kHz
	int32_t y = (int32_t)x - (dc_state >> 8);
	if (y >  32767) y =  32767;
	if (y < -32768) y = -32768;
	return (int16_t)y;
}

// Rolling window for the on-screen scope.
static const int SCOPE_N = 1024;
float scope_buf[SCOPE_N] = {0};
int   scope_pos = 0;

bool     stop_at_pc_enabled = false;
uint32_t stop_at_pc = 0;
bool     stop_at_frame_enabled = false;
int      stop_at_frame = 0;
// --trace-video state. Scanlines are counted from the rising edge of vsync.
bool trace_video = false;
int  vt_line = 0, vt_vb_rise = -1, vt_vb_fall = -1;
int  vt_last_lines = -1, vt_last_rise = -1, vt_last_fall = -1;
bool vt_hs_prev = false, vt_vs_prev = false, vt_vb_prev = false;

bool     max_ticks_enabled = false;
uint64_t max_ticks = 0;
vector<int> screenshot_frames;

// Headless typing. Keys are injected straight into ps2_key: in headless mode
// SimInput's event queue is always empty, so nothing else writes that signal.
const char* type_string = NULL;
int  type_start_frame = 150;   // let the machine boot and clear the screen first
int  type_hold        = 4;     // frames a key is held
int  type_gap         = 4;     // frames between keys
int  type_done_frame  = -1;
bool dump_screen_enabled = false;
// Raw screen-RAM bytes under each row. Bit 7 selects PCG rather than the char
// ROM, so the printed character alone is ambiguous - see dump_screen().
bool dump_screen_hex = false;
bool dump_colour = false;      // Premium colour + attribute RAM, per cell

FILE* fdc_log_file = NULL;

// M8-1. Every CPU read of PIO port B data, with a timestamp. The tape start
// trigger has to tell "the machine is in its tape sampling loop" from "the
// machine is polling port B for the 50 Hz vsync tick", and those two differ
// only in how often the read happens - so the gap between reads is the
// measurement the trigger is designed from. See PLAN's M8-1 build scope.
FILE* piob_log_file = NULL;

// M8-1 cassette. --tape mounts a .tap on block slot 1; --no-tape-audio clears
// the OSD's Tape Audio option, which is On by default on hardware because a
// silent multi-minute load looks like a hung machine.
const char* tape_file = NULL;
bool tape_audio_en = true;
int  tape_rewind_frame = -1;    // --tape-rewind N: pulse rewind at frame N
bool tape_rewind_pulse = false;
bool tape_trace = false;
uint64_t tape_playing_ticks = 0;

// Cold Boot, standing in for the OSD's T[19]. --cold-boot N pulses it at frame
// N; the core then zeroes DRAM with the machine held in reset. cold_boot_ticks
// counts how long the clear actually ran, because "the flag did something" has
// to be a measured quantity here - a one-shot that never reached the core would
// otherwise present as a machine that simply rebooted.
int  cold_boot_frame = -1;
bool cold_boot_pulse = false;
uint64_t cold_boot_ticks = 0;

// --reset N: a plain reset at frame N, and it exists to be Cold Boot's NEGATIVE
// CONTROL. On the 32K IC the two are distinguishable on screen - a reset returns
// to a bare `>` because BASIC finds its workspace intact and warm-starts, while
// a cold boot reprints the Microworld banner - so a test that only ever runs the
// cold case cannot tell "DRAM was cleared" from "the machine rebooted".
// Held for a fixed span of ticks; sim.v's own reset_cnt extends it by 255.
int      reset_frame = -1;
uint64_t reset_until = 0;

// Block device activity
uint64_t sd_rd_reqs = 0, sd_wr_reqs = 0, sd_acks = 0, sd_bytes = 0;
uint32_t sd_last_lba = 0;

// Keyboard scan activity
uint64_t kbd_r31_strobes = 0;   // R31 transparent-address strobes
uint64_t kbd_nat_scans   = 0;   // natural MA-walk scan points
uint64_t kbd_lpen_hits   = 0;   // times a pressed key strobed the light pen
// M5. The speaker is one PIO port-B bit, so counting transitions of the audio
// output says whether anything is actually driving it - the same trick as the
// keyboard scan counters, and it makes sound checkable headlessly.
uint64_t spk_toggles     = 0;
uint64_t pio_int_acks    = 0;   // interrupt acknowledge cycles taken

// CPU trace
bool  cpu_trace_enable = false;
const char* cpu_trace_filename = "cpu_trace.log";
FILE* cpu_trace_file = NULL;
uint64_t cpu_trace_count = 0;
uint64_t cpu_trace_limit = 0;   // 0 = unlimited
// --trace-from-pc: hold the trace off until the CPU first fetches from this
// address, so a hang hundreds of millions of instructions into a run can be
// captured without writing the whole boot to disk. -1 = trace from the start.
int  cpu_trace_from_pc = -1;
bool cpu_trace_armed   = false;

//----------------------------------------------------------------------------
// Harness objects
//----------------------------------------------------------------------------
const char* windowTitle       = "Verilator - MicroBee 64K CIAB";
const char* windowTitle_Video = "MicroBee video";
const char* windowTitle_Audio = "Audio output";
bool showDebugLog = true;

DebugConsole console;
MemoryEditor mem_edit;

SimBus         bus(console);
SimBlockDevice blockdevice(console);
SimInput       input(13, console);

// MicroBee standard video: 640 active pixels, ~312 lines at 50Hz. Give the
// framebuffer some headroom for whatever the CRTC is actually programmed to.
#define VGA_WIDTH  800
#define VGA_HEIGHT 350
SimVideo video(VGA_WIDTH, VGA_HEIGHT, 0);
float vga_scale = 1.5;

// Audio was compiled out by the template this harness came from. M5 gave the
// core a real speaker on PIO port B bit 6, so it is enabled again - only opened
// when there is a window, since headless runs have no SDL audio device and use
// the speaker-toggle counter instead.
SimAudio audio(CLK_SYS_HZ_HW, false);   // re-clocked in main() if --fast

Vemu* top = NULL;
vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

SimClock clk_sys(1);

//----------------------------------------------------------------------------
// Memory peek - resolves an address the way the running machine would, so the
// disassembler and the memory viewer show what the CPU actually sees.
//
// Mirrors rtl/microbee_mem.v. Kept deliberately simple: video RAM lands in
// M2, so for now that window reads as 0xFF like the RTL stub.
//----------------------------------------------------------------------------
static uint8_t peek(uint16_t addr)
{
	if (!top) return 0xFF;
	uint8_t p50 = VERTOPINTERN->debug_port50;

	bool novram = (p50 >> 3) & 1;
	bool vadd   = (p50 >> 4) & 1;
	bool noroms = (p50 >> 2) & 1;
	bool rom3   = (p50 >> 5) & 1;
	int  page   = addr >> 12;

	// 1. video window: $F000-$F7FF screen RAM, $F800-$FFFF PCG RAM
	if (!novram && ((vadd && page == 0x8) || (!vadd && page == 0xF))) {
		if (addr & 0x0800)
			return VERTOPINTERN->emu__DOT__core__DOT__video_inst__DOT__pcgram[addr & 0x7FF];
		return VERTOPINTERN->emu__DOT__core__DOT__video_inst__DOT__scrram[addr & 0x7FF];
	}

	// ROM1 is banked, one 16K image per selectable machine, so peeking has to
	// follow the same bank the core runs or the disassembler and memory editor
	// quietly show a different ROM than the CPU is executing. One definition of
	// that mapping, shared with the download routing.
	const unsigned rom1_base = rom_bank_for_model() << 14;

	// 0. boot overlay: ROM1 readable low until the first port-0x50 write
	if (VERTOPINTERN->emu__DOT__core__DOT__memmap__DOT__boot_overlay &&
	    (addr & 0xC000) == 0x0000)
		return VERTOPINTERN->emu__DOT__core__DOT__rom1[rom1_base | (addr & 0x3FFF)];

	// 2/3. ROM windows
	if (!noroms && (addr & 0xC000) == 0x8000)
		return VERTOPINTERN->emu__DOT__core__DOT__rom1[rom1_base | (addr & 0x3FFF)];
	// Upper ROM window. Absent on the CIAB family, which reads zero; the 32K IC
	// has WordBee at $C000 and Telcom at $E000. The index is microbee_mem's
	// rom_addr[13:0] for this window, so peek and the CPU see the same bytes.
	if (!noroms && (addr & 0xC000) == 0xC000) {
		if (!model_has_romhi()) return 0x00;
		unsigned off = rom3 ? (0x2000u | (addr & 0x1FFFu)) : (addr & 0x3FFFu);
		return VERTOPINTERN->emu__DOT__core__DOT__romhi[off];
	}

	// 4. DRAM. High window is always block 0; low window is banked.
	unsigned blocksel = ((p50 & 1) | ((((p50 >> 1) & 1) ^ (noroms ? 1 : 0)) << 1));
	if (addr & 0x8000)
		return VERTOPINTERN->emu__DOT__core__DOT__dram[addr & 0x7FFF];
	if (blocksel & 1) return 0x00;   // half not fitted on a 64K machine
	return VERTOPINTERN->emu__DOT__core__DOT__dram[(((blocksel >> 1) & 1) << 15) | (addr & 0x7FFF)];
}

//----------------------------------------------------------------------------
// One simulation half-tick
//----------------------------------------------------------------------------
static void verilate()
{
	if (!Verilated::gotFinish()) {

		if (main_time < initialReset) VERTOPINTERN->reset = 1;
		if (main_time == initialReset) VERTOPINTERN->reset = 0;
		// --reset N, asserted for a fixed span once its frame arrives.
		if (reset_until) {
			if (main_time < reset_until) VERTOPINTERN->reset = 1;
			else { VERTOPINTERN->reset = 0; reset_until = 0; }
		}

		VERTOPINTERN->phosphor = (CData)phosphor;
		VERTOPINTERN->use_colour = (CData)use_colour;
		VERTOPINTERN->kbd_symbolic = (CData)(kbd_symbolic ? 1 : 0);
		VERTOPINTERN->piob7_vs = (CData)piob7_vs;
		VERTOPINTERN->sim_fast = (CData)fast_clock;
		VERTOPINTERN->model = (CData)model;
		VERTOPINTERN->boot_basic = (CData)boot_basic;
		VERTOPINTERN->tape_audio_en = (CData)(tape_audio_en ? 1 : 0);
		// One-shot, cleared after a single rising edge - the RTL edge-detects
		// nothing, it acts on the level, so a held rewind would keep the
		// transport pinned at the start.
		VERTOPINTERN->tape_rewind = (CData)(tape_rewind_pulse ? 1 : 0);
		// Same one-shot discipline, and the core enforces it too: a held level
		// would restart the DRAM walk every cycle and never release reset.
		VERTOPINTERN->cold_boot = (CData)(cold_boot_pulse ? 1 : 0);

		clk_sys.Tick();
		VERTOPINTERN->clk_sys = clk_sys.clk;

		// Drive the HPS emulation on the rising edge only. The RTL latches on
		// posedge clk_sys, so servicing these on both edges would present two
		// bytes per clock and the core would sample only every second one.
		if (clk_sys.IsRising()) {
			blockdevice.BeforeEval(main_time);
			input.BeforeEval();
			bus.BeforeEval();
		}

		top->eval();

		if (clk_sys.IsRising()) {
			bus.AfterEval();
			blockdevice.AfterEval();
		}

		// Optional log of every FDC port access with its value. Decoded from
		// the CPU bus taps rather than from inside the FDC, so it shows exactly
		// what the BIOS asked for and what it got back - which is the thing
		// ubee512's --modio fdc prints, so the two can be compared line by line.
		if (fdc_log_file && clk_sys.IsRising()) {
			static bool in_cycle = false;
			bool io = VERTOPINTERN->debug_iorq &&
			          (VERTOPINTERN->debug_rd || VERTOPINTERN->debug_wr);
			uint8_t p = VERTOPINTERN->debug_addr & 0xFF;
			if (io && !in_cycle && p >= 0x40 && p <= 0x4B) {
				static const char* rn[4] = {"cmd/status", "track", "sector", "data"};
				const char* name = (p <= 0x47) ? rn[p & 3] : "ext";
				if (VERTOPINTERN->debug_wr)
					fprintf(fdc_log_file, "PC=%04X  W $%02X %-10s = %02X\n",
					        VERTOPINTERN->debug_pc, p, name, VERTOPINTERN->debug_dout);
				else
					fprintf(fdc_log_file, "PC=%04X  R $%02X %-10s = %02X\n",
					        VERTOPINTERN->debug_pc, p, name, VERTOPINTERN->debug_din);
			}
			// Port-0x50 writes go in the same log so they interleave with the FDC
			// traffic. ubee512's --modio mem shows the loader bracketing every disk
			// transfer with $0C (VRAM out) then $04 (VRAM back in); the question is
			// whether we execute the same writes.
			if (io && !in_cycle && VERTOPINTERN->debug_wr && p >= 0x50 && p <= 0x57) {
				fprintf(fdc_log_file, "PC=%04X  W $%02X port50     = %02X\n",
				        VERTOPINTERN->debug_pc, p, VERTOPINTERN->debug_dout);
			}
			// PIO ($00-$03, mirrored at $10-$13). Port B data is where the
			// speaker bit lives, so this shows whether software is driving it.
			if (io && !in_cycle && (p & 0xEC) == 0x00) {
				static const char* pn[4] = {"A data", "A ctrl", "B data", "B ctrl"};
				fprintf(fdc_log_file, "PC=%04X  %c $%02X pio %-6s = %02X\n",
				        VERTOPINTERN->debug_pc,
				        VERTOPINTERN->debug_wr ? 'W' : 'R', p, pn[p & 3],
				        VERTOPINTERN->debug_wr ? VERTOPINTERN->debug_dout
				                               : VERTOPINTERN->debug_din);
			}
			// Who writes into the video window? The CP/M image should land at
			// $C000/$D200, so anything reaching $F000-$FFFF is either the loader
			// aiming at the wrong address or a decode fault. Log the PC of the
			// first few so it is a fact rather than an inference.
			static bool in_mwr = false;
			static int vram_wr_logged = 0;
			bool mwr = VERTOPINTERN->debug_mreq && VERTOPINTERN->debug_wr;
			if (mwr && !in_mwr && VERTOPINTERN->debug_addr >= 0xF000 &&
			    vram_wr_logged < 40000) {
				fprintf(fdc_log_file, "PC=%04X  MEMW %04X = %02X\n",
				        VERTOPINTERN->debug_pc, VERTOPINTERN->debug_addr,
				        VERTOPINTERN->debug_dout);
				vram_wr_logged++;
			}
			in_mwr = mwr;
			in_cycle = io;

			// Which block did we actually serve? Interleaved with the command
			// trace this is what shows whether a seek/step landed where the BIOS
			// thinks it did: for ss80 the LBA must be track*10 + sector-1.
			static CData prev_sdrd = 0;
			if ((VERTOPINTERN->sd_rd & 1) && !(prev_sdrd & 1)) {
				fprintf(fdc_log_file, "         SDRD lba=%u\n",
				        (unsigned)VERTOPINTERN->sd_lba[0]);
			}
			prev_sdrd = VERTOPINTERN->sd_rd;
		}

		if (tape_trace && clk_sys.IsRising()) {
			static CData prv_rd = 0, prv_ack = 0, prv_mnt = 0;
			CData rd  = (VERTOPINTERN->sd_rd >> 1) & 1;
			CData ak  = (VERTOPINTERN->sd_ack >> 1) & 1;
			CData mnt = (VERTOPINTERN->img_mounted >> 1) & 1;
			if (rd != prv_rd || ak != prv_ack || mnt != prv_mnt)
				fprintf(stderr, "%10llu rd=%d ack=%d mnt=%d lba=%u fill=%u valid=%u\n",
				        (unsigned long long)main_time, rd, ak, mnt,
				        (unsigned)VERTOPINTERN->sd_lba[1],
				        (unsigned)VERTOPINTERN->emu__DOT__core__DOT__tape__DOT__fill_half,
				        (unsigned)VERTOPINTERN->emu__DOT__core__DOT__tape__DOT__half_valid);
			prv_rd = rd; prv_ack = ak; prv_mnt = mnt;
		}

		// Tape transport. The rewind pulse lasts exactly one rising edge, and
		// how long the tape spent running is the counter that says whether the
		// start trigger ever fired - tape_bytes says whether it then moved.
		if (clk_sys.IsRising()) {
			if (VERTOPINTERN->tape_playing) tape_playing_ticks++;
			if (tape_rewind_pulse) tape_rewind_pulse = false;
			if (VERTOPINTERN->dram_clearing) cold_boot_ticks++;
			if (cold_boot_pulse) cold_boot_pulse = false;
		}

		// Port-B data reads, timestamped. Same bus taps and the same
		// one-cycle-per-IO-access guard as the FDC log above, kept separate so
		// it can run without the FDC log's volume. $02 and its $12 mirror.
		if (piob_log_file && clk_sys.IsRising()) {
			static bool in_pb = false;
			bool io = VERTOPINTERN->debug_iorq && VERTOPINTERN->debug_rd;
			uint8_t p = VERTOPINTERN->debug_addr & 0xFF;
			if (io && !in_pb && (p & 0xEF) == 0x02)
				fprintf(piob_log_file, "%llu %04X %02X\n",
				        (unsigned long long)main_time,
				        VERTOPINTERN->debug_pc, VERTOPINTERN->debug_din);
			in_pb = io;
		}

		// Block device counters - is the FDC actually pulling sectors through?
		if (clk_sys.IsRising()) {
			static CData prev_rd = 0, prev_wr = 0, prev_ack = 0;
			if ((VERTOPINTERN->sd_rd & 1) && !(prev_rd & 1)) { sd_rd_reqs++; sd_last_lba = VERTOPINTERN->sd_lba[0]; }
			if ((VERTOPINTERN->sd_wr & 1) && !(prev_wr & 1)) { sd_wr_reqs++; sd_last_lba = VERTOPINTERN->sd_lba[0]; }
			if ((VERTOPINTERN->sd_ack & 1) && !(prev_ack & 1)) sd_acks++;
			if (VERTOPINTERN->sd_buff_wr && (VERTOPINTERN->sd_ack & 1)) sd_bytes++;
			prev_rd = VERTOPINTERN->sd_rd; prev_wr = VERTOPINTERN->sd_wr; prev_ack = VERTOPINTERN->sd_ack;
		}

		// Keyboard scan counters. The light pen has two independent scan paths
		// and either one working can hide the other being broken, so count them
		// separately rather than trusting that typing works.
		if (clk_sys.IsRising()) {
			if (VERTOPINTERN->emu__DOT__core__DOT__crtc__DOT__update_strobe) kbd_r31_strobes++;
			if (VERTOPINTERN->emu__DOT__core__DOT__kbd__DOT__natural)        kbd_nat_scans++;
			if (VERTOPINTERN->emu__DOT__core__DOT__kbd__DOT__lpen_set)       kbd_lpen_hits++;
			{
				static SData prev_audio = 0;
				static bool  prev_intack = false;
				if (VERTOPINTERN->AUDIO_L != prev_audio) spk_toggles++;
				prev_audio = VERTOPINTERN->AUDIO_L;
				bool ia = VERTOPINTERN->emu__DOT__core__DOT__intack;
				if (ia && !prev_intack) pio_int_acks++;
				prev_intack = ia;
			}
		}

		// CPU trace: one line per opcode fetch.
		if (cpu_trace_enable && cpu_trace_file && clk_sys.IsRising() &&
		    VERTOPINTERN->debug_fetch) {
			if (cpu_trace_from_pc >= 0 && !cpu_trace_armed &&
			    VERTOPINTERN->debug_pc == (uint16_t)cpu_trace_from_pc) {
				cpu_trace_armed = true;
				fprintf(cpu_trace_file, "; armed at PC=%04X, frame=%d, tick=%llu\n",
				        cpu_trace_from_pc, video.count_frame,
				        (unsigned long long)main_time);
			}
			if ((cpu_trace_from_pc < 0 || cpu_trace_armed) &&
			    (!cpu_trace_limit || cpu_trace_count < cpu_trace_limit)) {
				char dis[64];
				uint16_t pc = VERTOPINTERN->debug_pc;
				z80_disasm(pc, peek, dis, sizeof(dis));
				fprintf(cpu_trace_file, "%10llu  %04X  %02X  %-24s p50=%02X\n",
				        (unsigned long long)main_time, pc,
				        VERTOPINTERN->debug_opcode, dis,
				        VERTOPINTERN->debug_port50);
				cpu_trace_count++;
			}
		}

		// Video timing trace (--trace-video). Reports, per frame, where the
		// vertical blank edges fall in scanlines relative to vsync. Turns a
		// "one scanline different" observation into a line number that can be
		// compared between clock rates, instead of being inferred from pixels.
		// Only prints when the numbers change, so a settled display costs one
		// line of output however long the run is.
		if (trace_video && clk_sys.IsRising()) {
			bool hs = VERTOPINTERN->VGA_HS;
			bool vs = VERTOPINTERN->VGA_VS;
			bool vb = VERTOPINTERN->VGA_VB;
			if (hs && !vt_hs_prev) vt_line++;
			if (vb && !vt_vb_prev) vt_vb_rise = vt_line;   // active -> blank
			if (!vb && vt_vb_prev) vt_vb_fall = vt_line;   // blank  -> active
			if (vs && !vt_vs_prev) {
				if (vt_line != vt_last_lines || vt_vb_rise != vt_last_rise ||
				    vt_vb_fall != vt_last_fall) {
					printf("[vid] frame %d: lines=%d  vblank_start=%d  vblank_end=%d"
					       "  active=%d\n", video.count_frame, vt_line,
					       vt_vb_rise, vt_vb_fall, vt_vb_rise - vt_vb_fall);
					vt_last_lines = vt_line;
					vt_last_rise  = vt_vb_rise;
					vt_last_fall  = vt_vb_fall;
				}
				vt_line = 0;
			}
			vt_hs_prev = hs; vt_vs_prev = vs; vt_vb_prev = vb;
		}

		if (clk_sys.IsRising() && VERTOPINTERN->CE_PIXEL) {
			uint32_t r = VERTOPINTERN->VGA_R;
			uint32_t g = VERTOPINTERN->VGA_G;
			uint32_t b = VERTOPINTERN->VGA_B;
			video.Clock(VERTOPINTERN->VGA_HB, VERTOPINTERN->VGA_VB,
			            VERTOPINTERN->VGA_HS, VERTOPINTERN->VGA_VS,
			            0xFF000000 | (b << 16) | (g << 8) | r);
		}

		if (clk_sys.IsRising()) {
			audio.Clock(VERTOPINTERN->AUDIO_L, VERTOPINTERN->AUDIO_R);

			// Our own decimation for playback and the scope. SimAudio does its
			// own internally but does not hand the samples back.
			if (++audio_div_cnt >= AUDIO_DIV) {
				audio_div_cnt = 0;
				int16_t s = (int16_t)VERTOPINTERN->AUDIO_L;
				audio_samples_made++;
				scope_buf[scope_pos] = s / 32768.0f;
				scope_pos = (scope_pos + 1) % SCOPE_N;
				if (audio_capture &&
				    audio_buf.size() < (size_t)AUDIO_RATE * AUDIO_CAP_SECS) {
					int16_t d = audio_dcblock(s);
					audio_buf.push_back(d);
					// "Is sound still arriving?" - track anything above the
					// noise the DC blocker leaves behind while settling.
					if (d > 256 || d < -256) { audio_sound_cnt++; audio_quiet_run = 0; }
					else                       audio_quiet_run++;
				}
			}
		}

		main_time++;
	}
}

static void resetSim()
{
	main_time = 0;
	top->reset = 1;
	clk_sys.Reset();
}

//----------------------------------------------------------------------------
// PNG screenshot
//----------------------------------------------------------------------------
// Prefix so parallel runs do not collide. Without it every run writes
// screenshot_00890.png into the CWD and the regression set silently overwrites
// its own evidence.
const char* screenshot_prefix = "screenshot_";

static void save_screenshot(int frame)
{
	if (!output_ptr) return;
	char name[512];
	snprintf(name, sizeof(name), "%s%05d.png", screenshot_prefix, frame);

	int w = video.output_width, h = video.output_height;
	vector<unsigned char> rgb((size_t)w * h * 3);
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			uint32_t px = output_ptr[(size_t)y * w + x];
			size_t o = ((size_t)y * w + x) * 3;
			rgb[o + 0] = (unsigned char)(px & 0xFF);
			rgb[o + 1] = (unsigned char)((px >> 8) & 0xFF);
			rgb[o + 2] = (unsigned char)((px >> 16) & 0xFF);
		}
	}
	if (stbi_write_png(name, w, h, 3, rgb.data(), w * 3))
		printf("Wrote %s (%dx%d)\n", name, w, h);
	else
		printf("Failed to write %s\n", name);
}

static bool stop_pc_reached()
{
	return stop_at_pc_enabled && VERTOPINTERN->debug_fetch &&
	       VERTOPINTERN->debug_pc == (stop_at_pc & 0xFFFF);
}

// --dump-mem ADDR[,LEN]: hex + disassembly of a memory region at stop time.
// An instruction trace only records opcodes at fetch addresses, so operand bytes
// - the n in CP n, the target of LD (nn),HL - are invisible in it. Those are
// usually the interesting part when a branch never flips.
int dump_mem_addr = -1;
int dump_mem_len  = 64;

static void dump_memory_region(void)
{
	if (dump_mem_addr < 0) return;
	printf("  Memory $%04X..$%04X:\n", dump_mem_addr,
	       dump_mem_addr + dump_mem_len - 1);
	for (int i = 0; i < dump_mem_len; i += 16) {
		printf("    %04X ", dump_mem_addr + i);
		for (int j = 0; j < 16 && i + j < dump_mem_len; j++)
			printf(" %02X", peek((uint16_t)(dump_mem_addr + i + j)));
		printf("  ");
		for (int j = 0; j < 16 && i + j < dump_mem_len; j++) {
			uint8_t c = peek((uint16_t)(dump_mem_addr + i + j));
			printf("%c", (c >= 32 && c < 127) ? c : '.');
		}
		printf("\n");
	}
	printf("  Disassembly:\n");
	uint16_t a = (uint16_t)dump_mem_addr;
	while (a < (uint16_t)(dump_mem_addr + dump_mem_len)) {
		char d[64];
		int len = z80_disasm(a, peek, d, sizeof(d));
		printf("    %04X  %-28s\n", a, d);
		a += (len > 0) ? len : 1;
	}
}

static void print_stop_state(const char* why)
{
	char dis[64];
	uint16_t pc = VERTOPINTERN->debug_pc;
	z80_disasm(pc, peek, dis, sizeof(dis));
	printf("%s\n  PC=%04X  op=%02X  %s\n  port50=%02X  frame=%d  ticks=%llu\n",
	       why, pc, VERTOPINTERN->debug_opcode, dis,
	       VERTOPINTERN->debug_port50, video.count_frame,
	       (unsigned long long)main_time);

#define CRTCR(reg) VERTOPINTERN->emu__DOT__core__DOT__crtc__DOT__##reg
	printf("  CRTC: R0 htotal=%d  R1 hdisp=%d  R2 hsync=%d  R3 syncw=$%02X\n"
	       "        R4 vtotal=%d  R5 vadj=%d  R6 vdisp=%d  R7 vsync=%d  R9 maxra=%d\n"
	       "        R12/13 start=$%04X  R14/15 cursor=$%04X\n",
	       CRTCR(r0_h_total), CRTCR(r1_h_disp), CRTCR(r2_h_sync_pos), CRTCR(r3_sync_width),
	       CRTCR(r4_v_total), CRTCR(r5_v_adjust), CRTCR(r6_v_disp), CRTCR(r7_v_sync_pos),
	       CRTCR(r9_max_ra), CRTCR(r12_13_start), CRTCR(r14_15_cursor));
#undef CRTCR

	printf("  Disk: sd_rd=%llu  sd_wr=%llu  acks=%llu  bytes=%llu  last_lba=%u\n",
	       (unsigned long long)sd_rd_reqs, (unsigned long long)sd_wr_reqs,
	       (unsigned long long)sd_acks, (unsigned long long)sd_bytes, sd_last_lba);
	printf("  Keyboard: R31 strobes=%llu  natural scans=%llu  light-pen hits=%llu\n",
	       (unsigned long long)kbd_r31_strobes, (unsigned long long)kbd_nat_scans,
	       (unsigned long long)kbd_lpen_hits);
	printf("  Audio: speaker toggles=%llu   PIO int acks=%llu\n",
	       (unsigned long long)spk_toggles, (unsigned long long)pio_int_acks);
	// Two separate facts, because they fail separately: playing ticks say the
	// start trigger fired at all, tape bytes say the transport then moved.
	// A flag that prints a banner and does nothing is the failure this catches.
	if (tape_file) {
		static const char* ts[8] = {"magic", "leader", "header", "data",
		                            "done", "?", "?", "?"};
		printf("  Tape: playing ticks=%llu  bytes fed=%u  state=%s  baud=%s"
		       "  pos=%u  data_left=%u\n",
		       (unsigned long long)tape_playing_ticks,
		       (unsigned)VERTOPINTERN->tape_bytes,
		       ts[VERTOPINTERN->emu__DOT__core__DOT__tape__DOT__state & 7],
		       (VERTOPINTERN->emu__DOT__core__DOT__tape__DOT__speed == 0) ? "300" :
		       (VERTOPINTERN->emu__DOT__core__DOT__tape__DOT__speed == 1) ? "600" : "1200",
		       (unsigned)VERTOPINTERN->emu__DOT__core__DOT__tape__DOT__byte_pos,
		       (unsigned)VERTOPINTERN->emu__DOT__core__DOT__tape__DOT__data_left);
		// A starved tape holds its output level, which the ROM reads as a
		// half-cycle that never ends - so it hangs rather than reporting an
		// error. Stalls must be ZERO on a healthy load.
		printf("        stalls=%u  fetches=%u  next_lba=%u/%u  busy=%u rew=%u"
		       " mnt=%u valid=%u fill=%u play=%u\n",
		       (unsigned)VERTOPINTERN->tape_stalls,
		       (unsigned)VERTOPINTERN->tape_fetches,
		       (unsigned)VERTOPINTERN->emu__DOT__core__DOT__tape__DOT__next_lba,
		       (unsigned)VERTOPINTERN->emu__DOT__core__DOT__tape__DOT__blocks_total,
		       (unsigned)VERTOPINTERN->emu__DOT__core__DOT__tape__DOT__sd_busy,
		       (unsigned)VERTOPINTERN->emu__DOT__core__DOT__tape__DOT__rew_req,
		       (unsigned)VERTOPINTERN->emu__DOT__core__DOT__tape__DOT__mounted,
		       (unsigned)VERTOPINTERN->emu__DOT__core__DOT__tape__DOT__half_valid,
		       (unsigned)VERTOPINTERN->emu__DOT__core__DOT__tape__DOT__fill_half,
		       (unsigned)VERTOPINTERN->emu__DOT__core__DOT__tape__DOT__play_half);
	}
	// Only when asked for, so no existing run's output moves. The tick count is
	// the quantity that says the control did something: a one-shot that never
	// reached the core still reboots the machine, and a reboot alone looks
	// exactly like a working Cold Boot on screen.
	if (cold_boot_ticks || cold_boot_frame >= 0) {
		printf("  Cold boot: clearing ticks=%llu (expect %d)\n",
		       (unsigned long long)cold_boot_ticks, 128 * 1024);
	}
	printf("  Disk scanner: var_size=%u  sectors=%u  bytes parsed=%u  "
	       "spt_size=%u  track_size=%u  hdrs=%u  sum=%u\n",
	       (unsigned)VERTOPINTERN->emu__DOT__core__DOT__fdc__DOT__var_size,
	       (unsigned)VERTOPINTERN->emu__DOT__core__DOT__fdc__DOT__edsk_size,
	       (unsigned)VERTOPINTERN->emu__DOT__core__DOT__fdc__DOT__dbg_bytes,
	       (unsigned)VERTOPINTERN->emu__DOT__core__DOT__fdc__DOT__spt_size,
	       (unsigned)VERTOPINTERN->emu__DOT__core__DOT__fdc__DOT__dbg_tsize,
	       (unsigned)VERTOPINTERN->emu__DOT__core__DOT__fdc__DOT__dbg_hdrs,
	       (unsigned)VERTOPINTERN->emu__DOT__core__DOT__fdc__DOT__dbg_sum);

	dump_memory_region();
}

//----------------------------------------------------------------------------
// Headless typing
//
// The mapping is the inverse of rtl/microbee_kbd.v, which is positional: a PC
// key drives the MicroBee key in the same place. So the shifted symbols follow
// the MicroBee's layout, not the PC's - Shift+2 is '"', Shift+6 is '&'. The
// table below encodes what character each MicroBee key actually produces.
//----------------------------------------------------------------------------
struct TypeKey { uint8_t code; bool shift; };

// --type-codes drives PS/2 scan codes directly, bypassing the table below. That
// matters for surveying the keyboard: the character a key produces comes from
// the MicroBee ROM, so asking "what does scan code $1E give me?" has to be
// possible WITHOUT assuming the answer, which --type cannot do because its
// lookup is the very mapping under test.
static std::vector<TypeKey> type_keys;

// "1E,s:1E,36" - comma separated hex scan codes, "s:" for held Shift.
static bool type_codes_parse(const char* s)
{
	while (*s) {
		TypeKey k; k.shift = false;
		if ((s[0] == 's' || s[0] == 'S') && s[1] == ':') { k.shift = true; s += 2; }
		char* end;
		long v = strtol(s, &end, 16);
		if (end == s || v < 0 || v > 0xFF) return false;
		k.code = (uint8_t)v;
		type_keys.push_back(k);
		s = end;
		if (*s == ',') s++;
		else if (*s) return false;
	}
	return !type_keys.empty();
}

// Which keys a US PC keyboard would press for a character. Used when the core
// is in symbolic mode, where that IS the mapping - so --type means "type this
// on a PC keyboard" rather than "type this on a MicroBee keyboard".
static bool type_lookup_us(char ch, TypeKey& out)
{
	static const uint8_t letters[26] = {
		0x1C, 0x32, 0x21, 0x23, 0x24, 0x2B, 0x34, 0x33, 0x43,  // a-i
		0x3B, 0x42, 0x4B, 0x3A, 0x31, 0x44, 0x4D, 0x15, 0x2D,  // j-r
		0x1B, 0x2C, 0x3C, 0x2A, 0x1D, 0x22, 0x35, 0x1A         // s-z
	};
	static const uint8_t digits[10] = {
		0x45, 0x16, 0x1E, 0x26, 0x25, 0x2E, 0x36, 0x3D, 0x3E, 0x46
	};
	static const char shifted_digits[] = ")!@#$%^&*(";

	out.shift = false;

	if (ch >= 'a' && ch <= 'z') { out.code = letters[ch - 'a']; return true; }
	if (ch >= 'A' && ch <= 'Z') { out.code = letters[ch - 'A']; out.shift = true; return true; }
	if (ch >= '0' && ch <= '9') { out.code = digits[ch - '0']; return true; }

	for (int d = 0; d <= 9; d++)
		if (ch == shifted_digits[d]) { out.code = digits[d]; out.shift = true; return true; }

	switch (ch) {
		case ' ':  out.code = 0x29; return true;
		case '\n': out.code = 0x5A; return true;
		case '\b': out.code = 0x66; return true;
		case '\t': out.code = 0x0D; return true;
		case '\033': out.code = 0x76; return true;

		case '`':  out.code = 0x0E; return true;
		case '-':  out.code = 0x4E; return true;
		case '=':  out.code = 0x55; return true;
		case '[':  out.code = 0x54; return true;
		case ']':  out.code = 0x5B; return true;
		case '\\': out.code = 0x5D; return true;
		case ';':  out.code = 0x4C; return true;
		case '\'': out.code = 0x52; return true;
		case ',':  out.code = 0x41; return true;
		case '.':  out.code = 0x49; return true;
		case '/':  out.code = 0x4A; return true;

		case '~':  out.code = 0x0E; out.shift = true; return true;
		case '_':  out.code = 0x4E; out.shift = true; return true;  // dead in the core
		case '+':  out.code = 0x55; out.shift = true; return true;
		case '{':  out.code = 0x54; out.shift = true; return true;
		case '}':  out.code = 0x5B; out.shift = true; return true;
		case '|':  out.code = 0x5D; out.shift = true; return true;
		case ':':  out.code = 0x4C; out.shift = true; return true;
		case '"':  out.code = 0x52; out.shift = true; return true;
		case '<':  out.code = 0x41; out.shift = true; return true;
		case '>':  out.code = 0x49; out.shift = true; return true;
		case '?':  out.code = 0x4A; out.shift = true; return true;
	}
	return false;
}

static bool type_lookup_positional(char ch, TypeKey& out)
{
	static const uint8_t letters[26] = {
		0x1C, 0x32, 0x21, 0x23, 0x24, 0x2B, 0x34, 0x33, 0x43,  // a-i
		0x3B, 0x42, 0x4B, 0x3A, 0x31, 0x44, 0x4D, 0x15, 0x2D,  // j-r
		0x1B, 0x2C, 0x3C, 0x2A, 0x1D, 0x22, 0x35, 0x1A         // s-z
	};
	static const uint8_t digits[10] = {
		0x45, 0x16, 0x1E, 0x26, 0x25, 0x2E, 0x36, 0x3D, 0x3E, 0x46
	};
	// MicroBee shifted digit row: 0 1 2 3 4 5 6 7 8 9 -> (none) ! " # $ % & ' ( )
	static const char shifted_digits[] = "\0!\"#$%&'()";

	out.shift = false;

	if (ch >= 'a' && ch <= 'z') { out.code = letters[ch - 'a']; return true; }
	if (ch >= 'A' && ch <= 'Z') { out.code = letters[ch - 'A']; out.shift = true; return true; }
	if (ch >= '0' && ch <= '9') { out.code = digits[ch - '0']; return true; }

	for (int d = 1; d <= 9; d++)
		if (ch == shifted_digits[d]) { out.code = digits[d]; out.shift = true; return true; }

	switch (ch) {
		case ' ':  out.code = 0x29; return true;   // Space
		case '\n': out.code = 0x5A; return true;   // Enter
		case '\b': out.code = 0x66; return true;   // Backspace
		case '\t': out.code = 0x0D; return true;   // Tab
		case '\033': out.code = 0x76; return true; // Escape

		// Symbol keys, unshifted
		case '@':  out.code = 0x0E; return true;   // PC grave
		case '[':  out.code = 0x54; return true;
		case '\\': out.code = 0x5D; return true;
		case ']':  out.code = 0x5B; return true;
		case '^':  out.code = 0x55; return true;   // PC '='
		case ':':  out.code = 0x4C; return true;   // PC ';'
		case ';':  out.code = 0x52; return true;   // PC quote
		case ',':  out.code = 0x41; return true;
		case '-':  out.code = 0x4E; return true;
		case '.':  out.code = 0x49; return true;
		case '/':  out.code = 0x4A; return true;

		// ...and shifted
		case '`':  out.code = 0x0E; out.shift = true; return true;
		case '{':  out.code = 0x54; out.shift = true; return true;
		case '|':  out.code = 0x5D; out.shift = true; return true;
		case '}':  out.code = 0x5B; out.shift = true; return true;
		case '~':  out.code = 0x55; out.shift = true; return true;
		case '*':  out.code = 0x4C; out.shift = true; return true;
		case '+':  out.code = 0x52; out.shift = true; return true;
		case '<':  out.code = 0x41; out.shift = true; return true;
		case '=':  out.code = 0x4E; out.shift = true; return true;
		case '>':  out.code = 0x49; out.shift = true; return true;
		case '?':  out.code = 0x4A; out.shift = true; return true;
	}
	return false;
}

static bool type_lookup(char ch, TypeKey& out)
{
	return kbd_symbolic ? type_lookup_us(ch, out) : type_lookup_positional(ch, out);
}

// \n, \t, \e and \\ in the --type argument, so the shell doesn't have to.
static const char* type_unescape(const char* s)
{
	char* out = (char*)malloc(strlen(s) + 1);
	char* w = out;
	for (const char* r = s; *r; r++) {
		if (*r != '\\' || !r[1]) { *w++ = *r; continue; }
		switch (*++r) {
			case 'n': *w++ = '\n'; break;
			case 't': *w++ = '\t'; break;
			case 'e': *w++ = '\033'; break;
			case 'b': *w++ = '\b'; break;
			case '\\': *w++ = '\\'; break;
			default: *w++ = '\\'; *w++ = *r; break;
		}
	}
	*w = 0;
	return out;
}

// The core detects a key event by the strobe in ps2_key[10] changing, so only
// one event can be delivered per write. Queue them and emit one per frame -
// writing twice before the RTL runs toggles the strobe back and the event
// vanishes silently, which is exactly how a stuck key gets you 20 of the same
// character.
struct Ps2Event { uint8_t code; bool ext; bool pressed; };
static std::queue<Ps2Event> ps2_queue;

static void ps2_push(uint8_t code, bool pressed, bool ext = false)
{
	Ps2Event e; e.code = code; e.ext = ext; e.pressed = pressed;
	ps2_queue.push(e);
}

static void ps2_pump()
{
	if (ps2_queue.empty()) return;
	static bool strobe = false;
	strobe = !strobe;
	Ps2Event e = ps2_queue.front();
	ps2_queue.pop();
	VERTOPINTERN->ps2_key = (SData)(e.code | (e.ext ? (1 << 8) : 0) |
	                                (e.pressed ? (1 << 9) : 0) | (strobe ? (1 << 10) : 0));
}

//----------------------------------------------------------------------------
// Interactive key pacing.
//
// The simulation runs roughly 20x slower than the real machine, so one
// emulated frame takes about 0.4s of wall time. The MicroBee's key matrix is
// scanned through the light pen once per frame, so a normal ~100ms keypress
// covers only about a quarter of a frame and the scan usually never sees it -
// keys get silently dropped rather than merely delayed.
//
// So key events are paced in EMULATED frames, not wall time: each one is held
// long enough for at least one full matrix scan. Typing ahead is fine, the
// queue drains at the machine's own pace.
//----------------------------------------------------------------------------
int key_dwell_frames = 2;    // emulated frames between key events

static void ps2_service_interactive()
{
	static int last_pump_frame = -1000;
	if (ps2_queue.empty()) return;
	if (video.count_frame - last_pump_frame < key_dwell_frames) return;
	last_pump_frame = video.count_frame;
	ps2_pump();
}

// Called once per outer loop iteration; acts only when the frame number moves.
static void type_service()
{
	if (type_keys.empty()) return;

	static int  last_frame  = -1;
	static bool key_down    = false;
	static bool shift_down  = false;
	static uint8_t cur_code = 0;

	int frame = video.count_frame;
	if (frame == last_frame) return;
	last_frame = frame;

	if (frame < type_start_frame) return;

	int slot_len = type_hold + type_gap;
	int elapsed  = frame - type_start_frame;
	size_t index = (size_t)(elapsed / slot_len);
	int    phase = elapsed % slot_len;

	if (index >= type_keys.size()) {
		if (key_down)   { ps2_push(cur_code, false); key_down = false; }
		if (shift_down) { ps2_push(0x12, false); shift_down = false; }
		ps2_pump();
		if (type_done_frame < 0 && ps2_queue.empty()) {
			type_done_frame = frame;
			printf("Finished typing at frame %d.\n", frame);
		}
		return;
	}

	TypeKey k = type_keys[index];

	// Shift leads the key by a frame and releases a frame after it, so no two
	// transitions land on the same frame and the ROM never sees the key without
	// its modifier.
	bool want_shift = k.shift && (phase < type_hold + 2);
	bool want_key   = (phase >= 1) && (phase < type_hold + 1);

	if (want_shift != shift_down) { ps2_push(0x12, want_shift); shift_down = want_shift; }
	if (want_key   != key_down)   { cur_code = k.code; ps2_push(k.code, want_key); key_down = want_key; }

	ps2_pump();
}

//----------------------------------------------------------------------------
// Dump the text screen. Reads screen RAM directly rather than the framebuffer,
// so it says what the machine thinks it wrote, independent of video timing.
//----------------------------------------------------------------------------
static void dump_screen()
{
	uint16_t start = VERTOPINTERN->emu__DOT__core__DOT__crtc__DOT__r12_13_start;
	int cols = VERTOPINTERN->emu__DOT__core__DOT__crtc__DOT__r1_h_disp;
	int rows = VERTOPINTERN->emu__DOT__core__DOT__crtc__DOT__r6_v_disp;
	if (cols <= 0 || cols > 128) cols = 64;
	if (rows <= 0 || rows > 64)  rows = 16;

	printf("Screen (%dx%d, start=$%04X):\n", cols, rows, start);
	for (int y = 0; y < rows; y++) {
		printf("  |");
		for (int x = 0; x < cols; x++) {
			uint16_t a = (uint16_t)((start + y * cols + x) & 0x7FF);
			uint8_t  raw = VERTOPINTERN->emu__DOT__core__DOT__video_inst__DOT__scrram[a];
			uint8_t  c = raw & 0x7F;         // bit 7 selects PCG, not a code
			// Bit 7 set means the glyph comes from PCG RAM, not the character
			// ROM - a completely different picture for the same printed
			// character. Masking it silently made a PCG 0xFB read as '{' and a
			// PCG 0xA0 read as a space, which cost real time twice. Mark it.
			char ch = (c >= 0x20 && c < 0x7F) ? (char)c : ' ';
			putchar((raw & 0x80) ? '~' : ch);
		}
		printf("|\n");
		if (dump_screen_hex) {
			printf("  h|");
			for (int x = 0; x < cols; x++) {
				uint16_t a = (uint16_t)((start + y * cols + x) & 0x7FF);
				uint8_t  raw = VERTOPINTERN->emu__DOT__core__DOT__video_inst__DOT__scrram[a];
				printf("%02X", raw);
			}
			printf("|\n");
		}
		// Colour and attribute RAM, per cell. What the picture LOOKS like
		// depends on which frame you caught and what the software drew; these
		// bytes say what the machine was actually told to render, which is the
		// only way to tell "our decode is wrong" from "that screen really is
		// magenta". c = colour (low nibble foreground, high background),
		// a = attribute (bank in [3:0], inverse [6], flash [7]).
		if (dump_colour) {
			printf("  c|");
			for (int x = 0; x < cols; x++) {
				uint16_t a = (uint16_t)((start + y * cols + x) & 0x7FF);
				printf("%02X", VERTOPINTERN->emu__DOT__core__DOT__video_inst__DOT__colram[a]);
			}
			printf("|\n  a|");
			for (int x = 0; x < cols; x++) {
				uint16_t a = (uint16_t)((start + y * cols + x) & 0x7FF);
				printf("%02X", VERTOPINTERN->emu__DOT__core__DOT__video_inst__DOT__attram[a]);
			}
			printf("|\n");
		}
	}
}

static void show_help()
{
	printf(
	"Verilator harness - MicroBee 64K CIAB\n"
	"\n"
	"  --rom-slot N FILE      load FILE into bootN.rom slot N. The only ROM\n"
	"                         argument, and the same files hardware loads.\n"
	"                         MiSTer auto-loads boot0-boot3 and no further:\n"
	"                           slot 0  boot0.rom  36K  MANDATORY bundle -\n"
	"                                   bn54 + charrom + basic_5.22e + bn56,\n"
	"                                   build it with: make ../release/boot0.rom\n"
	"                           slot 1  wordbee_1.2.rom  8K  $C000  (32K IC)\n"
	"                           slot 2  telcom_1.0.rom   4K  $E000  (32K IC)\n"
	"                           slot 3  free\n"
	"  --phosphor C           colour | amber | green | white (default colour).\n"
	"                         Mirrors the OSD. Naming a tube views a Premium on\n"
	"                         a mono monitor; a machine with no colour board\n"
	"                         ignores 'colour' and shows amber, as MAME does.\n"
	"  --positional           pure positional keyboard, as the hardware does it.\n"
	"                         Default is symbolic: symbol keys give what a US\n"
	"                         keycap says, so --type takes PC-layout characters.\n"
	"  --audio-file FILE.wav  capture audio to a 16-bit mono WAV. Works headless.\n"
	"                         Accurate in emulated time, so pitch and duration\n"
	"                         are right even though the sim runs ~22x slow.\n"
	"                         The GUI also plays audio in bursts - see the\n"
	"                         Audio output window - but only a capture is gapless.\n"
	"  --model NAME           64k | p64k | ic | p128k  (default 64k). Names are\n"
	"                         ubee512's. Same encoding as the OSD. Every model's\n"
	"                         ROM1 lives in the slot-0 bundle, so the same\n"
	"                         boot0.rom serves all of them - only --model picks\n"
	"                         which bank the machine runs. 64k/p64k/p128k want\n"
	"                         a --disk; ic has no FDC fitted.\n"
	"  --boot-basic           run the BASIC image instead of the model's own\n"
	"                         ROM1, and take the vsync tick with it. Needs no\n"
	"                         extra file - BASIC is already in the bundle.\n"
	"  --piob7-vsync          PIO port B bit 7 = vsync, not a pull-up. Needed\n"
	"                         by ROM-BASIC models, which take their 50 Hz timer\n"
	"                         from it. The 64K CIAB wants the default.\n"
	"  --disk FILE            mount a floppy image on drive A: (M4)\n"
	"  --headless             run without a window\n"
	"  --trace-video          report vertical blank edges in scanlines per frame,\n"
	"                         printing only when they change. Use to compare\n"
	"                         display geometry between --fast and the 54 MHz\n"
	"                         default without inferring it from screenshots.\n"
	"  --fast                 clock the core at 13.5 MHz instead of the 54 MHz\n"
	"                         hardware rate. ~4.5x faster to simulate and every\n"
	"                         clock-enable ratio is identical, because 54 MHz\n"
	"                         exists only to feed MiSTer's scandoubler and there\n"
	"                         is no scandoubler here. Omit it to reproduce a\n"
	"                         result against the true hardware configuration.\n"
	"  --type STRING          headless: type STRING once the machine has booted.\n"
	"                         Layout is the MicroBee's, so \\\" is Shift+2 and & is\n"
	"                         Shift+6. Use \\n for Enter. Stops 30 frames after.\n"
	"  --type-codes LIST      headless: type raw PS/2 set-2 scan codes instead of\n"
	"                         characters - comma separated hex, s: prefix holds\n"
	"                         Shift, e.g. '1E,s:1E,36'. Use this to survey what a\n"
	"                         key actually produces; --type cannot, because its\n"
	"                         lookup assumes the mapping you are trying to test.\n"
	"  --type-start N         frame to start typing at (default 150)\n"
	"  --type-hold N          frames each key is held (default 4)\n"
	"  --type-gap N           frames between keys (default 4)\n"
	"  --dump-screen          print screen RAM as text when the run stops.\n"
	"                         A PCG cell (bit 7 set) prints as ~, because its\n"
	"                         glyph comes from PCG RAM, not the character ROM.\n"
	"  --dump-screen-hex      as --dump-screen, plus raw bytes under each row\n"
	"  --dump-colour          as --dump-screen, plus Premium colour RAM (c|) and\n"
	"                         attribute RAM (a|) per cell. c low nibble is the\n"
	"                         foreground, high nibble the background.\n"
	"  --trace [FILE]         write a Z80 instruction trace (default cpu_trace.log)\n"
	"  --trace-limit N        stop tracing after N instructions\n"
	"  --stop-at-pc ADDR      stop when the CPU fetches from ADDR\n"
	"  --trace-from-pc ADDR   hold the instruction trace off until the CPU first\n"
	"                         fetches from ADDR, then trace from there. Implies\n"
	"                         --trace. Use with --trace-limit to capture a hang\n"
	"                         without writing the whole boot to disk.\n"
	"  --stop-at-frame N      stop after N video frames\n"
	"  --screenshot-frame N   write screenshot_NNNNN.png at frame N (repeatable)\n"
	"  --screenshot-prefix P  use P instead of 'screenshot_', so parallel runs do\n"
	"                         not overwrite each other. May include a directory.\n"
	"  --max-ticks N          stop after N simulation ticks\n"
	"  --tape FILE            mount a DGOS .tap cassette image (block slot 1).\n"
	"                         Playback starts by itself when the machine enters\n"
	"                         its tape sampling loop - type LOAD in BASIC.\n"
	"  --no-tape-audio        do not mix the tape tone into the audio output\n"
	"  --tape-rewind N        pulse the OSD's Rewind Tape control at frame N\n"
	"  --cold-boot N          pulse the OSD's Cold Boot control at frame N. Zeroes\n"
	"                         DRAM with the machine held in reset - a power cycle\n"
	"                         rather than the reset button, which on a real\n"
	"                         MicroBee is ESC held during RESET. The stop report\n"
	"                         counts the ticks it actually spent clearing.\n"
	"  --reset N              plain reset at frame N - Cold Boot's negative\n"
	"                         control. On the 32K IC a reset warm-starts to a\n"
	"                         bare > and a cold boot reprints the banner, so run\n"
	"                         both to show the clear did something.\n"
	"  --piob-log FILE        log every CPU read of PIO port B data as\n"
	"                         'tick PC value'. The tape start trigger has to\n"
	"                         separate a tape sampling loop from the 50 Hz vsync\n"
	"                         poll, and read spacing is what distinguishes them.\n"
	"  --help                 this text\n");
}

//----------------------------------------------------------------------------
int main(int argc, char** argv)
{
	vector<string> diskFiles;
	// --rom-slot N FILE. Explicit slot loads, for models whose ROM set is more
	// than one image: the 32K IC runs BASIC (slot 2, via --rom) plus WordBee
	// (slot 4) and Telcom (slot 5). Kept separate from --rom, which routes to
	// whichever slot the selected model reads.
	vector<pair<int, string>> slotFiles;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) { show_help(); return 0; }
		else if (!strcmp(argv[i], "--headless")) headless = true;
		else if (!strcmp(argv[i], "--fast")) fast_clock = true;
		else if (!strcmp(argv[i], "--trace-video")) trace_video = true;
		else if (!strcmp(argv[i], "--dump-mem") && i + 1 < argc) {
			const char* s = argv[++i];
			dump_mem_addr = (int)strtoul(s, NULL, 0);
			const char* c = strchr(s, ',');
			if (c) dump_mem_len = (int)strtoul(c + 1, NULL, 0);
		}
		else if (!strcmp(argv[i], "--rom-slot") && i + 2 < argc) {
			int slot = (int)strtoul(argv[++i], NULL, 0);
			slotFiles.push_back(make_pair(slot, string(argv[++i])));
		}
		else if (!strcmp(argv[i], "--model") && i + 1 < argc) {
			const char* m = argv[++i];
			// Names are ubee512's, from its model table at ubee512.c:579 -
			// the same source microbee_models.v is transcribed from, so a
			// command line reads the same as the reference.
			// `ciab` and `ic32` are accepted as aliases; earlier sessions and
			// docs used them.
			model = (!strcmp(m, "64k")  || !strcmp(m, "ciab")) ? 0
			      :  !strcmp(m, "p64k")                        ? 1
			      : (!strcmp(m, "ic")   || !strcmp(m, "ic32")) ? 2
			      :  !strcmp(m, "p128k")                       ? 3
			      : atoi(m);
		}
		else if (!strcmp(argv[i], "--boot-basic")) boot_basic = 1;
		else if (!strcmp(argv[i], "--audio-file") && i + 1 < argc) audio_file = argv[++i];
		else if (!strcmp(argv[i], "--trace-from-pc") && i + 1 < argc) {
			cpu_trace_from_pc = (int)strtoul(argv[++i], NULL, 0);
			cpu_trace_enable = true;
		}
		else if (!strcmp(argv[i], "--piob7-vsync")) piob7_vs = 1;
		else if (!strcmp(argv[i], "--positional")) kbd_symbolic = false;
		else if (!strcmp(argv[i], "--phosphor") && i + 1 < argc) {
			const char* p = argv[++i];
			// "colour" keeps use_colour set; naming any tube clears it, which
			// is how you view a Premium on a mono monitor.
			use_colour = (!strcmp(p, "colour") || !strcmp(p, "color"));
			phosphor = !strcmp(p, "green") ? 0 : !strcmp(p, "white") ? 2 : 1;
		}
		else if (!strcmp(argv[i], "--disk") && i + 1 < argc) diskFiles.push_back(argv[++i]);
		else if (!strcmp(argv[i], "--trace")) {
			cpu_trace_enable = true;
			if (i + 1 < argc && argv[i + 1][0] != '-') cpu_trace_filename = argv[++i];
		}
		else if (!strcmp(argv[i], "--trace-limit") && i + 1 < argc)
			cpu_trace_limit = strtoull(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "--stop-at-pc") && i + 1 < argc) {
			stop_at_pc = (uint32_t)strtoul(argv[++i], NULL, 0);
			stop_at_pc_enabled = true;
		}
		else if (!strcmp(argv[i], "--stop-at-frame") && i + 1 < argc) {
			stop_at_frame = atoi(argv[++i]);
			stop_at_frame_enabled = true;
		}
		else if (!strcmp(argv[i], "--type") && i + 1 < argc) type_string = type_unescape(argv[++i]);
		else if (!strcmp(argv[i], "--type-codes") && i + 1 < argc) {
			if (!type_codes_parse(argv[++i])) {
				fprintf(stderr, "Bad --type-codes list: %s\n", argv[i]);
				return 1;
			}
		}
		else if (!strcmp(argv[i], "--type-start") && i + 1 < argc) type_start_frame = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--type-hold") && i + 1 < argc) type_hold = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--type-gap") && i + 1 < argc) type_gap = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--dump-screen")) dump_screen_enabled = true;
		else if (!strcmp(argv[i], "--dump-screen-hex")) { dump_screen_enabled = true; dump_screen_hex = true; }
		else if (!strcmp(argv[i], "--dump-colour")) { dump_screen_enabled = true; dump_colour = true; }
		else if (!strcmp(argv[i], "--tape") && i + 1 < argc) tape_file = argv[++i];
		else if (!strcmp(argv[i], "--no-tape-audio")) tape_audio_en = false;
		else if (!strcmp(argv[i], "--tape-trace")) tape_trace = true;
		else if (!strcmp(argv[i], "--tape-rewind") && i + 1 < argc) tape_rewind_frame = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--cold-boot") && i + 1 < argc) cold_boot_frame = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--reset") && i + 1 < argc) reset_frame = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--piob-log") && i + 1 < argc) {
			piob_log_file = fopen(argv[++i], "w");
			if (!piob_log_file) { printf("Cannot open port B log\n"); return 1; }
		}
		else if (!strcmp(argv[i], "--fdc-log") && i + 1 < argc) {
			fdc_log_file = fopen(argv[++i], "w");
			if (!fdc_log_file) { printf("Cannot open FDC log\n"); return 1; }
		}
		else if (!strcmp(argv[i], "--screenshot-frame") && i + 1 < argc)
			screenshot_frames.push_back(atoi(argv[++i]));
		else if (!strcmp(argv[i], "--screenshot-prefix") && i + 1 < argc)
			screenshot_prefix = argv[++i];
		else if (!strcmp(argv[i], "--max-ticks") && i + 1 < argc) {
			max_ticks = strtoull(argv[++i], NULL, 0);
			max_ticks_enabled = true;
		}
		else { printf("Unknown argument: %s\n", argv[i]); show_help(); return 1; }
	}

	// --type is --type-codes with a lookup in front of it. Characters the
	// MicroBee has no key for are dropped rather than silently typed as
	// something else.
	if (type_string) {
		for (const char* p = type_string; *p; p++) {
			TypeKey k;
			if (type_lookup(*p, k)) type_keys.push_back(k);
			else fprintf(stderr, "--type: no MicroBee key for '%c', skipped\n", *p);
		}
	}

	{
		bool have0 = false;
		for (size_t s = 0; s < slotFiles.size(); s++)
			if (slotFiles[s].first == 0) have0 = true;
		if (!have0) {
			printf("Need --rom-slot 0 (the mandatory boot0.rom bundle).\n\n"
			       "  64K CIAB (boots to CP/M, needs a disk):\n"
			       "    --rom-slot 0 ../release/boot0.rom --disk ../release/ciabmaster.dsk\n\n"
			       "  32K IC (boots straight to BASIC, option ROMs in slots 1 and 2):\n"
			       "    --model ic --rom-slot 0 ../release/boot0.rom \\\n"
			       "      --rom-slot 1 ../release/wordbee_1.2.rom \\\n"
			       "      --rom-slot 2 ../release/telcom_1.0.rom\n\n"
			       "  Build the bundle with:  make ../release/boot0.rom\n\n");
			show_help();
			return 1;
		}
	}

	// Check the images up front. SimBus only logs a failure to the ImGui debug
	// window, which prints nothing in headless mode - and a missing character
	// ROM looks like a working machine with invisible text, because every
	// glyph fetches as zero and only the inverted cursor cell shows.
	{
		bool ok = true;
		// --rom-slot images. Reported as well as checked: a slot load that
		// silently did nothing is indistinguishable from a decode that dropped
		// it, and that ambiguity is what BUG-004 was.
		for (size_t s = 0; s < slotFiles.size(); s++) {
			FILE* f = fopen(slotFiles[s].second.c_str(), "rb");
			if (!f) {
				printf("ERROR: cannot open slot %d image: %s\n",
				       slotFiles[s].first, slotFiles[s].second.c_str());
				ok = false;
				continue;
			}
			fseek(f, 0, SEEK_END);
			long n = ftell(f);
			char label[16];
			snprintf(label, sizeof(label), "slot %d", slotFiles[s].first);
			printf("%-9s %-44s %ld bytes\n", label, slotFiles[s].second.c_str(), n);

			// Slot 0 is the mandatory bundle. Same six signature bytes the core
			// checks (see microbee.sv) - a mis-ordered bundle is exactly 36,864
			// bytes like a correct one, so length alone cannot see it, and bn54
			// and bn56 share their first four bytes so only offset 5 separates
			// them. Warn rather than fail: an unusual bundle may be deliberate.
			if (slotFiles[s].first == 0) {
				static const struct { long off; unsigned char val; const char* what; } sig[] = {
					{ 0x0000, 0xF3, "bn54 DI" },
					{ 0x0005, 0x00, "bn54 (not bn56)" },
					{ 0x2004, 0x7F, "char ROM glyph 0" },
					{ 0x3000, 0xC3, "BASIC JP" },
					{ 0x7000, 0xF3, "bn56 DI" },
					{ 0x7005, 0x40, "bn56 (not bn54)" },
				};
				if (n != 36864)
					printf("WARNING: boot0.rom is %ld bytes, expected 36864\n", n);
				for (auto& g : sig) {
					unsigned char got = 0;
					if (g.off >= n) { printf("WARNING: boot0.rom too short for 0x%04lX (%s)\n",
					                         g.off, g.what); continue; }
					fseek(f, g.off, SEEK_SET);
					if (fread(&got, 1, 1, f) == 1 && got != g.val)
						printf("WARNING: boot0.rom 0x%04lX = %02X, expected %02X (%s)"
						       " - wrong order or wrong image?\n",
						       g.off, got, g.val, g.what);
				}
			}
			fclose(f);
		}
		if (!ok) {
			printf("\nPaths are relative to the current directory. From verilator/:\n"
			       "  make run-basic     BASIC in ROM\n"
			       "  make run-ciab      64K CIAB\n");
			return 2;
		}
	}

	top = new Vemu();
	Verilated::commandArgs(argc, argv);

	// Bind the HPS emulation to the DUT.
	bus.ioctl_addr     = &VERTOPINTERN->ioctl_addr;
	bus.ioctl_index    = &VERTOPINTERN->ioctl_index;
	bus.ioctl_wait     = &VERTOPINTERN->ioctl_wait;
	bus.ioctl_download = &VERTOPINTERN->ioctl_download;
	bus.ioctl_wr       = &VERTOPINTERN->ioctl_wr;
	bus.ioctl_dout     = &VERTOPINTERN->ioctl_dout;
	// SimInput is not allowed to drive the core directly - we drain its event
	// queue and pace the events ourselves in emulated frames. Give it a
	// scratch variable to write to so its own path stays harmless.
	static SData ps2_key_scratch = 0;
	input.ps2_key      = &ps2_key_scratch;

	blockdevice.sd_lba[0]      = &VERTOPINTERN->sd_lba[0];
	blockdevice.sd_lba[1]      = &VERTOPINTERN->sd_lba[1];
	blockdevice.sd_rd          = &VERTOPINTERN->sd_rd;
	blockdevice.sd_wr          = &VERTOPINTERN->sd_wr;
	blockdevice.sd_ack         = &VERTOPINTERN->sd_ack;
	blockdevice.sd_buff_addr   = &VERTOPINTERN->sd_buff_addr;
	blockdevice.sd_buff_dout   = &VERTOPINTERN->sd_buff_dout;
	blockdevice.sd_buff_din[0] = &VERTOPINTERN->sd_buff_din[0];
	blockdevice.sd_buff_din[1] = &VERTOPINTERN->sd_buff_din[1];
	blockdevice.sd_buff_wr     = &VERTOPINTERN->sd_buff_wr;
	blockdevice.img_mounted    = &VERTOPINTERN->img_mounted;
	blockdevice.img_size       = &VERTOPINTERN->img_size;

	for (size_t d = 0; d < diskFiles.size() && d < 1; d++)
		blockdevice.MountDisk(diskFiles[d], (int)d);

	// Slot 1 is the cassette, not a second floppy. Drive B: is M8-2 and will
	// want its own slot when it lands.
	if (tape_file) blockdevice.MountDisk(string(tape_file), 1);

	// The bootN.rom slot number goes in ioctl_index[15:6], which is how MiSTer
	// delivers it - so slot N is sent as N<<6. Not a detail: two different wrong
	// decodes of this reached hardware, the second writing every ROM into bank 0
	// and stopping the machine from booting at all. Sending it the hardware way
	// here is what lets the harness catch that class of bug at all.
	//
	// --rom-slot is now the ONLY ROM argument, and slot 0 takes the same
	// boot0.rom the hardware loads. --rom/--charrom used to route by model and
	// assemble things here, which meant the harness could differ from what
	// hps_io actually delivers - the exact divergence that hid BUG-011 until a
	// board found it. Loading the identical file removes the question.
	for (size_t s = 0; s < slotFiles.size(); s++)
		bus.QueueDownload(slotFiles[s].second, slotFiles[s].first << 6, true);

	// Apply --fast. Three things have to agree about the master clock: the RTL's
	// enable masks, the audio decimator, and the block-device model's latencies
	// (which are real-time delays expressed in ticks). Setting only some of them
	// silently changes how the disk is timed relative to the CPU.
	// sim_fast itself is driven every edge in the tick loop, alongside model and
	// piob7_vs. Only the tick-to-real-time conversions are set once, here.
	if (fast_clock) clk_sys_hz = CLK_SYS_HZ_FAST;
	AUDIO_DIV = clk_sys_hz / AUDIO_RATE;
	audio.SetSystemClock(clk_sys_hz);
	SimBlockDevice_SetClockHz(clk_sys_hz);
	printf("clk_sys = %.1f MHz%s\n", clk_sys_hz / 1e6, fast_clock ? " (--fast)" : "");

	input.Initialise();
#ifdef WIN32
	input.SetMapping(0, DIK_RIGHT);
#else
	input.SetMapping(0, SDL_SCANCODE_RIGHT);
#endif

	if (headless) { if (video.InitialiseHeadless() == 1) return 1; }
	else if (video.Initialise(windowTitle) == 1) return 1;

	if (cpu_trace_enable) {
		cpu_trace_file = fopen(cpu_trace_filename, "w");
		if (cpu_trace_file) printf("CPU trace -> %s\n", cpu_trace_filename);
		else { printf("Cannot open trace file %s\n", cpu_trace_filename); cpu_trace_enable = false; }
	}

	//------------------------------------------------------------------------
	// Open an SDL audio device for chunked playback (GUI only).
	//------------------------------------------------------------------------
	if (!headless) {
		if (SDL_InitSubSystem(SDL_INIT_AUDIO) != 0) {
			printf("No SDL audio (%s) - playback disabled, --audio-file still works\n",
			       SDL_GetError());
		}
		else {
			SDL_AudioSpec want, have;
			SDL_zero(want);
			want.freq     = AUDIO_RATE;
			want.format   = AUDIO_S16SYS;
			want.channels = 1;
			want.samples  = 1024;
			want.callback = NULL;          // queue-driven, not callback-driven
			audio_dev = SDL_OpenAudioDevice(NULL, 0, &want, &have, 0);
			if (!audio_dev) {
				printf("Cannot open audio device (%s) - playback disabled\n", SDL_GetError());
			}
			else {
				// SDL opens devices paused. Leave it running: an empty queue is
				// silence, which is genuinely silent now DC is removed.
				SDL_PauseAudioDevice(audio_dev, 0);
				audio_buf.reserve((size_t)AUDIO_RATE * AUDIO_CAP_SECS);
				printf("Audio: %d Hz mono. Capturing to a %d s buffer - watch it "
				       "fill in the Audio output window, then press Play buffer. "
				       "The sim is far too slow to play live.\n",
				       have.freq, AUDIO_CAP_SECS);
			}
		}
	}

	// Capture works headless too - it is just a file write, no audio device.
	if (audio_file) {
		audio.SetOutputFile(audio_file);
		printf("Audio capture -> %s   (16-bit PCM mono WAV)\n", audio_file);
	}
	audio.Initialise();

	//------------------------------------------------------------------------
	// Headless: run to a stop condition and exit.
	//------------------------------------------------------------------------
	if (headless) {
		bool done = false;
		while (!done) {
			for (int step = 0; step < batchSize; step++) {
				verilate();
				if (stop_pc_reached()) {
					print_stop_state("Reached --stop-at-pc.");
					done = true; break;
				}
				if (max_ticks_enabled && main_time >= max_ticks) {
					print_stop_state("Reached --max-ticks.");
					done = true; break;
				}
			}
			if (done) break;

			type_service();
			// The 30-frame tail after the last key is only a *default* stop, for
			// runs that just want to see the effect of what was typed. An explicit
			// --stop-at-frame always wins: typed input that kicks off disk activity
			// (RETURN at the CIAB menu loads CP/M) needs far longer than 30 frames,
			// and silently stopping early looks exactly like the machine hanging.
			if (!stop_at_frame_enabled &&
			    type_done_frame >= 0 && video.count_frame >= type_done_frame + 30) {
				print_stop_state("Typing complete.");
				break;
			}

			if (tape_rewind_frame >= 0 && video.count_frame >= tape_rewind_frame) {
				tape_rewind_pulse = true;
				tape_rewind_frame = -1;
			}

			if (cold_boot_frame >= 0 && video.count_frame >= cold_boot_frame) {
				cold_boot_pulse = true;
				cold_boot_frame = -1;
			}

			if (reset_frame >= 0 && video.count_frame >= reset_frame) {
				reset_until = main_time + 4000;
				reset_frame = -1;
			}

			if (!screenshot_frames.empty()) {
				auto it = find(screenshot_frames.begin(), screenshot_frames.end(), video.count_frame);
				if (it != screenshot_frames.end()) {
					save_screenshot(video.count_frame);
					screenshot_frames.erase(it);
				}
			}
			if (stop_at_frame_enabled && video.count_frame >= stop_at_frame) {
				print_stop_state("Reached --stop-at-frame.");
				break;
			}
		}
		if (dump_screen_enabled) dump_screen();
		if (cpu_trace_file) fclose(cpu_trace_file);
		if (fdc_log_file) fclose(fdc_log_file);
		if (piob_log_file) fclose(piob_log_file);
		audio.CleanUp();
		top->final();
		video.CleanUpHeadless();
		return 0;
	}

	//------------------------------------------------------------------------
	// Interactive
	//------------------------------------------------------------------------
	bool quit = false;
	while (!quit) {
#ifndef _MSC_VER
		SDL_Event e;
		while (SDL_PollEvent(&e)) {
			ImGui_ImplSDL2_ProcessEvent(&e);
			if (e.type == SDL_QUIT) quit = true;
		}
#endif
		// SimVideo owns the frame lifecycle: StartFrame() is the backend
		// NewFrame, UpdateTexture() at the bottom does ImGui::Render() and
		// presents. Don't duplicate either of them here.
		video.StartFrame();
		ImGui::NewFrame();

		input.Read();

		// Take the key events off SimInput before it can deliver them itself -
		// it paces in simulated ticks, which at this speed is far too fast for
		// the once-per-frame matrix scan to catch. See ps2_service_interactive.
		while (!input.keyEvents.empty()) {
			SimInput_PS2KeyEvent e = input.keyEvents.front();
			input.keyEvents.pop();
			ps2_push((uint8_t)(e.mapped & 0xFF), e.pressed, e.extended != 0);
		}

		if (run_enable) {
			ps2_service_interactive();
			for (int step = 0; step < batchSize; step++) {
				verilate();
				if (stop_pc_reached()) {
					print_stop_state("Reached --stop-at-pc.");
					run_enable = false; break;
				}
			}
		} else {
			if (single_step) { verilate(); single_step = false; }
			if (multi_step) {
				for (int step = 0; step < multi_step_amount; step++) verilate();
				multi_step = false;
			}
		}

		// --- audio: scope and on-demand playback ---
		ImGui::Begin(windowTitle_Audio);
		ImGui::PlotLines("##speaker", scope_buf, SCOPE_N, scope_pos,
		                 "speaker output", -1.0f, 1.0f, ImVec2(0, 120));

		double buffered = (double)audio_buf.size() / AUDIO_RATE;
		bool   full     = audio_buf.size() >= (size_t)AUDIO_RATE * AUDIO_CAP_SECS;

		ImGui::Text("buffer  %.2f s / %d s%s", buffered, AUDIO_CAP_SECS,
		            full ? "  FULL" : "");
		ImGui::Text("sound in buffer: %.3f s%s",
		            (double)audio_sound_cnt / AUDIO_RATE,
		            audio_sound_cnt == 0 ? "   (silent so far)"
		              : (audio_quiet_run > AUDIO_RATE / 20
		                   ? "   - quiet now, ready to play" : "   - still arriving"));

		if (audio_dev) {
			Uint32 queued = SDL_GetQueuedAudioSize(audio_dev) / sizeof(int16_t);

			// Play everything captured, then start a fresh capture - so the
			// cycle is: watch the buffer fill, trigger, listen, repeat.
			if (ImGui::Button("Play buffer") && !audio_buf.empty()) {
				SDL_ClearQueuedAudio(audio_dev);
				SDL_QueueAudio(audio_dev, audio_buf.data(),
				               (Uint32)(audio_buf.size() * sizeof(int16_t)));
				audio_buf.clear();
				audio_sound_cnt = 0;
				audio_quiet_run = 0;
			}
			ImGui::SameLine();
			if (ImGui::Button("Clear")) {
				audio_buf.clear(); audio_sound_cnt = 0; audio_quiet_run = 0;
			}
			ImGui::SameLine();
			if (ImGui::Button("Stop")) SDL_ClearQueuedAudio(audio_dev);
			ImGui::SameLine();
			ImGui::Checkbox("Capture", &audio_capture);

			if (queued)
				ImGui::Text("playing, %.2f s to go", (double)queued / AUDIO_RATE);
			else
				ImGui::Text("idle");

			ImGui::TextWrapped(
				"The sim is ~22x slower than real time, so there are never enough "
				"samples to play live. Capture instead: let the buffer fill, and "
				"when 'sound in buffer' stops growing press Play buffer - it plays "
				"at correct speed and pitch, then clears so the next thing can be "
				"captured. --audio-file writes the whole run as a WAV.");
		}
		else {
			ImGui::TextWrapped("No audio device. The scope and buffer counters "
			                   "still work, and --audio-file writes a WAV.");
		}
		ImGui::Text("%.2f s emulated in total", (double)audio_samples_made / AUDIO_RATE);
		ImGui::End();

		// --- control window ---
		ImGui::Begin("Simulation control");
		ImGui::Text("main_time: %llu", (unsigned long long)main_time);
		ImGui::Text("frame: %d   fps: %.1f", video.count_frame, video.stats_fps);
		ImGui::Text("keys queued: %d", (int)ps2_queue.size());
		ImGui::SliderInt("key dwell (frames)", &key_dwell_frames, 1, 10);
		ImGui::SameLine();
		if (ImGui::Button("Flush keys")) { while (!ps2_queue.empty()) ps2_queue.pop(); }
		ImGui::Separator();
		{
			char dis[64];
			uint16_t pc = VERTOPINTERN->debug_pc;
			z80_disasm(pc, peek, dis, sizeof(dis));
			ImGui::Text("PC   %04X  op %02X  %s", pc, VERTOPINTERN->debug_opcode, dis);
			ImGui::Text("addr %04X  din %02X  dout %02X  %s%s%s%s",
			            VERTOPINTERN->debug_addr, VERTOPINTERN->debug_din,
			            VERTOPINTERN->debug_dout,
			            VERTOPINTERN->debug_mreq ? "MREQ " : "",
			            VERTOPINTERN->debug_iorq ? "IORQ " : "",
			            VERTOPINTERN->debug_rd ? "RD " : "",
			            VERTOPINTERN->debug_wr ? "WR" : "");
			uint8_t p50 = VERTOPINTERN->debug_port50;
			ImGui::Text("port50 %02X  blk=%d %s %s vid@%s %s", p50,
			            p50 & 3,
			            (p50 & 0x04) ? "NOROMS" : "ROMS",
			            (p50 & 0x08) ? "novram" : "vram",
			            (p50 & 0x10) ? "8000" : "F000",
			            (p50 & 0x20) ? "ROM3" : "ROM2");
		}
		ImGui::Separator();
		if (ImGui::Button(run_enable ? "Stop" : "Run")) run_enable = !run_enable;
		ImGui::SameLine();
		if (ImGui::Button("Step")) { run_enable = false; single_step = true; }
		ImGui::SameLine();
		if (ImGui::Button("Step x1024")) { run_enable = false; multi_step = true; }
		ImGui::SameLine();
		if (ImGui::Button("Reset")) resetSim();
		ImGui::SameLine();
		if (ImGui::Button("Screenshot")) save_screenshot(video.count_frame);
		ImGui::SliderInt("Batch size", &batchSize, 1000, 500000);
		ImGui::End();

		// --- debug log ---
		console.Draw("Debug log", &showDebugLog, ImVec2(500, 200));

		// --- memory viewer, wired to the DUT's DRAM ---
		ImGui::Begin("DRAM");
		mem_edit.DrawContents(&VERTOPINTERN->emu__DOT__core__DOT__dram[0],
		                      sizeof(VERTOPINTERN->emu__DOT__core__DOT__dram), 0);
		ImGui::End();

		// --- video ---
		ImGui::Begin(windowTitle_Video);
		ImGui::SliderFloat("Zoom", &vga_scale, 1, 8);
		ImGui::Text("%dx%d  frame %d", video.output_width, video.output_height, video.count_frame);
		ImGui::Image(video.texture_id,
		             ImVec2((float)video.output_width * vga_scale,
		                    (float)video.output_height * vga_scale));
		ImGui::End();

		// Must be outside all Begin/End pairs - it calls ImGui::Render().
		video.UpdateTexture();
	}

	if (cpu_trace_file) fclose(cpu_trace_file);
	if (fdc_log_file) fclose(fdc_log_file);
	if (piob_log_file) fclose(piob_log_file);
	audio.CleanUp();
	if (audio_dev) SDL_CloseAudioDevice(audio_dev);
	top->final();
	video.CleanUp();
	return 0;
}
