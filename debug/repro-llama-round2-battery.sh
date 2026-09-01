#!/bin/bash
# Round-2 battery: N холодных prefill с вариацией размеров (новые seed,
# slot auto, maxtok=1). Xid-контроль на каждом шаге.
# Env: OUT GPUCSV BASE CONT N SIZES STOP
set -u
OUT=${OUT:?}
GPUCSV=${GPUCSV:?}
BASE=${BASE:-http://127.0.0.1:8080}
CONT=${CONT:?}
N=${N:-12}
SIZES=${SIZES:-"170000 81000 18000"}
CONC=${CONC:-0}
ROUNDS=${ROUNDS:-}
PAR=${PAR:-4}
MAXTOK=${MAXTOK:-1}
STOP=${STOP:-debug/repro-llama-round2.stop}
CRE=podman
[ -f /run/.containerenv ] && CRE=podman-remote
: > "$OUT"; : > "$GPUCSV"; rm -f "$STOP"
echo "t,card,temp_c,power_w,sm_mhz,mem_mhz" >> "$GPUCSV"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$OUT"; }
xid_count() {
  if [ -n "${XID_FAKE_FILE:-}" ]; then
    cat "$XID_FAKE_FILE" 2>/dev/null || echo 0
  else
    dmesg 2>/dev/null | grep -c "Xid" || true
  fi
}

gpu_sampler() {
  while [ ! -f "$STOP" ]; do
    "$CRE" exec "$CONT" /opt/nvidia/bin/nvidia-smi \
      --query-gpu=index,temperature.gpu,power.draw,clocks.sm,clocks.mem \
      --format=csv,noheader,nounits 2>/dev/null | \
    while IFS=, read -r i t p s m; do
      echo "$(date +%s),$i,$t,$p,$s,$m" >> "$GPUCSV"
    done
    sleep 5
  done
}

dump_and_exit() {
  log "!!! $2"
  dmesg 2>/dev/null | grep "Xid" | tail -6 >> "$OUT"
  "$CRE" logs "$CONT" --tail 250 >> "$OUT" 2>&1 || true
  touch "$STOP"
  [ -n "${SAMPLER:-}" ] && wait "$SAMPLER" 2>/dev/null
  exit "$1"
}

run_step() {
  local label=$1 seed=$2 tok=$3 step=${4:-0}
  local before after res
  before=$(xid_count)
  if [ "${CONC:-0}" -gt 1 ]; then
    log "step $label (${CONC} parallel, seeds $((seed*10))..$((seed*10+CONC-1))):"
    local j pids=() fails=0
    for ((j=0; j<CONC; j++)); do
      local stok=${SZ[$(( (seed + j) % nsh ))]}
      log "  slot$j: ~${stok} tok"
      ( python3 debug/llama-send.py "$BASE" $((seed * 10 + j)) "$stok" "$MAXTOK" "$j" >> "$OUT" 2>&1 ) &
      pids+=("$!")
    done
    for p in "${pids[@]}"; do wait "$p" || fails=$((fails+1)); done
    # fake-Xid: имитация краха ВО ВРЕМЯ запроса (до чтения after)
    if [ -n "${XID_FAKE_FILE:-}" ]; then
      case "${XID_FAKE_INJECT:-}" in
        "it$step") log "FAKE-XID: +3 during $label (debug)"; echo $(( $(cat "$XID_FAKE_FILE") + 3 )) > "$XID_FAKE_FILE";;
      esac
    fi
    sleep 8
    after=$(xid_count)
    log "  Xid: before=$before after=$after (fails=$fails/$CONC)"
    if [ "$after" -gt "$before" ]; then
      dump_and_exit 10 "XID DETECTED at step $label ($CONT)"
    fi
    [ "$fails" -gt 0 ] && dump_and_exit 11 "$fails/$CONC requests failed at step $label (res в $OUT)"
    curl -s -m 5 "$BASE/health" 2>/dev/null | grep -q ok || dump_and_exit 11 "server down at step $label"
    sleep 5
    return
  fi
  log "step $label (seed=$seed, ~${tok} tok):"
  res=$(python3 debug/llama-send.py "$BASE" "$seed" "$tok" "$MAXTOK" -1)
  log "  $res"
  # fake-Xid: имитация краха ВО ВРЕМЯ запроса (до чтения after)
  if [ -n "${XID_FAKE_FILE:-}" ]; then
    case "${XID_FAKE_INJECT:-}" in
      "it$step") log "FAKE-XID: +3 during $label (debug)"; echo $(( $(cat "$XID_FAKE_FILE") + 3 )) > "$XID_FAKE_FILE";;
    esac
  fi
  sleep 8
  after=$(xid_count)
  log "  Xid: before=$before after=$after"
  if [ "$after" -gt "$before" ]; then
    dump_and_exit 10 "XID DETECTED at step $label ($CONT)"
  fi
  case "$res" in ok*) ;; *) dump_and_exit 11 "request failed at step $label: $res";; esac
  curl -s -m 5 "$BASE/health" 2>/dev/null | grep -q ok || dump_and_exit 11 "server down at step $label"
  sleep 5
}

