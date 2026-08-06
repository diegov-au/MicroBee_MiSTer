# MicroBee core for MiSTer

An FPGA implementation of the Australian **MicroBee** for the MiSTer platform, the
Series-3 banked machines and the earlier ROM-BASIC 32K IC, written from the factory
schematics and cross-checked against ubee512, MAME and FPGABee.

Z80 + 6545 CRTC + light-pen keyboard + WD2793 floppy + Z80 PIO + cassette, in
Verilog/SystemVerilog. Everything lives in block RAM — no SDRAM or DDR3 is used or
required.

The MicroBee was designed and built in Australia by Applied Technology from 1982, and was the machine most Australian schools of the era actually had. Four
of its models are here, all selectable at run time from one bitstream.

---

## Supported models

Switch models from the OSD; the core resets itself and comes up as the machine you
picked, with your disk still mounted.

| Model | What it is |
|---|---|
| **CIAB Standard** | 64K Computer-in-a-Book, monochrome. The standard Series-3 machine |
| **CIAB Premium** | The same machine with the Alpha Plus board — colour, attribute RAM, 8 PCG banks and the Alpha+ port map |
| **32K IC** | The unbanked ROM-BASIC machine. Boots straight to BASIC with WordBee and Telcom in ROM, and loads from cassette. No disk controller |
| **Premium 128K** | Top of the range: Premium video with 128K of banked RAM. Runs 128K-only software, and CP/M finds the second bank as a RAM disk (`M:`) |

**CIAB Standard is the power-on default**, deliberately — it is the machine most
likely to have working ROMs and a disk that will mount.



---

## Core features

### CPU and system

- **Z80 at 3.375 MHz**, the machine's real clock, derived from one 54 MHz PLL
  (`/16` CPU, `/4` 13.5 MHz dot clock, `/32` 1.6875 MHz character clock).
- **Memory banking** through port `$50`, with the boot overlay that makes ROM
  readable low until the first bank write — which is how the machine gets something
  to execute at reset.
- **32K, 64K and 128K** memory configurations, selected at run time rather than at
  build time, so one bitstream covers all four machines.

### Video

- **Real 6545 CRTC timing**, generated from registers R0–R9 rather than synthesised
  from a fixed raster. The core emits the machine's native **15.625 kHz / 50 Hz** and
  lets MiSTer's scaler do its job, so the picture is the shape the hardware actually
  produced.
- Both text modes, and software switches between them live: **64×16** (ROM BASIC and
  most games) and **80×24** (CP/M and the CIAB menu). A single CIAB boot crosses that
  boundary.
- **PCG graphics** — programmable character generator RAM, which is how the MicroBee
  does graphics at all — and dual character sets.
- **Premium colour**, with a CGA-style palette taken from the Alpha Plus schematic
  rather than guessed, plus **attribute RAM**: per-cell inverse, flash and PCG bank
  select, across 8 PCG banks.
- **Phosphor emulation** for the mono machines — Amber, Green or White. A Premium can
  be run on a mono monitor by choosing one.
- **Aspect ratio is computed, not fixed.** MicroBee pixels are 1 wide : 2 tall, and
  the active area changes when software reprograms the CRTC, so the core reports the
  true shape per mode instead of declaring a static 4:3.

### Keyboard

The MicroBee has **no keyboard controller at all** — the key matrix is wired into the
CRTC's *light pen* input, so the CRTC's own address scan is what detects a keypress.
The core implements that literally, including both scan paths: the natural
memory-address walk during refresh, and the explicit R18/R19 + R31 strobe.

Two mappings, selectable in the OSD:

- **Symbolic** (default) — you get the character printed on your keycap, assuming a
  US layout.
- **Positional** — the machine's own **ASCII-63** layout, key for key, where Shift
  moves the whole digit row one place left. Use this if software reads the key matrix
  directly.

### Disk

- **WD2793 floppy controller**, with read *and* write, verified writing back to the
  SD card.
- **CPCEMU `.dsk`**, standard *and* EXTENDED — self-describing, carries the real
  sector IDs, and reproduces awkwardly-formatted disks faithfully.
