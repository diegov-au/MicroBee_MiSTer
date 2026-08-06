//============================================================================
// Compact Z80 disassembler for the Verilator trace window.
//
// Replaces the Musashi 68k disassembler the Mac II harness used. Covers the
// base table plus the CB / ED / DD / FD prefixes. Instruction lengths are
// exact (that is what the trace actually depends on); mnemonics follow the
// usual Zilog syntax.
//
// Placeholders in the tables:
//   %n  immediate byte          %w  immediate word
//   %r  relative jump target    %d  IX/IY displacement (signed)
//============================================================================

#include "z80_dasm.h"
#include <stdio.h>
#include <string.h>

static const char* const kMain[256] = {
/*00*/ "NOP",        "LD BC,%w",   "LD (BC),A",  "INC BC",     "INC B",      "DEC B",      "LD B,%n",    "RLCA",
/*08*/ "EX AF,AF'",  "ADD HL,BC",  "LD A,(BC)",  "DEC BC",     "INC C",      "DEC C",      "LD C,%n",    "RRCA",
/*10*/ "DJNZ %r",    "LD DE,%w",   "LD (DE),A",  "INC DE",     "INC D",      "DEC D",      "LD D,%n",    "RLA",
/*18*/ "JR %r",      "ADD HL,DE",  "LD A,(DE)",  "DEC DE",     "INC E",      "DEC E",      "LD E,%n",    "RRA",
/*20*/ "JR NZ,%r",   "LD HL,%w",   "LD (%w),HL", "INC HL",     "INC H",      "DEC H",      "LD H,%n",    "DAA",
/*28*/ "JR Z,%r",    "ADD HL,HL",  "LD HL,(%w)", "DEC HL",     "INC L",      "DEC L",      "LD L,%n",    "CPL",
/*30*/ "JR NC,%r",   "LD SP,%w",   "LD (%w),A",  "INC SP",     "INC (HL)",   "DEC (HL)",   "LD (HL),%n", "SCF",
/*38*/ "JR C,%r",    "ADD HL,SP",  "LD A,(%w)",  "DEC SP",     "INC A",      "DEC A",      "LD A,%n",    "CCF",
/*40*/ "LD B,B",     "LD B,C",     "LD B,D",     "LD B,E",     "LD B,H",     "LD B,L",     "LD B,(HL)",  "LD B,A",
/*48*/ "LD C,B",     "LD C,C",     "LD C,D",     "LD C,E",     "LD C,H",     "LD C,L",     "LD C,(HL)",  "LD C,A",
/*50*/ "LD D,B",     "LD D,C",     "LD D,D",     "LD D,E",     "LD D,H",     "LD D,L",     "LD D,(HL)",  "LD D,A",
/*58*/ "LD E,B",     "LD E,C",     "LD E,D",     "LD E,E",     "LD E,H",     "LD E,L",     "LD E,(HL)",  "LD E,A",
/*60*/ "LD H,B",     "LD H,C",     "LD H,D",     "LD H,E",     "LD H,H",     "LD H,L",     "LD H,(HL)",  "LD H,A",
/*68*/ "LD L,B",     "LD L,C",     "LD L,D",     "LD L,E",     "LD L,H",     "LD L,L",     "LD L,(HL)",  "LD L,A",
/*70*/ "LD (HL),B",  "LD (HL),C",  "LD (HL),D",  "LD (HL),E",  "LD (HL),H",  "LD (HL),L",  "HALT",       "LD (HL),A",
/*78*/ "LD A,B",     "LD A,C",     "LD A,D",     "LD A,E",     "LD A,H",     "LD A,L",     "LD A,(HL)",  "LD A,A",
/*80*/ "ADD A,B",    "ADD A,C",    "ADD A,D",    "ADD A,E",    "ADD A,H",    "ADD A,L",    "ADD A,(HL)", "ADD A,A",
/*88*/ "ADC A,B",    "ADC A,C",    "ADC A,D",    "ADC A,E",    "ADC A,H",    "ADC A,L",    "ADC A,(HL)", "ADC A,A",
/*90*/ "SUB B",      "SUB C",      "SUB D",      "SUB E",      "SUB H",      "SUB L",      "SUB (HL)",   "SUB A",
/*98*/ "SBC A,B",    "SBC A,C",    "SBC A,D",    "SBC A,E",    "SBC A,H",    "SBC A,L",    "SBC A,(HL)", "SBC A,A",
/*A0*/ "AND B",      "AND C",      "AND D",      "AND E",      "AND H",      "AND L",      "AND (HL)",   "AND A",
/*A8*/ "XOR B",      "XOR C",      "XOR D",      "XOR E",      "XOR H",      "XOR L",      "XOR (HL)",   "XOR A",
/*B0*/ "OR B",       "OR C",       "OR D",       "OR E",       "OR H",       "OR L",       "OR (HL)",    "OR A",
/*B8*/ "CP B",       "CP C",       "CP D",       "CP E",       "CP H",       "CP L",       "CP (HL)",    "CP A",
/*C0*/ "RET NZ",     "POP BC",     "JP NZ,%w",   "JP %w",      "CALL NZ,%w", "PUSH BC",    "ADD A,%n",   "RST 00H",
/*C8*/ "RET Z",      "RET",        "JP Z,%w",    "[CB]",       "CALL Z,%w",  "CALL %w",    "ADC A,%n",   "RST 08H",
/*D0*/ "RET NC",     "POP DE",     "JP NC,%w",   "OUT (%n),A", "CALL NC,%w", "PUSH DE",    "SUB %n",     "RST 10H",
/*D8*/ "RET C",      "EXX",        "JP C,%w",    "IN A,(%n)",  "CALL C,%w",  "[DD]",       "SBC A,%n",   "RST 18H",
/*E0*/ "RET PO",     "POP HL",     "JP PO,%w",   "EX (SP),HL", "CALL PO,%w", "PUSH HL",    "AND %n",     "RST 20H",
/*E8*/ "RET PE",     "JP (HL)",    "JP PE,%w",   "EX DE,HL",   "CALL PE,%w", "[ED]",       "XOR %n",     "RST 28H",
/*F0*/ "RET P",      "POP AF",     "JP P,%w",    "DI",         "CALL P,%w",  "PUSH AF",    "OR %n",      "RST 30H",
/*F8*/ "RET M",      "LD SP,HL",   "JP M,%w",    "EI",         "CALL M,%w",  "[FD]",       "CP %n",      "RST 38H"
};

