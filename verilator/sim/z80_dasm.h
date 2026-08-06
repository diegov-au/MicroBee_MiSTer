#pragma once
#include <stdint.h>
#include <stddef.h>

// Peek callback: return the byte the CPU would see at this address, honouring
// whatever bank/ROM mapping is currently active.
typedef uint8_t (*z80_peek_fn)(uint16_t addr);

// Disassemble one instruction at `pc`. Writes text into `out` and returns the
// instruction length in bytes (1..4).
int z80_disasm(uint16_t pc, z80_peek_fn peek, char* out, size_t outsz);
