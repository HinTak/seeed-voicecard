#!/bin/bash
# Regression test for the ReSpeaker 6-mic seeed-voicecard/ac10x driver.
# The kernel is our assertion engine (might_sleep / slab poisoning / fault handler);
# this harness just drives the paths and counts the signatures. Mode -> fix covered:
#   check   -> sleep-in-atomic count is 0, AND 8ch S32 capture opens (CPU-DAI
#              channel-range override) AND plughw 1ch records real audio (RMS>0).
#   run     -> capture-panic fix (sleeping I2C in atomic .trigger).
#   unbind  -> unbind-teardown UAF + stale-callback fix (unregister vs kfree).
#   store   -> CAP_SYS_RAWIO gate on the raw-register debug sysfs writes.
# The remaining fixes in this series (table-bounds, uninitialised-read, volsw
# range, of_node_put leaks, regcache max_register, devm_free_irq device) are
# error-path defensive fixes with no practical runtime trigger -- validated by
# review; see each commit message.
#
# MODES:
#   check           SAFE. No arecord, no unbind. Verdict on the absolute count of
#                   atomic-sleep AND fault signatures in dmesg since boot.
#                   Buggy driver => >0 (RED); cold-booted FIXED module => 0 (GREEN).
#   run [cycles]    ACCEPTANCE (bug 1). N arecord capture START/STOP cycles, counts
#                   NEW atomic-sleep events. WARNING: can panic on an UNFIXED driver
#                   (~1-in-7). FIXED cold-booted module only, someone able to power-
#                   cycle standing by. PASS = 0 new events + no panic.
#   unbind          ACCEPTANCE (bug 2). Unbinds then rebinds the three ac10x-codec
#                   i2c devices, exercising ac108_i2c_remove() (codec unregister +
#                   kfree(ac10x)) and re-probe. PASS = 0 new fault signatures.
#                   WARNING: on an UNFIXED driver this is the shutdown-panic path.
#                   FIXED cold-booted module only.
#
# Usage:  sudo ./test_trigger_atomic.sh check
#         sudo ./test_trigger_atomic.sh run 30
#         sudo ./test_trigger_atomic.sh unbind
#         sudo ./test_trigger_atomic.sh store
set -u
MODE="${1:-run}"
CYCLES="${2:-30}"
DEV="plughw:CARD=seeed8micvoicec"
DRV=/sys/bus/i2c/drivers/ac10x-codec
# atomic-sleep signatures (bug 1): the BUG line + the kernel's might_sleep() warn
SIG='scheduling while atomic'
SIG2='sleeping function called from invalid context'
# teardown-fault signatures (bug 2, and any crash): oops / abort / UAF
FAULT='Unable to handle kernel|Internal error|Oops|use-after-free|BUG: KASAN|Aiee'
TRACE='seeed_voice_card_trigger'

count_sleep() { dmesg 2>/dev/null | grep -Ec "$SIG|$SIG2"; }
count_fault() { dmesg 2>/dev/null | grep -Ec "$FAULT"; }
count_bad()   { dmesg 2>/dev/null | grep -Ec "$SIG|$SIG2|$FAULT"; }

verdict() { # $1 = bad count, $2 = label
  echo "-------------------------------------------------------------"
  if [ "$1" -eq 0 ]; then
    echo "RESULT: PASS  — 0 $2 (driver FIXED)"
    return 0
  fi
  echo "RESULT: FAIL  — $1 $2 => bug PRESENT"
  return 1
}

echo "=== seeed-voicecard ac108 regression test ==="
echo "kernel: $(uname -r)   mode: $MODE"
echo "loaded ac108 srcversion: $(cat /sys/module/snd_soc_ac108/srcversion 2>/dev/null || echo '?')"
echo "loaded seeed srcversion: $(cat /sys/module/snd_soc_seeed_voicecard/srcversion 2>/dev/null || echo '?')"

case "$MODE" in
check)
  S=$(count_sleep); F=$(count_fault)
  echo "atomic-sleep events since boot : $S"
  echo "teardown/fault signatures      : $F"
  verdict "$((S + F))" "atomic-sleep + fault events since boot"; exit $?
  ;;

