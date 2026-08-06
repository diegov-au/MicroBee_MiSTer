//============================================================================
// ZEXDOC / ZEXALL runner for tv80.
//
//   ./obj_dir/Vzex_top zexdoc.com [--max-ticks N] [--quiet]
//
// Sets up a minimal CP/M environment in the flat 64K:
//   $0000  JP $0100        reset vector into the program
//   $0005  JP $FE00        BDOS entry (and (6)/(7) = $FE00, which zexdoc
//                          loads into SP - standard CP/M convention)
//   $0100  the .com image
//   $FE00  a small Z80 BDOS stub
//
// The BDOS stub is Z80 code rather than a C++ trap so we never have to reach
// into tv80's register file: console output leaves as OUT ($01),A and exit as
// OUT ($00),A.
//
// Exit code is 0 only if the suite ran to completion with no failures.
//============================================================================

#include <verilated.h>
#include "Vzex_top.h"
#include "Vzex_top__Syms.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <string>

#define VERILATOR_MAJOR_VERSION (VERILATOR_VERSION_INTEGER / 1000000)
#if VERILATOR_MAJOR_VERSION >= 5
#define TOPI top->rootp
#else
#define TOPI top
#endif

static Vzex_top* top = NULL;
vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

// BDOS stub, assembled by hand. Loaded at $FE00.
//   FE00  79        LD A,C
//   FE01  FE 02     CP 2
//   FE03  28 0A     JR Z,$FE0F      (console out)
//   FE05  FE 09     CP 9
//   FE07  28 0C     JR Z,$FE15      (print $-terminated string)
//   FE09  B7        OR A
//   FE0A  28 18     JR Z,$FE24      (function 0 = exit)
//   FE0C  C9        RET
//   FE0F  7B        LD A,E
//   FE10  D3 01     OUT ($01),A
//   FE12  C9        RET
//   FE15  1A        LD A,(DE)
//   FE16  FE 24     CP '$'
//   FE18  C8        RET Z
//   FE19  D3 01     OUT ($01),A
//   FE1B  13        INC DE
//   FE1C  18 F7     JR $FE15
//   FE24  D3 00     OUT ($00),A
//   FE26  76        HALT
static const struct { unsigned addr; unsigned char b; } kBdos[] = {
	{0xFE00,0x79},{0xFE01,0xFE},{0xFE02,0x02},{0xFE03,0x28},{0xFE04,0x0A},
	{0xFE05,0xFE},{0xFE06,0x09},{0xFE07,0x28},{0xFE08,0x0C},
	{0xFE09,0xB7},{0xFE0A,0x28},{0xFE0B,0x18},{0xFE0C,0xC9},
	{0xFE0F,0x7B},{0xFE10,0xD3},{0xFE11,0x01},{0xFE12,0xC9},
	{0xFE15,0x1A},{0xFE16,0xFE},{0xFE17,0x24},{0xFE18,0xC8},
	{0xFE19,0xD3},{0xFE1A,0x01},{0xFE1B,0x13},{0xFE1C,0x18},{0xFE1D,0xF7},
	{0xFE24,0xD3},{0xFE25,0x00},{0xFE26,0x76},
};