# ROUNDS-режим: каждый паттерн (размер через '-', паттерны через '|') =
# раунд конкурентных запросов; slot j -> id_slot=j если j < PAR, иначе auto
# (очередь). N = число полных проходов по списку паттернов.
run_pattern() {
  local label=$1 pattern=$2 seedbase=$3 step=$4
  local before after
  local -a psizes
  IFS='-' read -r -a psizes <<< "$pattern"
  before=$(xid_count)
  log "step $label (${#psizes[@]} parallel: $pattern):"
  local j pids=() fails=0 slotarg
  for ((j=0; j<${#psizes[@]}; j++)); do
    slotarg=-1
    [ "$j" -lt "$PAR" ] && slotarg=$j
    log "  slot$j: ~${psizes[j]} tok"
    ( python3 debug/llama-send.py "$BASE" $((seedbase + j)) "${psizes[j]}" "$MAXTOK" "$slotarg" >> "$OUT" 2>&1 ) &
    pids+=("$!")
  done
  for p in "${pids[@]}"; do wait "$p" || fails=$((fails+1)); done
  if [ -n "${XID_FAKE_FILE:-}" ]; then
    case "${XID_FAKE_INJECT:-}" in
      "it$step") log "FAKE-XID: +3 during $label (debug)"; echo $(( $(cat "$XID_FAKE_FILE") + 3 )) > "$XID_FAKE_FILE";;
    esac
  fi
  sleep 8
  after=$(xid_count)
  log "  Xid: before=$before after=$after (fails=$fails/${#psizes[@]})"
  if [ "$after" -gt "$before" ]; then
    dump_and_exit 10 "XID DETECTED at step $label ($CONT)"
  fi
  [ "$fails" -gt 0 ] && dump_and_exit 11 "$fails/${#psizes[@]} requests failed at step $label (res в $OUT)"
  curl -s -m 5 "$BASE/health" 2>/dev/null | grep -q ok || dump_and_exit 11 "server down at step $label"
  sleep 5
}

log "=== ROUND2 BATTERY START (N=$N, SIZES=[$SIZES], CONC=$CONC, ROUNDS=[$ROUNDS], PAR=$PAR, $CONT) $(date '+%H:%M:%S') ==="
log "waiting for server health..."
HW=${HEALTH_WAIT:-150}
for w in $(seq 1 $HW); do
  if curl -s -m 3 "$BASE/health" 2>/dev/null | grep -q ok; then break; fi
  sleep 5
done
if ! curl -s -m 3 "$BASE/health" 2>/dev/null | grep -q ok; then
  log "ERROR: server not healthy after $HW polls, aborting"
  exit 12
fi
XBASE=$(xid_count)
log "server healthy; Xid baseline: $XBASE (watchdog: рост Xid -> kill $CONT, rc=10)"
gpu_sampler &
SAMPLER=$!
trap 'dump_and_exit 10 "WATCHDOG Xid abort ($CONT)"' TERM
(
  while [ ! -f "$STOP" ]; do
    sleep 5
    cur=$(xid_count)
    if [ "$cur" -gt "$XBASE" ]; then
      log "WATCHDOG: Xid $XBASE -> $cur — kill $CONT, abort"
      timeout 30 "$CRE" logs "$CONT" --tail 2500 > "${OUT}.server" 2>/dev/null || true
      timeout 20 "$CRE" rm -f "$CONT" >/dev/null 2>&1 || true
      touch "$STOP"
      kill -TERM "$$" 2>/dev/null
      break
    fi
  done
) &
WATCHDOG=$!

read -r -a SZ <<< "$SIZES"
nsh=${#SZ[@]}
if [ -n "$ROUNDS" ]; then
  IFS='|' read -r -a PATS <<< "$ROUNDS"
  npat=${#PATS[@]}
  for pass in $(seq 1 "$N"); do
    for ((pi=0; pi<npat; pi++)); do
      step=$(( (pass - 1) * npat + pi + 1 ))
      run_pattern "it$step p$pi pass$pass" "${PATS[pi]}" $(( (pass - 1) * 100000 + pi * 1000 )) "$step"
    done
  done
elif [ "${CONC:-0}" -gt 1 ]; then
  for i in $(seq 1 $N); do
    run_step "it$i x$CONC" $((3000 + i)) 0 "$i"
  done
else
  for i in $(seq 1 $N); do
    tok=${SZ[$(( (i - 1 ) % nsh ))]}
    run_step "it$i size=$tok" $((3000 + i)) "$tok" "$i"
  done
fi

touch "$STOP"
wait "$SAMPLER" 2>/dev/null
kill "$WATCHDOG" 2>/dev/null
wait "$WATCHDOG" 2>/dev/null
log "=== ROUND2 BATTERY done (no Xid, N=$N) $(date '+%H:%M:%S') ==="
exit 0