- **Raw `ss80`** and **raw `ds80`** images.
- Geometry is **detected from the image size**, not chosen in a menu, so there is no
  way to mount a disk with the wrong setting and get what looks like a corrupt disk.

### Cassette

- Mount a **DGOS `.tap`** image and type `LOAD` in BASIC, exactly as on the real
  machine. There is no Play button, because the MicroBee had no tape motor control —
  the core notices the ROM entering its tape routine and starts the tape itself.
- **Both tape speeds**, 300 and 1200 baud, switched automatically from the tape's own
  header, as the hardware does.
- The core **generates the Kansas City waveform** from the file rather than injecting
  bytes behind the ROM's back, so a load takes the time it really took and the
  machine's own ROM decoder is what reads it.
- **Tape audio**, on by default, mixed in at half the speaker's level. A load takes
  minutes against a static screen and the sound is the only sign it is working —
  without it people conclude the machine has hung. There is an OSD toggle for anyone
  who finds it tiresome.
- **Rewind** in the OSD, for when a load has already run past.
- Saving to tape is deliberately not implemented.

### Sound

Speaker output from PIO port B bit 6, the machine's own one-bit sound. `PLAY` works
from BASIC.

### Peripherals

- **Z80 PIO** with both ports, all four modes, IM2 interrupt vectors and the daisy
  chain — including RETI detection off the opcode stream, which the real chip does.
- The 50 Hz frame interrupt on the models wired for it, taken from PIO port B bit 7.

---

## OSD options

| Option | What it does |
|---|---|
| **Model** | CIAB Standard / CIAB Premium / 32K IC / Premium 128K |
| **Load BASIC ROM** | Boots a disk machine into ROM BASIC instead of the disk BIOS |
| **Phosphor** | Colour / Amber / Green / White |
| **Keyboard** | Symbolic / Positional |
| **Mount Drive A:** | `.dsk`, `.ss8`, `.ds8` |
| **Mount Tape** | `.tap` |
| **Rewind Tape** | Returns the tape to the start |
| **Tape Audio** | On / Off — On by default |
| **Aspect ratio** | Original (true 1:2 pixels) / Full Screen / custom |
| **Scandoubler Fx** | None / HQ2x / CRT 25% / CRT 50% |
| **Scale** | Normal / V-Integer / HV-Integer variants |
| **Reset** | Restarts the machine, leaving memory as it was |
| **Cold Reset** | Clears memory first, so the machine comes up as if switched off and on — what **ESC + RESET** does on real hardware. 

---

## Installing on MiSTer

The core name is **`MicroBee`**, which is what MiSTer uses to find everything.

```
/media/fat/_Computer/MicroBee_YYYYMMDD.rbf
/media/fat/games/MicroBee/
        boot0.rom  boot1.rom  boot2.rom
        *.dsk  *.ss8  *.ds8  *.tap
```

### ROMs — one required file

**ROMs are not included. They are copyrighted, and you must supply your own.**

MiSTer auto-loads only `boot0`–`boot3`, so the four images every model needs are
concatenated into a single bundle. Build it once — these are 1980s ROMs and they
never change.

**Linux / macOS:**

```bash
cat bn54.rom charrom.bin basic_5.22e.rom bn56.rom > boot0.rom
```

**Windows — Command Prompt.** The `/b` matters: it means binary, and without it
`copy` stops at the first `Ctrl+Z` byte and silently truncates the bundle.

```
copy /b bn54.rom + charrom.bin + basic_5.22e.rom + bn56.rom boot0.rom
```

| Order | Image | Size | What it is |
|---|---|---|---|
| 1 | `bn54.rom` | 8K | 64K CIAB boot ROM — the standard machine |
| 2 | `charrom.bin` | 4K | character ROM, shared by **every** model |
| 3 | `basic_5.22e.rom` | 16K | ROM BASIC — the CIAB's *Load BASIC ROM* option, and the 32K IC's own boot ROM |
| 4 | `bn56.rom` | 8K | Premium boot ROM — Premium 64K **and** Premium 128K share one image |