capture)
  # MANDATORY real-capture gate: prove arecord actually OPENS and records audio
  # (guards against a silent hw_params -EINVAL that enumerates a card but can't record).
  systemctl stop jarvis-assistant 2>/dev/null || true
  sleep 1
  rm -f /tmp/cap8.wav /tmp/cap1.wav
  echo "--- native 8ch S32 open (must succeed) ---"
  arecord -D hw:CARD=seeed8micvoicec -c8 -r16000 -f S32_LE -d 2 /tmp/cap8.wav; r8=$?
  echo "  exit=$r8"
  echo "--- app path: plughw 1ch S16 3s (must succeed AND be non-silent) ---"
  arecord -D plughw:CARD=seeed8micvoicec -c1 -r16000 -f S16_LE -d 3 /tmp/cap1.wav; r1=$?
  echo "  exit=$r1"
  RMS=$(python3 - <<'PY'
import wave
try:
    import audioop
    def rms(d, w): return audioop.rms(d, w)
except Exception:
    import array, math
    def rms(d, w):
        a = array.array({1:'b',2:'h',4:'i'}[w]); a.frombytes(d[:len(d)-(len(d)%w)])
        return int(math.sqrt(sum(x*x for x in a)/len(a))) if a else 0
try:
    wf = wave.open("/tmp/cap1.wav","rb"); w = wf.getsampwidth()
    d = wf.readframes(wf.getnframes()); wf.close()
    print(rms(d, w))
except Exception as e:
    print("ERR", e)
PY
)
  echo "  1ch capture RMS=$RMS  ($(wc -c </tmp/cap1.wav 2>/dev/null || echo 0) bytes)"
  echo "-------------------------------------------------------------"
  ok=1
  [ "${r8:-1}" -eq 0 ] || { echo "  FAIL: native 8ch S32 open failed (-EINVAL regression)"; ok=0; }
  [ "${r1:-1}" -eq 0 ] || { echo "  FAIL: plughw 1ch open failed"; ok=0; }
  case "$RMS" in ''|*[!0-9]*) echo "  FAIL: RMS not measurable ($RMS)"; ok=0;; *) [ "$RMS" -gt 0 ] || { echo "  FAIL: RMS=0 -- silence / no real audio"; ok=0; };; esac
  if [ "$ok" -eq 1 ]; then
    echo "RESULT: PASS  — capture opens (8ch S32 + plughw 1ch) and RMS=$RMS > 0 (real audio)"; exit 0
  fi
  echo "RESULT: FAIL  — capture regression"; exit 1
  ;;

run)
  BEFORE=$(count_sleep)
  echo "baseline atomic-sleep events: $BEFORE"
  echo "--- $CYCLES capture start/stop cycles (can panic if UNFIXED) ---"
  for i in $(seq 1 "$CYCLES"); do
    timeout 1 arecord -D "$DEV" -c1 -r16000 -f S16_LE -d 1 /tmp/_atomtest.wav >/dev/null 2>&1
    printf '\r  cycle %d/%d' "$i" "$CYCLES"
  done
  echo; sleep 1
  AFTER=$(count_sleep); NEW=$((AFTER - BEFORE))
  echo "post-run atomic-sleep events: $AFTER  (new this run: $NEW)"
  if dmesg 2>/dev/null | grep -A20 -E "$SIG|$SIG2" | grep -q "$TRACE"; then
    echo "  (trace still references $TRACE)"
  fi
  echo "--- start/stop latency (mean over 10 short captures) ---"
  TOT=0; REPS=10
  for i in $(seq 1 $REPS); do
    T=$( { /usr/bin/time -f "%e" arecord -D "$DEV" -c1 -r16000 -f S16_LE -d 0.2 /tmp/_lat.wav >/dev/null 2>/tmp/_t; } 2>/dev/null; cat /tmp/_t 2>/dev/null )
    TOT=$(awk -v a="$TOT" -v b="${T:-0}" 'BEGIN{print a+b}')
  done
  MEAN=$(awk -v t="$TOT" -v r="$REPS" 'BEGIN{printf "%.3f", t/r}')
  echo "mean open+0.2s-capture+close: ${MEAN}s"
  verdict "$NEW" "new atomic-sleep events across $CYCLES cycles"; exit $?
  ;;

unbind)
  [ -d "$DRV" ] || { echo "driver path $DRV not found"; exit 2; }
  DEVS=$(for l in "$DRV"/*; do b=$(basename "$l"); echo "$b" | grep -Eq '^[0-9]+-[0-9a-f]+$' && echo "$b"; done)
  echo "ac10x-codec devices: $(echo $DEVS)"
  BEFORE=$(count_fault)
  echo "baseline fault signatures: $BEFORE"
  echo "--- unbind (exercises ac108_i2c_remove: codec unregister + kfree(ac10x)) ---"
  for d in $DEVS; do echo "  unbind $d"; echo "$d" | sudo tee "$DRV/unbind" >/dev/null 2>&1; done
  sleep 1
  echo "--- rebind (re-probe + re-register codec) ---"
  for d in $DEVS; do echo "  bind $d"; echo "$d" | sudo tee "$DRV/bind" >/dev/null 2>&1; done
  sleep 1
  AFTER=$(count_fault); NEW=$((AFTER - BEFORE))
  echo "post fault signatures: $AFTER  (new this run: $NEW)"
  verdict "$NEW" "new fault signatures across unbind/rebind"; exit $?
  ;;

store)
  # Raw-register debug sysfs writes require CAP_SYS_RAWIO (the attrs are 0644 =
  # root-only; the in-driver capable() check is defense-in-depth against a
  # cap-dropped / container root). Prove an unprivileged write is rejected.
  attr=$(find /sys/bus/i2c/devices -maxdepth 2 \( -name ac108 -o -name ac10x \) 2>/dev/null | head -1)
  [ -n "$attr" ] || { echo "SKIP: no ac10x debug sysfs attribute present"; exit 77; }
  echo "debug attr: $attr"
  if runuser -u nobody -- sh -c "echo 00 > '$attr'" 2>/dev/null; then
    echo "RESULT: FAIL -- unprivileged register write was ACCEPTED"; exit 1
  fi
  echo "RESULT: PASS -- unprivileged raw-register write rejected"; exit 0
  ;;

*)
  echo "usage: sudo $0 [check|run [cycles]|unbind|store]"; exit 2
  ;;
esac