static const char* const kRegs[8] = { "B", "C", "D", "E", "H", "L", "(HL)", "A" };
static const char* const kRot[8]  = { "RLC", "RRC", "RL", "RR", "SLA", "SRA", "SLL", "SRL" };

// ED-prefix opcodes that actually exist; everything else is a 2-byte NOP.
static const char* ed_op(uint8_t op)
{
	switch (op) {
	case 0x40: return "IN B,(C)";     case 0x41: return "OUT (C),B";
	case 0x42: return "SBC HL,BC";    case 0x43: return "LD (%w),BC";
	case 0x44: return "NEG";          case 0x45: return "RETN";
	case 0x46: return "IM 0";         case 0x47: return "LD I,A";
	case 0x48: return "IN C,(C)";     case 0x49: return "OUT (C),C";
	case 0x4A: return "ADC HL,BC";    case 0x4B: return "LD BC,(%w)";
	case 0x4D: return "RETI";         case 0x4F: return "LD R,A";
	case 0x50: return "IN D,(C)";     case 0x51: return "OUT (C),D";
	case 0x52: return "SBC HL,DE";    case 0x53: return "LD (%w),DE";
	case 0x56: return "IM 1";         case 0x57: return "LD A,I";
	case 0x58: return "IN E,(C)";     case 0x59: return "OUT (C),E";
	case 0x5A: return "ADC HL,DE";    case 0x5B: return "LD DE,(%w)";
	case 0x5E: return "IM 2";         case 0x5F: return "LD A,R";
	case 0x60: return "IN H,(C)";     case 0x61: return "OUT (C),H";
	case 0x62: return "SBC HL,HL";    case 0x63: return "LD (%w),HL";
	case 0x67: return "RRD";
	case 0x68: return "IN L,(C)";     case 0x69: return "OUT (C),L";
	case 0x6A: return "ADC HL,HL";    case 0x6B: return "LD HL,(%w)";
	case 0x6F: return "RLD";
	case 0x70: return "IN (C)";       case 0x71: return "OUT (C),0";
	case 0x72: return "SBC HL,SP";    case 0x73: return "LD (%w),SP";
	case 0x78: return "IN A,(C)";     case 0x79: return "OUT (C),A";
	case 0x7A: return "ADC HL,SP";    case 0x7B: return "LD SP,(%w)";
	case 0xA0: return "LDI";          case 0xA1: return "CPI";
	case 0xA2: return "INI";          case 0xA3: return "OUTI";
	case 0xA8: return "LDD";          case 0xA9: return "CPD";
	case 0xAA: return "IND";          case 0xAB: return "OUTD";
	case 0xB0: return "LDIR";         case 0xB1: return "CPIR";
	case 0xB2: return "INIR";         case 0xB3: return "OTIR";
	case 0xB8: return "LDDR";         case 0xB9: return "CPDR";
	case 0xBA: return "INDR";         case 0xBB: return "OTDR";
	default:   return NULL;
	}
}