**The order matters, and the size will not tell you if you got it wrong** — a bundle
assembled in the wrong order is exactly 36,864 bytes, the same as a correct one.
Check it against this:

```
36,864 bytes
SHA1  7c4678e69ab8917a36e88025fa63f065b79fa9ae
```

To check it — Linux/macOS `sha1sum boot0.rom`, Windows
`certutil -hashfile boot0.rom SHA1`.

Use `bn54.rom`, **not** `bn56.rom`, in position 1. They look interchangeable and are
not. The core also samples six bytes at known offsets while loading and reports
`WARNING: boot0.rom is wrong` in the OSD if the bundle is short, mis-ordered or built
from the wrong images — but the SHA1 above is the real answer.

**Optional — the 32K IC's two option ROMs**, each in its own slot so you can fit one
and not the other:

| File | Image | Size | What it is |
|---|---|---|---|
| `boot1.rom` | `wordbee_1.2.rom` | 8K | WordBee, the word processor — `PAK` |
| `boot2.rom` | `telcom_1.0.rom` | 4K | Telcom, the terminal — `NET` |

Leave either out and the IC still boots; the missing command answers `Option not
fitted error`.

`bootN.rom` files are picked up automatically when the core starts. There is nothing
to load from the OSD.

### If something does not boot

None of these produce an error message, and two look like something other than a
missing file:

| Missing | What you see |
|---|---|
| `boot0.rom` | Nothing at all — blank screen, no cursor |
| `boot0.rom` truncated after 8K | **A flashing cursor and no text, ever.** The machine is running fine and you can type into it blind; the character ROM never arrived, so every cell fetches as zero and only the inverted cursor shows |
| `boot0.rom` in the wrong order | Varies, and rarely obviously — a CIAB running the Premium BIOS still boots. The OSD's `boot0.rom is wrong` line is the reliable tell |
| `boot1.rom` / `boot2.rom` | The IC boots normally; `PAK` or `NET` answers `Option not fitted error` |


---

## Disk images

| Format | Extension | Notes |
|---|---|---|
| **CPCEMU `.dsk`** — standard *and* EXTENDED | `.dsk` | Prefer this. Self-describing and carries the real sector IDs |
| **Raw `ss80`** | `.ss8` | 80 track, single sided, 10 × 512 — the CIAB's native format |
| **Raw `ds80`** | `.ds8` | 80 track, double sided, 10 × 512 = 819,200 bytes — the Premium 128K's native format |

MiSTer's file browser only matches 3-character extensions, which is why a raw image
needs renaming to `.ss8` or `.ds8`.

Only drive A: is fitted. On a single-drive CP/M system, selecting `B:` shows A:'s
files — that is CP/M aliasing the drive in software, and is correct behaviour rather
than a fault. A second drive is planned.

---

## Using the 32K IC

Select **Model: 32K IC**. It cold-boots straight to the BASIC prompt — there is no
disk and nothing to mount.

### PAK and NET — the two option ROMs

The machine's three ROMs fill `$8000–$EFFF` exactly — 16K + 8K + 4K — with video at
`$F000`. Nothing is bank-switched, so all three are live at once, and two BASIC
commands reach the other two:

| Type at the `>` prompt | You get |
|---|---|
| `PAK` | **WordBee 1.2**, the word processor — `boot1.rom`, in the PAK0 socket at `$C000` |
| `NET` | **Telcom 1.0**, the terminal — `boot2.rom`, in the Net ROM socket at `$E000` |

Both are entered directly with no loading — that is the whole point of a ROM machine.
Each has its own way back to BASIC, and resetting the core always works.

If a socket is empty, BASIC answers `Option not fitted error` and returns you to the
prompt, so a missing ROM here is never a mystery: the machine tells you itself.

### Loading from tape

Mount a `.tap` with **Mount Tape**, then at the BASIC prompt:

```
>LOAD
```

The tape starts by itself. You will hear it load, and the machine prints the file's
name and type as it finds the header:

