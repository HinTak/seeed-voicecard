#!/bin/bash
# Regression test for the DAC-volume-clobber fix in ac101.c (ac10x codec).
#
# BUG (pre-fix): ac101_aif_mute() wrote DAC_VOL_CTRL on every mute/unmute — 0 on mute,
#   a hardcoded 0xA0A0 on unmute. DAC_VOL_CTRL is *also* the ALSA "DAC volume" mixer
#   control, so the driver zeroed the user/alsactl-set volume on EVERY playback stream
#   close. Symptom: the first sound plays, every sound after it is silent (DAC at 0),
#   and any amixer/alsactl "DAC volume" setting is overridden the moment a stream ends.
#
# FIX: ac101_aif_mute() no longer touches DAC_VOL_CTRL (muting is done by gating the
#   speaker/amp); the DAC level is owned purely by the ALSA control. probe() sets one
#   audible default. See the ac101.c comments on aif_mute and codec_probe.
#
# TEST: set "DAC volume" to a known level, force a playback stream open+close, and assert
#   the control is UNCHANGED afterwards. The ALSA control state IS the assertion.
#     buggy module  -> volume reset (drops to 0% / probe default) on close  => FAIL (RED)
#     fixed module  -> volume held across the close                         => PASS (GREEN)
#
# Usage:  sudo ./test_dac_volume_persist.sh            # one open/close cycle
#         CYCLES=5 sudo ./test_dac_volume_persist.sh   # repeat N times
#         TESTVOL='70%' sudo ./test_dac_volume_persist.sh
#
# NOTE: if a userspace mixer/daemon holds the playback stream open forever (which itself
#   masks the bug), stop it first so this test can actually open+close a stream.
set -u
CARD="${CARD:-0}"
DEV="${DEV:-plughw:CARD=seeed8micvoicec}"
CTL="DAC volume"
TESTVOL="${TESTVOL:-80%}"
CYCLES="${CYCLES:-1}"

get() { amixer -c "$CARD" sget "$CTL" 2>/dev/null | grep -o '\[[0-9]*%\]' | head -1; }

if ! amixer -c "$CARD" sget "$CTL" >/dev/null 2>&1; then
  echo "SKIP: no '$CTL' control on card $CARD (is the ac10x codec loaded?)"; exit 77
fi

amixer -c "$CARD" sset "$CTL" "$TESTVOL" >/dev/null 2>&1
set_to=$(get)
echo "set '$CTL' -> $set_to; running $CYCLES playback open/close cycle(s) on $DEV"

fail=0
for i in $(seq 1 "$CYCLES"); do
  before=$(get)
  # 0.1s of silence: opens a playback stream and closes it (fires aif_mute on close)
  head -c 3200 /dev/zero | aplay -q -D "$DEV" -f S16_LE -r 16000 -c 1 -t raw 2>/dev/null
  after=$(get)
  if [ "$before" != "$after" ]; then
    echo "  cycle $i: FAIL  $before -> $after  (DAC volume clobbered on stream close)"
    fail=1
  else
    echo "  cycle $i: ok    held $after"
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "PASS: DAC volume persisted across stream close (clobber fix present)"
  exit 0
else
  echo "FAIL: DAC volume was reset on stream close (buggy/pre-fix module loaded)"
  exit 1
fi