// Expand a template, consuming operand bytes. Returns total instruction length.
static int expand(const char* tmpl, uint16_t pc, int opbytes, z80_peek_fn peek,
                  const char* idx, int disp_at, char* out, size_t outsz)
{
	char buf[80];
	size_t o = 0;
	int consumed = 0;
	uint16_t operand_pc = (uint16_t)(pc + opbytes);

	for (const char* p = tmpl; *p && o < sizeof(buf) - 24; ) {
		if (p[0] == '%' && p[1]) {
			char kind = p[1];
			p += 2;
			if (kind == 'n') {
				uint8_t v = peek((uint16_t)(operand_pc + consumed));
				consumed += 1;
				o += (size_t)snprintf(buf + o, sizeof(buf) - o, "$%02X", v);
			} else if (kind == 'w') {
				uint8_t lo = peek((uint16_t)(operand_pc + consumed));
				uint8_t hi = peek((uint16_t)(operand_pc + consumed + 1));
				consumed += 2;
				o += (size_t)snprintf(buf + o, sizeof(buf) - o, "$%04X", (unsigned)(lo | (hi << 8)));
			} else if (kind == 'r') {
				int8_t d = (int8_t)peek((uint16_t)(operand_pc + consumed));
				consumed += 1;
				uint16_t tgt = (uint16_t)(operand_pc + consumed + d);
				o += (size_t)snprintf(buf + o, sizeof(buf) - o, "$%04X", tgt);
			} else if (kind == 'd') {
				int8_t d = (int8_t)peek((uint16_t)(pc + disp_at));
				o += (size_t)snprintf(buf + o, sizeof(buf) - o, "%+d", (int)d);
			}
		} else if (p[0] == 'H' && p[1] == 'L' && idx) {
			// Rewrite HL -> IX/IY under a DD/FD prefix.
			o += (size_t)snprintf(buf + o, sizeof(buf) - o, "%s", idx);
			p += 2;
		} else {
			buf[o++] = *p++;
		}
	}
	buf[o] = 0;
	snprintf(out, outsz, "%s", buf);
	return opbytes + consumed;
}

int z80_disasm(uint16_t pc, z80_peek_fn peek, char* out, size_t outsz)
{
	uint8_t op = peek(pc);

	// ---- CB: rotates, shifts, bit ops ----
	if (op == 0xCB) {
		uint8_t o2 = peek((uint16_t)(pc + 1));
		int r = o2 & 7, y = (o2 >> 3) & 7;
		if (o2 < 0x40) snprintf(out, outsz, "%s %s", kRot[y], kRegs[r]);
		else if (o2 < 0x80) snprintf(out, outsz, "BIT %d,%s", y, kRegs[r]);
		else if (o2 < 0xC0) snprintf(out, outsz, "RES %d,%s", y, kRegs[r]);
		else snprintf(out, outsz, "SET %d,%s", y, kRegs[r]);
		return 2;
	}

	// ---- ED ----
	if (op == 0xED) {
		uint8_t o2 = peek((uint16_t)(pc + 1));
		const char* t = ed_op(o2);
		if (!t) { snprintf(out, outsz, "DB $ED,$%02X", o2); return 2; }
		return expand(t, pc, 2, peek, NULL, 0, out, outsz);
	}

	// ---- DD / FD: IX / IY ----
	if (op == 0xDD || op == 0xFD) {
		const char* idx = (op == 0xDD) ? "IX" : "IY";
		uint8_t o2 = peek((uint16_t)(pc + 1));

		// DDCB/FDCB: prefix, displacement, then the CB opcode.
		if (o2 == 0xCB) {
			int8_t d = (int8_t)peek((uint16_t)(pc + 2));
			uint8_t o4 = peek((uint16_t)(pc + 3));
			int y = (o4 >> 3) & 7;
			if (o4 < 0x40) snprintf(out, outsz, "%s (%s%+d)", kRot[y], idx, (int)d);
			else if (o4 < 0x80) snprintf(out, outsz, "BIT %d,(%s%+d)", y, idx, (int)d);
			else if (o4 < 0xC0) snprintf(out, outsz, "RES %d,(%s%+d)", y, idx, (int)d);
			else snprintf(out, outsz, "SET %d,(%s%+d)", y, idx, (int)d);
			return 4;
		}

		// Opcodes that address (HL) become (IX+d) and gain a displacement byte.
		bool uses_hl_mem = (o2 == 0x34 || o2 == 0x35 || o2 == 0x36 ||
		                    (o2 >= 0x70 && o2 <= 0x77 && o2 != 0x76) ||
		                    ((o2 & 0xC7) == 0x46 && o2 >= 0x40 && o2 < 0x80) ||
		                    (o2 >= 0x80 && o2 < 0xC0 && (o2 & 7) == 6));
		if (uses_hl_mem) {
			char tmp[64];
			const char* base = kMain[o2];
			// Replace "(HL)" with "(IX%d)" and let expand() fill the rest.
			const char* hlp = strstr(base, "(HL)");
			if (hlp) {
				size_t pre = (size_t)(hlp - base);
				snprintf(tmp, sizeof(tmp), "%.*s(%s%%d)%s", (int)pre, base, idx, hlp + 4);
				// operand bytes: prefix + opcode + displacement
				int len = expand(tmp, pc, 3, peek, NULL, 2, out, outsz);
				return len;
			}
		}

		// Everything else: same as the base opcode with HL renamed.
		return expand(kMain[o2], pc, 2, peek, idx, 0, out, outsz);
	}

	// ---- base table ----
	return expand(kMain[op], pc, 1, peek, NULL, 0, out, outsz);
}
