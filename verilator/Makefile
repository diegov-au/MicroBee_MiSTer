V = verilator

TOP = --top-module emu
RTL = ../rtl
V_INC = +incdir+$(RTL)

# Harness master clock is a RUN-TIME choice, not a build one - pass --fast.
#
# The MicroBee's real crystal is 13.5 MHz (the dot clock). Hardware runs clk_sys
# at 54 MHz only because MiSTer's scandoubler derives a 4x pixel clock by
# measuring the ce_pix period and shifting it right by 2 - see sys/scandoubler.v.
# This harness has no scandoubler, so --fast clocks at 13.5 MHz and evaluates
# the design a quarter as many times for the same simulated second (~4.5x).
#
# Every real-time constant in the RTL is in ce_cpu or ce_char units, so the
# ratios are untouched either way. The C++ block-device model is the exception:
# its delays are in clk_sys ticks and it scales them - see sim_blkdevice.cpp.

# TV80_REFRESH: without it tv80 does not implement the R register at all and
# `LD A,R` returns a hardcoded 0 (tv80_core.v ~line 754). R is the classic Z80
# pseudo-random source, and Asteroids Plus uses it to walk an entropy pointer -
# with R stuck at 0 the pointer never advances and the game hangs (BUG-008).
# zexdoc does not catch this: Z80 test suites deliberately exclude R.
# MUST match the VERILOG_MACRO in files.qip - simulation and synthesis
# disagreeing about the CPU would be worse than either setting.
V_DEFINE = +define+SIMULATION=1 +define+TV80_REFRESH=1 \
	-CFLAGS "-I../sim/imgui -I../sim/vinc -I../sim/ -g" \
	--timescale-override 1ps/1ps -Wno-TIMESCALEMOD \
	-I$(RTL) \
	-I$(RTL)/tv80

# Warnings that don't affect simulation correctness. Most of these come from
# the vendored tv80 core, which predates modern Verilator lint.
V_DEFINE += -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-IMPLICIT \
	-Wno-PINMISSING -Wno-PINCONNECTEMPTY -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	-Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-CMPCONST -Wno-LATCH \
	-Wno-UNDRIVEN -Wno-MISINDENT -Wno-COMBDLY -Wno-INITIALDLY -Wno-SYNCASYNCNET \
	-Wno-ALWNEVER -Wno-PROCASSWIRE -Wno-PROCASSINIT -Wno-BLKANDNBLK \
	-Wno-MULTIDRIVEN -Wno-GENUNNAMED -Wno-DECLFILENAME

# NOT --public-flat-rw. Making the whole design public forces every signal to
# be stored and blocks Verilator's optimiser - it cost about 4x simulation
# speed here, and 2.4x on the zexdoc testbench. The handful of signals
# sim_main.cpp reaches into (dram, rom1, screen/PCG RAM, the CRTC register
# file, boot_overlay, the keyboard scan taps) carry a per-signal
# `/* verilator public_flat_rw */` attribute in the RTL instead.

UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S), Darwin) #APPLE
	ECHO_MESSAGE = "Mac OS X"
	LIBS += -framework OpenGL -framework Cocoa -framework IOKit -framework CoreVideo `sdl2-config --libs`
	LIBS += -L/usr/local/lib -L/opt/local/lib

	CXXFLAGS += `sdl2-config --cflags` -Iimgui
	CXXFLAGS += `sdl2-config --cflags | sed 's|include/SDL2|include/|'`
	CXXFLAGS += -I/usr/local/include -I/opt/local/include
	CFLAGS = $(CXXFLAGS) -Iimgui
endif

ifeq ($(UNAME_S), Linux) #LINUX
	ECHO_MESSAGE = "Linux"
	LIBS += -lGL -ldl `sdl2-config --libs`

	CXXFLAGS += `sdl2-config --cflags` -Iimgui
	CFLAGS = $(CXXFLAGS)
endif

ifeq ($(findstring MINGW,$(UNAME_S)),MINGW)
	ECHO_MESSAGE = "MinGW"
	LIBS += -lgdi32 -lopengl32 -limm32 `pkg-config --static --libs sdl2`

	CXXFLAGS += `pkg-config --cflags sdl2`
	CFLAGS = $(CXXFLAGS)
endif

CFLAGS += $(CC_OPT) $(CC_DEFINE) -Iimgui
LDFLAGS = $(LIBS)
EXE = ./obj_dir/Vemu
V_OPT = --x-assign fast --x-initial fast --noassert
CC_OPT =

# MicroBee RTL
V_SRC = \
	sim.v \
	$(RTL)/microbee_core.v \
	$(RTL)/microbee_mem.v \
	$(RTL)/microbee_models.v \
	$(RTL)/mc6545.v \
	$(RTL)/microbee_video.v \
	$(RTL)/microbee_kbd.v \
	$(RTL)/z80pio.v \
	$(RTL)/wd1793.sv \
	$(RTL)/microbee_tape.v \
	$(RTL)/tv80/tv80s_ce.v \
	$(RTL)/tv80/tv80_core.v \
	$(RTL)/tv80/tv80_alu.v \
	$(RTL)/tv80/tv80_mcode.v \
	$(RTL)/tv80/tv80_reg.v

