# ZEXDOC / ZEXALL gate for the vendored tv80.
#
#   make && make zexdoc      # the gate - must PASS before M2 depends on the CPU
#   make zexall              # informational: also covers undocumented flags
#
# No SDL/ImGui here - this is a pure batch test, built with -O3 because the
# suite runs several billion cycles.

V = verilator
RTL = ../../rtl
TOP = --top-module zex_top

V_OPT = -O3 --x-assign fast --x-initial fast --noassert
V_WARN = -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-IMPLICIT -Wno-PINMISSING \
	-Wno-PINCONNECTEMPTY -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-UNOPTFLAT \
	-Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-CMPCONST -Wno-LATCH -Wno-UNDRIVEN \
	-Wno-MISINDENT -Wno-COMBDLY -Wno-INITIALDLY -Wno-SYNCASYNCNET -Wno-ALWNEVER \
	-Wno-PROCASSWIRE -Wno-PROCASSINIT -Wno-BLKANDNBLK -Wno-MULTIDRIVEN \
	-Wno-GENUNNAMED -Wno-DECLFILENAME -Wno-TIMESCALEMOD

V_SRC = \
	zex_top.v \
	$(RTL)/tv80/tv80s_ce.v \
	$(RTL)/tv80/tv80_core.v \
	$(RTL)/tv80/tv80_alu.v \
	$(RTL)/tv80/tv80_mcode.v \
	$(RTL)/tv80/tv80_reg.v

EXE = ./obj_dir/Vzex_top

all: $(EXE)

$(EXE): $(V_SRC) zex_main.cpp Makefile
	$(V) -cc $(V_OPT) $(V_WARN) --timescale-override 1ps/1ps -exe --Mdir ./obj_dir \
		-CFLAGS "-O3" $(TOP) $(V_SRC) zex_main.cpp
	(cd obj_dir && make OPT_FAST="-O3 -march=native" -f Vzex_top.mk)

# Test images are not redistributed with the core; fetch on demand.
zexdoc.com:
	curl -sfL -o $@ https://raw.githubusercontent.com/anotherlin/z80emu/master/testfiles/zexdoc.com
zexall.com:
	curl -sfL -o $@ https://raw.githubusercontent.com/anotherlin/z80emu/master/testfiles/zexall.com

zexdoc: $(EXE) zexdoc.com
	$(EXE) zexdoc.com

zexall: $(EXE) zexall.com
	$(EXE) zexall.com

clean:
	rm -rf obj_dir

.PHONY: all zexdoc zexall clean