```
>LOAD
DEFEND M  *
```

An 18 KB program at 1200 baud takes about **three minutes**, which is how long it
took in 1983. If a load has already run past the start of a file, use **Rewind Tape**
and `LOAD` again.

Cassette works on **every** model, not just the IC — they all have the same PIO
wiring — so a CIAB can load tape software too.

---

## Keyboard reference

Default is **Symbolic**, which assumes a **US layout**. In **Positional** mode you get
the MicroBee's ASCII-63 layout:

| You press | Positional gives | | You press | Positional gives |
|---|---|---|---|---|
| `` ` `` | `@` | | Shift+`9` | `)` |
| Shift+`` ` `` | `` ` `` | | Shift+`0` | `0` (nothing) |
| Shift+`2` | `"` | | Shift+`-` | `=` |
| Shift+`6` | `&` | | `=` | `^` |
| Shift+`7` | `'` | | Shift+`=` | `~` |
| Shift+`8` | `(` | | `;` / Shift+`;` | `:` / `*` |
| | | | `'` / Shift+`'` | `;` / `+` |

Letters, digits, Space, Enter, Ctrl, the cursor keys and Shift itself are identical in
both modes. **Home** is Linefeed, **End** is Break, **Caps Lock** is Lock, **Delete**
is DEL.


---

## Credits and attributions

### Core development

- **Diego Viso** ([@diegov-au](https://github.com/diegov-au)) - core development, hardware testing and verification.
-  **Alan Steremberg** ([@alanswx](https://github.com/alanswx)) - core development support.

This core was written from the **factory schematics** wherever possible. Where a
question could not be answered from a drawing, the emulators below were the
reference, and the project is indebted to all of them.

### Reference emulators

- **[ubee512](https://github.com/under4mhz/ubee512)** by **uBee** — the primary
  reference throughout. Its per-model feature table, memory map, CRTC and light-pen
  handling, WD2793 behaviour and disk geometry are what this core was checked
  against, and where two sources disagreed ubee512 was followed. 
- **[MAME](https://github.com/mamedev/mame)** by the MAMEdev team — the `mbee`
  driver, and the better source for per-register semantics: the CRTC keyboard scan,
  the video window decode and the palettes.
- **[FPGABee](https://bitbucket.org/toptensoftware/fpgabee)** by **Topten Software** —
  an independent FPGA MicroBee, used to confirm the memory bank equations and the
  light-pen keyboard structure from a second implementation.
- **[tapetool](https://github.com/toptensoftware/tapetool)** by **Topten Software** —
  the definitive description of the MicroBee `.tap` container and its Kansas City
  modulation, and the tool that produces `.tap` files. The cassette encoder was
  written from its source and cross-checked byte for byte against a real tape.

### Hardware sources

The Applied Technology **factory schematics and PAL dumps** are the
primary sources for the memory map, the video hardware, the Alpha Plus colour palette
and the floppy interface. They are the only sources in the project that are not
somebody else's reading of the hardware.

### Framework and vendored cores

- **[MiSTer](https://github.com/MiSTer-devel/Main_MiSTer)** framework (`sys/`) by
  **Alexey Melnikov (Sorgelig)**, **Till Harbaum** and the MiSTer-devel community —
  HPS interface, video scaling, audio output and the OSD.
- **[tv80](https://github.com/hutch31/tv80)** by **Guy Hutchison** — the Z80 CPU core
  (MIT).
- **`wd1793.sv`** — the WD1793/2793 floppy controller from the MiSTer-devel
  ecosystem, with several fixes made here for MicroBee disk formats.

---

## Licence

**GPL-2.0**, matching the MiSTer framework in `sys/` and the vendored `wd1793.sv`.
The `tv80` CPU core is MIT.

**No ROM content is distributed with this repository.** You supply your own.

---

This core was developed with AI assistance. The RTL, the simulation harness and the
documentation were written collaboratively with Claude, with every hardware behaviour
verified against the factory schematics, the reference emulators listed above, and a
real DE10-Nano.