C_SRC = \
	sim_main.cpp \
	sim/sim_bus.cpp sim/sim_blkdevice.cpp sim/sim_clock.cpp sim/sim_console.cpp \
	sim/sim_video.cpp sim/sim_input.cpp sim/sim_audio.cpp sim/sim_serial.cpp \
	sim/z80_dasm.cpp \
	sim/imgui/imgui_impl_sdl.cpp sim/imgui/imgui_impl_opengl2.cpp sim/imgui/imgui_draw.cpp \
	sim/imgui/imgui_widgets.cpp sim/imgui/imgui_tables.cpp sim/imgui/imgui.cpp \
	sim/imgui/ImGuiFileDialog.cpp sim/imgui/implot.cpp sim/imgui/implot_items.cpp

VOUT = obj_dir/Vemu.cpp

all: $(EXE)

$(VOUT): $(V_SRC) Makefile
	$V -cc $(V_OPT) -LDFLAGS "$(LDFLAGS) " -exe --Mdir ./obj_dir $(V_DEFINE) $(V_INC) $(TOP) -CFLAGS $(CFLAGS) $(V_SRC) $(C_SRC)

# OPT_FAST applies to the generated model only, not the ImGui/SDL support code,
# so the build stays quick while the part that runs 100M times a second is
# optimised properly. Verilator's default here is -Os.
OPT_FAST = -O3 -march=native

$(EXE): $(VOUT) $(C_SRC)
	(cd obj_dir; make -f Vemu.mk OPT_FAST="$(OPT_FAST)")

# The mandatory ROM bundle - slot 0, and the same file hardware loads as
# boot0.rom. MiSTer auto-loads only boot0-boot3 (BUG-011), so the four images
# every model needs share one slot and the optional ROMs keep their own.
#
# THIS RULE IS WHERE THE ORDER IS DEFINED. It is chosen so truncation degrades
# gracefully: cut short after 12K the bundle still gives a working standard
# CIAB *with* text, rather than a machine with no font. Do not retype the order
# elsewhere - point at this rule.
#
#   0x0000   8K  bn54.rom         ROM1 bank 0   CIAB
#   0x2000   4K  charrom.bin      char ROM      every model
#   0x3000  16K  basic_5.22e.rom  ROM1 bank 1   BASIC
#   0x7000   8K  bn56.rom         ROM1 bank 2   Premium
#
# 36,864 bytes, SHA1 7c4678e69ab8917a36e88025fa63f065b79fa9ae
BOOT0_PARTS = ../release/bn54.rom ../release/charrom.bin \
              ../release/basic_5.22e.rom ../release/bn56.rom

../release/boot0.rom: $(BOOT0_PARTS)
	cat $(BOOT0_PARTS) > $@
	@ls -l $@

CHARROM = ../release/charrom.bin

# CPCEMU .dsk -> raw ss80.
#
# A standard (non-EXTENDED) CPCEMU image is a 256-byte disk header followed by
# one 256-byte header per track. The WD1793's own parser only recognises the
# "EXTENDED CPC DSK" signature, so for a standard image it falls through to the
# fixed-geometry path, which assumes a raw image with no headers at all. Strip
# them and it lines up exactly: track size 0x1500 = 256 + 10*512.
%.ss80: ../release/%.dsk
	@rm -f $@
	@for t in $$(seq 0 79); do \
		dd if=$< bs=256 skip=$$((2 + t * 21)) count=20 status=none >> $@; \
	done
	@ls -l $@

# 64K CIAB - boots the bn54 loader, then wants a disk (M4).
run-ciab: all
	$(EXE) --rom ../release/bn54.bin --charrom $(CHARROM)

# 64K CIAB booting CP/M off the master disk. The sim runs about 20x slower than
# the real machine, so the Computer-In-A-Book menu takes a few minutes of wall
# time to appear - that is expected, not a hang. RETURN at the menu gives CP/M.
run-ciab-disk: all ciabmaster.ss80
	$(EXE) --rom ../release/bn54.bin --charrom $(CHARROM) --disk ciabmaster.ss80

# ROM-based BASIC - runs standalone, no disk needed.
#
# --piob7-vsync because ROM-BASIC models put vsync on PIO port B bit 7 and take
# their 50 Hz timer from it; without it the monitored bit is stuck true.
# Try `PLAY 5` at the prompt for a short mid tone.
run-basic: all
	$(EXE) --rom ../release/basic_5.22e.rom --charrom $(CHARROM) --piob7-vsync

# The 32K IC - its own BASIC plus WordBee and Telcom, all three resident.
# `PAK` enters WordBee, `NET` enters Telcom; an empty socket answers
# "Option not fitted error".
run-ic: all
	$(EXE) --model ic --rom ../release/basic_5.22e.rom --charrom $(CHARROM) \
	  --rom-slot 4 ../release/wordbee_1.2.rom \
	  --rom-slot 5 ../release/telcom_1.0.rom

lint:
	$V --lint-only $(V_DEFINE) $(V_INC) $(TOP) $(V_SRC)

clean:
	rm -rf obj_dir obj_dir_hw basic.rom boot.rom

.PHONY: all clean lint run-ciab run-ciab-disk run-basic