int main(int argc, char** argv)
{
	const char* image = NULL;
	uint64_t max_ticks = 40000000000ULL;
	bool quiet = false;
	bool debug_io = false;
	uint64_t trace_fetches = 0;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--max-ticks") && i + 1 < argc) max_ticks = strtoull(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "--quiet")) quiet = true;
		else if (!strcmp(argv[i], "--debug-io")) debug_io = true;
		else if (!strcmp(argv[i], "--trace-fetches") && i + 1 < argc) trace_fetches = strtoull(argv[++i], NULL, 0);
		else if (argv[i][0] != '-') image = argv[i];
	}
	if (!image) { printf("usage: Vzex_top <zexdoc.com|zexall.com> [--max-ticks N] [--quiet]\n"); return 2; }

	FILE* f = fopen(image, "rb");
	if (!f) { printf("Cannot open %s\n", image); return 2; }

	top = new Vzex_top();
	Verilated::commandArgs(argc, argv);

	// Assert reset and clock through it BEFORE loading memory. The CPU's
	// control outputs power up at zero, and eval'ing with them in that state
	// can drive a spurious write into mem[0]; holding the CPU in reset first
	// keeps the image intact.
	TOPI->reset = 1;
	for (int i = 0; i < 32; i++) { TOPI->clk = i & 1; top->eval(); main_time++; }

	// Blank memory, then lay out the CP/M environment.
	for (int i = 0; i < 65536; i++) TOPI->zex_top__DOT__mem[i] = 0;

	TOPI->zex_top__DOT__mem[0x0000] = 0xC3;   // JP $0100
	TOPI->zex_top__DOT__mem[0x0001] = 0x00;
	TOPI->zex_top__DOT__mem[0x0002] = 0x01;

	TOPI->zex_top__DOT__mem[0x0005] = 0xC3;   // JP $FE00
	TOPI->zex_top__DOT__mem[0x0006] = 0x00;   // zexdoc does LD HL,($0006) / LD SP,HL
	TOPI->zex_top__DOT__mem[0x0007] = 0xFE;

	for (size_t i = 0; i < sizeof(kBdos)/sizeof(kBdos[0]); i++)
		TOPI->zex_top__DOT__mem[kBdos[i].addr] = kBdos[i].b;

	int c, n = 0;
	unsigned addr = 0x0100;
	while ((c = fgetc(f)) != EOF && addr < 0xFE00) { TOPI->zex_top__DOT__mem[addr++] = (unsigned char)c; n++; }
	fclose(f);
	printf("Loaded %s: %d bytes at $0100\n\n", image, n);

	TOPI->reset = 0;

	std::string line, out;
	bool started = false, finished = false, exited = false;

	while (main_time < max_ticks) {
		TOPI->clk = 1; top->eval();
		TOPI->clk = 0; top->eval();
		main_time++;

		if (TOPI->dbg_fetch) {
			if (trace_fetches && main_time < trace_fetches)
				printf("[pc] t=%llu %04X op=%02X\n", (unsigned long long)main_time,
				       TOPI->dbg_pc, TOPI->zex_top__DOT__mem[TOPI->dbg_pc]);
			if (TOPI->dbg_pc >= 0x0100 && TOPI->dbg_pc < 0xFE00) started = true;
			else if (started && TOPI->dbg_pc == 0x0000) { finished = true; break; }
		}

		if (TOPI->out_stb) {
			if (debug_io)
				printf("[io] t=%llu pc=%04X port=%02X data=%02X\n",
				       (unsigned long long)main_time, TOPI->dbg_pc,
				       TOPI->out_port, TOPI->out_data);
			if (TOPI->out_port == 0x00) { exited = true; finished = true; break; }
			if (TOPI->out_port == 0x01) {
				char ch = (char)TOPI->out_data;
				out += ch;
				if (ch == '\n' || ch == '\r') {
					if (!line.empty() && !quiet) { printf("%s\n", line.c_str()); fflush(stdout); }
					line.clear();
				} else if (ch >= 32) {
					line += ch;
				}
			}
		}
	}
	if (!line.empty() && !quiet) printf("%s\n", line.c_str());

	top->final();

	// zexdoc prints "ERROR" per failing test and "Tests complete" at the end.
	int errors = 0;
	for (size_t p = out.find("ERROR"); p != std::string::npos; p = out.find("ERROR", p + 1)) errors++;
	bool complete = out.find("Tests complete") != std::string::npos;

	printf("\n----------------------------------------\n");
	printf("ticks:     %llu\n", (unsigned long long)main_time);
	printf("finished:  %s%s\n", finished ? "yes" : "NO (ran out of ticks)",
	       exited ? " (via BDOS exit)" : "");
	printf("complete:  %s\n", complete ? "yes" : "NO");
	printf("errors:    %d\n", errors);
	printf("RESULT:    %s\n", (complete && errors == 0) ? "PASS" : "FAIL");
	printf("----------------------------------------\n");

	return (complete && errors == 0) ? 0 : 1;
}
