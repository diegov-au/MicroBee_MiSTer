#!/bin/bash
# MicroBee core regression set.
#
# Run after ANY change. Every number below is a fingerprint of a whole boot -
# disk scan, CPU, CRTC, PIO and video all have to be right to reproduce it - so
# "different" means "something moved", not "probably fine".
#
# The frozen baseline is MicroBee_20260731, which is hardware-verified. See
# docs/STATUS.md "FROZEN BASELINE".
#
#   ./regress.sh            run everything
#   ./regress.sh --quick    skip the three slow disk boots
#
# Tests 7 and 8 hash the RENDERED PIXELS. Everything else reads screen RAM or
# the scanner, and screen RAM was perfectly correct for all three video bugs
# this project has had - the notch, the clipped column and the row-boundary bug
# all lived after it. Without a pixel hash the set cannot see them.
#
# The three disk boots take ~25 min; all run in parallel.

# Everything lives in main() so bash parses the whole file before running any of
# it. Without that, editing this script while a 25-minute run is in flight makes
# bash resume from a now-wrong byte offset and die on a syntax error - which is
# exactly what happened during M7-2, after the tests themselves had all passed.
main() {

cd "$(dirname "$0")" || exit 1

# The regression runs at the true 54 MHz hardware clock - this is the thorough
# pass, so it should exercise the configuration that actually gets synthesised.
# MB_REGRESS_FAST=1 reruns it at 13.5 MHz for a quick sanity check (~4.5x
# quicker). Every assertion below is in frames, and frames are CRTC-derived, so
# the two must agree exactly. If they ever diverge, something depends on the
# master clock rate and that is the bug - which is how the block-device model's
# tick-calibrated SD latency was caught. Unquoted on purpose so the flag
# word-splits into the command line.
FAST=
[ -n "$MB_REGRESS_FAST" ] && FAST=--fast
BIN=./obj_dir/Vemu
E="$BIN $FAST"
BOOT0=../release/boot0.rom
R0="--rom-slot 0 $BOOT0"
O=${MB_REGRESS_OUT:-/tmp/mb_regress}

# Test BIN, not E - E carries the flag and is not a filename.
[ -x "$BIN" ] || { echo "No $BIN - run make first."; exit 1; }
echo "=== binary: $E ==="

rm -rf "$O"; mkdir -p "$O" || exit 1

# Mount COPIES, never the masters.
#
# The harness mounts images WRITABLE and has no read-only flag, so any run can
# rewrite the disk it booted from - and several of these numbers ARE the disk
# (test 2's sum= is a plain byte sum of the whole file). A fixture edited by the
# software running on it then reads as a moved core. That has happened twice:
# session 8 lost a gate run to a replaced ciabmaster.dsk, and a CIAB SYSTEM SETUP
# change writes its drive configuration straight back to the image.
#
# release/fixtures/ holds the masters, mode 444, and nothing ever mounts them.
# Verify against the recorded byte sums before trusting a failure:
#   ciabmaster.dsk 55720636   hs-arcade.dsk 33286519
#   microsoft_master.dsk 49578143   raftaway_river.dsk 80673507
#   ciabmaster.ss80 55578237   wordstar.ds8 74469497
#   pattern1200.tap 34778
FIX=../release/fixtures
D="$O/disks"
mkdir -p "$D" || exit 1
[ -d "$FIX" ] || { echo "No $FIX - the fixture masters are missing."; exit 1; }
cp "$FIX"/* "$D"/ || exit 1
chmod u+w "$D"/*

quick=0
[ "$1" = "--quick" ] && quick=1

# Models are explicit: a regression that only shows on the non-default is still
# a regression.
M="--model 64k"

if [ $quick -eq 0 ]; then
  $E --headless $M $R0 --disk "$D/ciabmaster.ss80" \
     --stop-at-frame 900 --dump-screen > "$O/1_ss80.log" 2>&1 &
  $E --headless $M $R0 --disk "$D/ciabmaster.dsk" \
     --stop-at-frame 900 --dump-screen > "$O/2_dsk.log" 2>&1 &
  $E --headless $M $R0 --disk "$D/hs-arcade.dsk" \
     --stop-at-frame 900 --dump-screen --screenshot-frame 890 \
     --screenshot-prefix "$O/arcade_" > "$O/3_arcade.log" 2>&1 &
  $E --headless $M $R0 --disk "$D/raftaway_river.dsk" \
     --stop-at-frame 900 --screenshot-frame 890 \
     --screenshot-prefix "$O/raft_" > "$O/7_raft.log" 2>&1 &

  # 10/11 - the M7-4 RAM axis, as a matched pair on ONE disk and ONE build.
  #
  # microsoft_master.dsk is the gate because it only works on a 128K machine, so
  # it fails closed. A generic CP/M image boots on the 64K CIAB too and therefore
  # cannot tell "the RAM axis works" from "nothing changed".
  #
  # The negative half is asserted, not just assumed. Both runs mount the same
  # image from the same build and differ only in --model, so the pair proves the
  # model switch is really switching - if 64k ever reached A> here, the runtime
  # ram_size select would have stopped selecting.
  $E --headless --model p128k $R0 --disk "$D/microsoft_master.dsk" \
     --stop-at-frame 900 --dump-screen > "$O/10_p128k.log" 2>&1 &
  $E --headless $M $R0 --disk "$D/microsoft_master.dsk" \
     --stop-at-frame 900 --dump-screen > "$O/11_128k_on_64k.log" 2>&1 &

  # 12 - raw DS80 (BUG-012). The ONLY test of wd1793's arithmetic-geometry path
  # on a disk whose sector IDs are not positions.
  #
  # It must be wordstar.ds8 and NOT arcade.ds8. arcade.ds8 reads too few sectors
  # to reach a data cylinder, and it booted correctly through the entire period
  # this path was broken - taking it as proof is how raw DS80 nearly shipped
  # silently wrong. Two disks disagreeing was the finding.
  #
  # What it discriminates: READ ADDRESS must report IDs from the track's own
  # base (21..30 on a data cylinder), because the BIOS reads the numbering off
  # READ ADDRESS and then asks for what it was told. Before the fix this run
  # gave "CP/M Err On A: Bad Sector" at the same PC where the .dsk container
  # asked for sector $16.
  $E --headless --model p128k $R0 --disk "$D/wordstar.ds8" \
     --stop-at-frame 900 --dump-screen > "$O/12_ds80.log" 2>&1 &

  # 13 - drive B: must not be served drive A:'s media (BUG-013).
  #
  # Asserted in BOTH directions on purpose. `Err On B:` alone would also pass on
  # a machine that had wedged before reaching the prompt, so `A>DIR B:` proves
  # the command was typed at a live CP/M first.
  #
  # This uses the 128K CP/M because it is configured for two drives out of the
  # box. A CIAB is single-drive as shipped, and CP/M then aliases B: in software
  # without ever asserting drive select - so a CIAB here would test nothing and
  # look like a pass. See NOTES 2.
  $E --headless --model p128k $R0 --disk "$D/microsoft_master.dsk" \
     --type 'DIR B:\n' --type-start 820 --stop-at-frame 1200 \
     --dump-screen > "$O/13_driveb.log" 2>&1 &
fi

# Tests 4-6 run BASIC, and how they reach it changed with the slot-0 bundle.
#
# They used to pass the BASIC image as --rom on the default model, which loaded
# it into ROM1 bank 0. Bank 0 is now always bn54, so BASIC is only reachable
# where it actually lives - bank 1 - by either of the two routes that select it:
# the 32K IC, whose own ROM1 that is, or a CIAB with --boot-basic.
#
# 5 and 6 taking different routes to the same bank is deliberate and preserves
# what test 6 was for: both must produce identical numbers, so the model table's
# bank select and the boot_basic override still have to agree.
$E --headless --model ic $R0 \
   --type 'PRINT 7*6\n' --dump-screen > "$O/4_kbd.log" 2>&1 &
$E --headless --model ic $R0 --piob7-vsync \
   --type 'PLAY 5\n' --type-start 120 --stop-at-frame 400 > "$O/5_sound.log" 2>&1 &
$E --headless $M $R0 --boot-basic \
   --type 'PLAY 5\n' --type-start 120 --stop-at-frame 400 > "$O/6_bootbasic.log" 2>&1 &

# 9 - the 32K IC has no port $50, so writing it must do NOTHING.
#
# This is the one check on the IC's pinned map, and nothing else in the set
# looks at it in either direction. It is genuinely discriminating: measured on
# the core BEFORE the fix, the same command line left port50=FF and killed the
# machine outright - PC grinding NOPs at $5A77, no `42`, screen frozen at the
# moment of the write. $FF is chosen over a single bit because it moves every
# field at once (NOROMS, VRAM, VADD, ROM3 and the block select), so a decode
# that pins only some of them still fails here.
#
# Both halves are asserted. `port50=00` is the register itself; ` 42.` is that
# the machine is still alive and running BASIC out of ROM afterwards. A fix that
# swallowed the write but wedged the machine would pass the first alone.
$E --headless --model ic $R0 \
   --type 'OUT 80,255\nPRINT 7*6\n' --stop-at-frame 360 \
   --dump-screen > "$O/9_ic_p50.log" 2>&1 &

# 14 - cassette LOAD (M8-1). The whole tape path in one run: the start trigger
# fires off the read rate, blocks stream from the SD model, the encoder frames
# bytes into Kansas City tones, and the ROM's own decoder reads them back.
#
# pattern1200.tap is 256 bytes of 00,01,02,... at 1200 baud, loading at $4000.
# Small on purpose: defender.tap is 18 KB, which is 167 seconds of EMULATED time
# and would dominate a set that is already bandwidth-bound (NOTES 11). 1200 baud
# rather than 300 for the same reason - and because it is the rate that broke.
#
# THREE assertions, and each fails separately:
#   'TEST   M'     the ROM found and checksummed the 16-byte header. Header
#                  bytes go out at 300 baud whatever the tape's speed, so this
#                  covers the leader, the framing and the header checksum.
#   the $4000 dump the DATA arrived intact - the ROM verifies a checksum per
#                  block, so a wrong byte anywhere shows up as 'Bad load'
#                  instead. This is the half that only passes at 1200 baud.
#   bytes fed=338  the transport actually moved. A tape that never started
#                  would leave the screen at '>LOAD' forever, which the first
#                  two catch, but this one names the reason.
#
# 338 = 352 file bytes less the 14-byte container signature, which is skipped
# rather than modulated. It is IDENTICAL at 13.5 and 54 MHz, which is the whole
# point of clocking the tape off ce_pix - and it was 337 under --fast until a
# settle tick was added to the signature skip, which is exactly the kind of
# clock-rate divergence this set exists to catch.
$E --headless --model ic $R0 --piob7-vsync --tape "$D/pattern1200.tap" \
   --type 'LOAD\n' --type-start 150 --stop-at-frame 620 \
   --dump-mem 0x4000,16 --dump-screen > "$O/14_tape.log" 2>&1 &

# 15 - Cold Boot (session 11). The 32K IC is the model this exists for: with no
# disk to reboot from, and a machine-code game owning the machine and leaving no
# prompt to type NEW at, a reset alone can never get BASIC's memory back. On a
# disk machine it matters far less - CP/M reloads and overwrites anyway.
#
# Run as a PAIR differing in exactly one flag, because BASIC itself reports which
# path it took and that is the only thing that separates them:
#   --reset       warm start - the workspace survives, so it prints `Ready`
#   --cold-boot   cold start - DRAM is zero, so it reprints the Microworld banner
#
# The negative control is the whole point. A Cold Boot that reset the CPU and
# silently failed to clear anything would still reboot the machine and would
# still look right on screen; only the banner tells the two apart. Measured
# before this was written, not assumed: 15a prints `Ready` and 15b prints
# `Copyright MS 1983`.
#
# The tick count is the third assertion and the one that says the DRAM walk
# really ran - 131,072 bytes, one per clk_sys cycle, the whole array. It is the
# same at 13.5 and 54 MHz because the walk is clocked off clk_sys and counted in
# clk_sys ticks, not frames.
$E --headless --model ic $R0 --piob7-vsync \
   --reset 200 --stop-at-frame 400 --dump-screen > "$O/15a_reset.log" 2>&1 &
$E --headless --model ic $R0 --piob7-vsync \
   --cold-boot 200 --stop-at-frame 400 --dump-screen > "$O/15b_cold.log" 2>&1 &
wait

pass=0; fail=0
check() { # check <label> <file> <regex>
  if grep -qE "$3" "$2" 2>/dev/null; then
    echo "  PASS  $1"; pass=$((pass+1))
  else
    echo "  FAIL  $1"; fail=$((fail+1))
    grep -hE "sum=|toggles=" "$2" 2>/dev/null | sed 's/^/          got: /' | head -2
  fi
}

# The negative half of the M7-4 gate. A test whose expected result is "this does
# NOT happen" needs the file to exist, or a missing log would pass silently.
check_absent() { # check_absent <label> <file> <regex>
  if [ ! -s "$2" ]; then
    echo "  FAIL  $1  (no log - the run did not happen)"; fail=$((fail+1))
  elif grep -qE "$3" "$2" 2>/dev/null; then
    echo "  FAIL  $1  (present, and it must not be)"; fail=$((fail+1))
  else
    echo "  PASS  $1"; pass=$((pass+1))
  fi
}

echo "=== MicroBee regression ==="
if [ $quick -eq 0 ]; then
  check "1 raw ss80      sum=58646"        "$O/1_ss80.log"      'sum=58646'
  check "1 raw ss80      CIAB menu"        "$O/1_ss80.log"      'Table of Contents'
  check "2 .dsk          sectors=800"      "$O/2_dsk.log"       'sectors=800.*sum=55720636'
  check "2 .dsk          CIAB menu"        "$O/2_dsk.log"       'Table of Contents'
  check "3 arcade        sectors=225"      "$O/3_arcade.log"    'sectors=225.*sum=33286519'
  check "3 arcade        banner"           "$O/3_arcade.log"    'arcade-style games'
  check "3 arcade        toggles=201"      "$O/3_arcade.log"    'toggles=201'
  check   "10 p128k       reaches A>"      "$O/10_p128k.log"       '\|A>'
  check   "10 p128k       CP/M directory"  "$O/10_p128k.log"       'MBASIC'
  check_absent "11 same disk on 64k fails" "$O/11_128k_on_64k.log" '\|A>'
  check   "12 raw DS80     reaches A>"     "$O/12_ds80.log"        '\|A>'
  check   "12 raw DS80     WordStar dir"   "$O/12_ds80.log"        'WSMSGS'
  check   "13 drive B      command typed"  "$O/13_driveb.log"      'A>DIR B:'
  check   "13 drive B      not ready"      "$O/13_driveb.log"      'Err On B:'
fi
check   "4 keyboard      42."              "$O/4_kbd.log"       '\| 42\.'
check   "5 sound         271/346"          "$O/5_sound.log"     'toggles=271.*acks=346'
check   "6 boot-basic    271/346"          "$O/6_bootbasic.log" 'toggles=271.*acks=346'
check   "9 IC no \$50     port50=00"        "$O/9_ic_p50.log"    'port50=00'
check   "9 IC no \$50     still alive"      "$O/9_ic_p50.log"    '\| 42\.'
check   "14 tape         header read"      "$O/14_tape.log"     '\|TEST   M'
check   "14 tape         data at \$4000"    "$O/14_tape.log"     '00 01 02 03 04 05 06 07'
check   "14 tape         bytes fed=338"    "$O/14_tape.log"     'bytes fed=338'
check        "15 reset       warm start"   "$O/15a_reset.log"   '\|Ready'
check_absent "15 reset       no banner"    "$O/15a_reset.log"   'Copyright MS 1983'
check        "15 cold reset  cold start"   "$O/15b_cold.log"    'Copyright MS 1983'
check        "15 cold reset  cleared 128K" "$O/15b_cold.log"    'clearing ticks=131072'

if [ $quick -eq 0 ]; then
  echo
  echo "=== rendered-pixel hashes (compare against the last known-good run) ==="
  for p in "$O"/arcade_*.png "$O"/raft_*.png; do
    [ -f "$p" ] && sha1sum "$p" | sed "s|$O/|  |"
  done
  echo "  (these are not asserted - they change legitimately when video changes"
  echo "   on purpose. Diff them by eye against the previous run and explain any"
  echo "   move before committing.)"
fi

echo
echo "=== $pass passed, $fail failed ==="
[ $fail -eq 0 ] || return 1

}

main "$@"
