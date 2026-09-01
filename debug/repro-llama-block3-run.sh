#!/bin/bash
# Блок 3 (§20) + Фаза A (§23.4/§24):
#   MODE=prod (по умолчанию):
#     A2': 4B, 5 GPU tensor-split, БЕЗ LB, 2x170k (STAGE_START=a2)
#     B2': 4B, 5 GPU, БЕЗ LB, compute-sanitizer memcheck (devel-образ,
#          /app = build, идентичный прод), конфиг = A2' 1:1;
#          смоук 1x18k -> 3x170k; smoke-infra-fail -> повтор с
#          GGML_CUDA_ALLREDUCE=none
#     C2:  (rcb=0 и Xid не вырос, либо FORCE_C2=1) OC off: пользователь
#          rmmod/modprobe nvidia + nvidia-smi -pl 130, сигнал
#          debug/repro-llama-block3-driver-reloaded, 27B prod-preset,
#          батарея 12x[170k,81k,18k]
#   MODE=debug: CPU-стуб (4B, --n-gpu-layers 0, порт 8081), промпты 100/1000,
#     сьют веток d1..d6; прод не трогается, сессии живы:
#       d1 clean-path (rc=0)  d2 fake-Xid (rc=10)  d3 watchdog (rc=11)
#       d4 OC-probe (stderr виден)  d5 router-форма (lazy instance)
#       d6 health-timeout (rc=12)
# prod ВСЕГДА возвращается restore_prod (юнит llama-cpp.service: stop/start через systemctl; debug/llama-run.sh — manual fallback, только если юнит неработоспособен).
# Фиксы: $(elapsed) [было: unbound $elapsed, смерть run-1], trap-статус,
# OC-probe до стопа прода + stderr, STAGE_START, FORCE_C2, rm leftover'ов.
set -u
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODE=${MODE:-prod}
if [ "$MODE" = "debug" ]; then
  OUT=debug/repro-llama-block3-debug-run.log
  STATUS=debug/repro-llama-block3-debug-run.status
  JOURNAL=debug/repro-llama-block3-debug-journal.md
  BASE_PORT=8081
  GRACE=${GRACE:-0}
  GLOBAL_TIMEOUT=${GLOBAL_TIMEOUT:-3600}
else
  OUT=debug/repro-llama-block3-run.log
  STATUS=debug/repro-llama-block3-run.status
  JOURNAL=${JOURNAL:-docs/superpowers/reports/2026-08-19-llama-server-xid13-crash.md}
  BASE_PORT=8080
  GRACE=${GRACE:-60}
  GLOBAL_TIMEOUT=${GLOBAL_TIMEOUT:-25200}
fi
PROD=llama-cpp
CA=llama-block3-a2
CB=llama-block3-b2
CC=llama-block3-c2
STUB=llama-cpu-stub
PROD_IMG=localhost/llama-cpp-cuda:13.2
DEV_IMG=localhost/llama-cpp-cuda-debug:13.2
DRVREADY=debug/repro-llama-block3-driver-reloaded
STAGE_START=${STAGE_START:-a2}
FORCE_C2=${FORCE_C2:-0}
XID_FAKE_FILE=""
XID_FAKE_INJECT=""
CRE=podman
[ -f /run/.containerenv ] && CRE=podman-remote
HOST_ROOT=""
[ -f /run/.containerenv ] && HOST_ROOT=/run/host
SYSCTL=systemctl
[ -n "$HOST_ROOT" ] && SYSCTL="chroot $HOST_ROOT /usr/bin/systemctl"
START_TS=$(date +%s)
RUNID=$(date +%m%d-%H%M%S)
: > "$OUT"
echo "running" > "$STATUS"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$OUT"; }
jlog() {
  local ts
  ts=$(date '+%F %T')
  echo "- $ts $*" >> "$OUT"
  echo "- $ts $*" >> "$JOURNAL"
}
xid_count() { dmesg 2>/dev/null | grep -c "Xid" || true; }
elapsed() { echo $(( $(date +%s) - START_TS )); }
BASELINE=0
C2_DONE=0

trap 'if [ "$(cat "$STATUS" 2>/dev/null)" = "running" ]; then
  echo "ABORTED (orchestrator exited before final status; see $OUT)" > "$STATUS"
  echo "[$(date '+%H:%M:%S')] TRAP: orchestrator aborted early" >> "$OUT"
fi' EXIT

timeout_abort() {
  log "FATAL: global timeout ${GLOBAL_TIMEOUT}s (elapsed $(elapsed)s) — abort, restore prod"
  jlog "ABORT: global timeout, restore prod"
  echo "TIMEOUT-ABORT (elapsed $(elapsed)s) Xid=$(xid_count)/$BASELINE" > "$STATUS"
  restore_prod
  exit 1
}

restore_prod() {
  if [ "$MODE" = "debug" ]; then
    log "restore_prod: no-op (debug)"
    return 0
  fi
  log "restoring prod (unit llama-cpp)"
  jlog "restore_prod: removing test containers, starting prod unit"
  $CRE rm -f "$CA" >/dev/null 2>&1 || true
  $CRE rm -f "$CB" >/dev/null 2>&1 || true
  $CRE rm -f "$CC" >/dev/null 2>&1 || true
  $SYSCTL start llama-cpp >> "$OUT" 2>&1 \
    || log "WARN: prod restore FAILED — запустить вручную: systemctl start llama-cpp (llama-run.sh — только если юнит неработоспособен)"
  log "prod state: $($SYSCTL is-active llama-cpp 2>/dev/null) | $($CRE ps --format '{{.Names}} | {{.Status}}' 2>/dev/null | grep "^$PROD" || echo NOT-RUNNING)"
  jlog "restore_prod done"
}

oc_probe() {
  # mem clock GPU0 (8301=OC on, 7501=off, 405=idle); stderr не глотается.
  # raw-строка — только в $OUT (log() в stdout ломает $(oc_probe) capture)
  local out
  out=$($CRE run --rm --device /dev/nvidia0 --security-opt label=disable --privileged \
    --entrypoint /opt/nvidia/bin/nvidia-smi \
    "$PROD_IMG" \
    -i 0 --query-gpu=clocks.mem --format=csv,noheader,nounits 2>&1)
  echo "[$(date '+%H:%M:%S')] OC probe raw: $out" >> "$OUT"
  echo "$out" | grep -E '^[0-9]+$' | head -1
}

tok() {
  case "$1" in
    0) echo CLEAN;; 10) echo XID;; 11) echo REQ-FAIL;; 12) echo HEALTH-TIMEOUT;;
    13) echo LAUNCH-FAIL;; -1) echo SKIPPED;; *) echo "rc=$1";;
  esac
}

run_battery() {
  # run_battery <tag> <container> <watchdog-sec> <N> <SIZES> -> rc батареи
  local tag=$1 cont=$2 maxwd=$3 n=$4 sizes=$5
  local wd r
  ( sleep "$maxwd"; [ -f "debug/repro-llama-block3-$tag.stop" ] || {
      log "WATCHDOG $tag: ${maxwd}s timeout, kill $cont"
      jlog "WATCHDOG $tag: ${maxwd}s timeout, kill $cont"
      $CRE rm -f "$cont" 2>/dev/null; touch "debug/repro-llama-block3-$tag.stop"; } ) &
  wd=$!
  OUT="debug/repro-llama-block3-$tag.out" GPUCSV="debug/repro-llama-block3-$tag-gpus.csv" \
    BASE="http://127.0.0.1:$BASE_PORT" CONT="$cont" N="$n" SIZES="$sizes" CONC="${CONC:-0}" \
    ROUNDS="${ROUNDS:-}" PAR="${PAR:-4}" MAXTOK="${MAXTOK:-1}" \
    STOP="debug/repro-llama-block3-$tag.stop" \
    XID_FAKE_FILE="$XID_FAKE_FILE" XID_FAKE_INJECT="$XID_FAKE_INJECT" \
    HEALTH_WAIT="${HEALTH_WAIT:-150}" \
    bash debug/repro-llama-round2-battery.sh >> "$OUT" 2>&1
  r=$?
  kill $wd 2>/dev/null; wait $wd 2>/dev/null
  if [ $r -ne 0 ]; then
    $CRE logs "$cont" --tail 250 >> "debug/repro-llama-block3-$tag.out" 2>&1 || true
    [ "$MODE" = "prod" ] && dmesg 2>/dev/null | grep "Xid" | tail -6 >> "debug/repro-llama-block3-$tag.out"
  fi
  log "battery $tag rc=$r"
  return $r
}

log "=== BLOCK3 (MODE=$MODE) START $(date '+%F %T') (pid $$) ==="
jlog "BLOCK3 MODE=$MODE START (pid $$, grace ${GRACE}s)"
log "grace ${GRACE}s: запустившая сессия завершает ход до стопа прода (prod)"
sleep "$GRACE"

# ---------- проверки ----------
if [ "$MODE" = "prod" ]; then
  for f in Qwen3.5-4B-Q8_0.gguf qwen3.8-27b-ud-q8_k_xl.gguf; do
    if [ ! -f "/run/host/var/local/llm/gguf-models/$f" ]; then
      log "FATAL: /models/$f отсутствует — abort, прод не трогался"
      echo "FATAL: model $f missing" > "$STATUS"
      exit 1
    fi
  done
else
  if [ ! -f "/run/host/var/local/llm/gguf-models/Qwen3.5-4B-Q8_0.gguf" ]; then
    log "FATAL: /models/Qwen3.5-4B-Q8_0.gguf отсутствует — abort"
    echo "FATAL: model missing" > "$STATUS"
    exit 1
  fi
fi

# OC-probe ДО стопа прода (после стопа временный контейнер падал — run-1/round2)
OCSTATE=$(oc_probe)
log "OC state (GPU0 mem clock): ${OCSTATE:-unknown} (8301=OC on, 7501=off/reloaded)"
OC_OFF_ALREADY=0
case "$OCSTATE" in 7501*) OC_OFF_ALREADY=1;; esac
[ "$OC_OFF_ALREADY" = "1" ] && [ "${FORCE_C2:-0}" != "1" ] && { log "OC уже сброшен — C2 пропустим"; jlog "OC already off (mem clock $OCSTATE) — C2 will be skipped"; }
[ "$OC_OFF_ALREADY" = "1" ] && [ "${FORCE_C2:-0}" = "1" ] && { log "OC уже сброшен + FORCE_C2=1 — C2 запустим (контроль OC off)"; jlog "OC already off + FORCE_C2=1 — C2 will run (OC-off control)"; }

if [ "$MODE" = "debug" ]; then
  XID_FAKE_FILE=debug/repro-llama-block3-fake-xid
  BASELINE=30
  echo 30 > "$XID_FAKE_FILE"
  log "debug: fake-xid baseline 30 ($XID_FAKE_FILE)"
else
  BASELINE=$(xid_count)
  log "models in place; Xid baseline: $BASELINE"
  jlog "models ok; Xid baseline $BASELINE; stopping prod"
  if ! $SYSCTL is-active llama-cpp >/dev/null 2>&1; then
    log "FATAL: prod $PROD не запущен (юнит inactive) — abort"
    echo "FATAL: prod not running at start" > "$STATUS"
    exit 1
  fi
  $SYSCTL stop llama-cpp >> "$OUT" 2>&1 || true
  if $SYSCTL is-active llama-cpp >/dev/null 2>&1; then
    log "FATAL: prod ещё жив — abort"
    echo "FATAL: prod not stopped" > "$STATUS"
    exit 1
  fi
  log "prod stopped"
  jlog "prod stopped"
fi

# ---------- debug suite ----------
launch_stub() {
  # launch_stub <form: plain|router|broken>
  local form=$1
  $CRE rm -f "$STUB" >/dev/null 2>&1 || true
  case "$form" in
    broken)
      $CRE run -d --name "$STUB" "$PROD_IMG" sleep infinity >> "$OUT" 2>&1
      ;;
    plain)
      $CRE run -d --name "$STUB" \
        --security-opt label=disable --shm-size=4g \
        -v /var/local/llm/gguf-models:/models \
        -v /etc/llama:/root/llama:ro \
        -p 8081:8080 \
        "$PROD_IMG" \
          --port 8080 --host 0.0.0.0 --model /models/Qwen3.5-4B-Q8_0.gguf --alias default \
          --n-gpu-layers 0 --ctx-size 32768 --parallel 1 --jinja --threads 28 \
          --api-key-file /root/llama/llama-cpp-keys.txt >> "$OUT" 2>&1
      ;;
    router)
      $CRE run -d --name "$STUB" \
        --security-opt label=disable --shm-size=4g \
        -v /var/local/llm/gguf-models:/models \
        -v /etc/llama:/root/llama:ro \
        -v "$REPO_ROOT":/repo:ro \
        -p 8081:8080 \
        "$PROD_IMG" \
          --port 8080 --host 0.0.0.0 \
          --models-preset /repo/debug/llama-cpu-stub.ini >> "$OUT" 2>&1
      ;;
  esac
}

run_debug_suite() {
  local r1 r2 r3 r5 r6
  log "--- d1: clean-path (plain stub, 2x100)"
  jlog "d1 start (clean-path, 2x100)"
  launch_stub plain || { echo "DEBUG d1=LAUNCH-FAIL" > "$STATUS"; return; }
  echo 30 > "$XID_FAKE_FILE"
  run_battery d1 "$STUB" 120 2 "100 100"; r1=$?
  jlog "d1 rc=$r1 (expect 0)"
  $CRE rm -f "$STUB" >/dev/null 2>&1 || true

  log "--- d2: fake-Xid (инжект +3 после it1 -> rc=10 на it2)"
  jlog "d2 start (fake-Xid)"
  launch_stub plain || { echo "DEBUG d2=LAUNCH-FAIL" > "$STATUS"; return; }
  echo 30 > "$XID_FAKE_FILE"
  XID_FAKE_INJECT=it2
  run_battery d2 "$STUB" 120 2 "100 100"; r2=$?
  XID_FAKE_INJECT=""
  jlog "d2 rc=$r2 (expect 10)"
  $CRE rm -f "$STUB" >/dev/null 2>&1 || true

  log "--- d3: watchdog (WD=40s < health+5000-токенный prefill ~70s -> rc=11)"
  jlog "d3 start (watchdog 40s)"
  launch_stub plain || { echo "DEBUG d3=LAUNCH-FAIL" > "$STATUS"; return; }
  echo 30 > "$XID_FAKE_FILE"
  HEALTH_WAIT=30
  run_battery d3 "$STUB" 40 1 "5000"; r3=$?
  HEALTH_WAIT=""
  jlog "d3 rc=$r3 (expect 11)"
  $CRE rm -f "$STUB" >/dev/null 2>&1 || true

  log "--- d4: OC-probe (выполнен до старта; raw-вывод в $OUT)"
  jlog "d4 done (OC probe raw in run.log)"

  log "--- d5: router-форма (lazy instance, 1x100)"
  jlog "d5 start (router form, lazy instance)"
  launch_stub router || { echo "DEBUG d5=LAUNCH-FAIL" > "$STATUS"; return; }
  echo 30 > "$XID_FAKE_FILE"
  run_battery d5 "$STUB" 300 1 "100"; r5=$?
  jlog "d5 rc=$r5 (expect 0)"
  $CRE rm -f "$STUB" >/dev/null 2>&1 || true

  log "--- d6: health-timeout (sleep-infinity stub, HEALTH_WAIT=6 -> rc=12)"
  jlog "d6 start (health-timeout)"
  launch_stub broken || { echo "DEBUG d6=LAUNCH-FAIL" > "$STATUS"; return; }
  echo 30 > "$XID_FAKE_FILE"
  HEALTH_WAIT=6
  run_battery d6 "$STUB" 60 1 "100"; r6=$?
  HEALTH_WAIT=""
  jlog "d6 rc=$r6 (expect 12)"
  $CRE rm -f "$STUB" >/dev/null 2>&1 || true

  echo "DEBUG d1=$(tok $r1) d2=$(tok $r2) d3=$(tok $r3) d4=OC-PROBE-SEE-LOG d5=$(tok $r5) d6=$(tok $r6)" > "$STATUS"
  log "=== DEBUG SUITE DONE d1=$r1 d2=$r2 d3=$r3 d5=$r5 d6=$r6 elapsed=$(elapsed)s ==="
  jlog "DEBUG SUITE DONE d1=$r1 d2=$r2 d3=$r3 d5=$r5 d6=$r6 elapsed=$(elapsed)s; status: $(cat "$STATUS")"
  return 0
}

if [ "$MODE" = "debug" ]; then
  run_debug_suite
  exit 0
fi

# ---------- A2' ----------
rca=-1
if [ "$STAGE_START" = "a2" ]; then
  log "--- A2': 4B, 5 GPU tensor-split, NO LB, 2x170k, ctx=175k"
  jlog "A2' start: 4B/5GPU no-LB 2x170k"
  $CRE rm -f "$CA" >/dev/null 2>&1 || true
  if ! $CRE run -d --name "$CA" \
      --device /dev/nvidia0 --device /dev/nvidia1 --device /dev/nvidia2 --device /dev/nvidia3 --device /dev/nvidia4 \
      --security-opt label=disable --privileged --shm-size=16g \
      -v /var/local/llm/gguf-models:/models \
      -p 8080:8080 \
      -e LLAMA_LOG_TIMESTAMPS=1 \
      "$PROD_IMG" \
        --port 8080 --host 0.0.0.0 --model /models/Qwen3.5-4B-Q8_0.gguf --alias default \
        --ctx-size 175000 --n-gpu-layers all \
        --flash-attn on --cache-type-k q8_0 --cache-type-v q8_0 \
        --split-mode tensor --tensor-split 1,1,1,1,1 \
        --parallel 1 --jinja >> "$OUT" 2>&1; then
    log "FATAL: $CA не поднялся"; jlog "A2' infra-fail: container launch failed"
    rca=13
  else
    run_battery "a2-$RUNID" "$CA" 1800 2 "170000"
    rca=$?
  fi
  jlog "A2' done rc=$rca (Xid $(xid_count)/$BASELINE); log debug/repro-llama-block3-a2.out"
else
  log "A2' skipped (STAGE_START=$STAGE_START)"
  jlog "A2' skipped (STAGE_START=$STAGE_START)"
fi

# ---------- B2' (4B-only по решению 23.4) ----------
launch_b2() {
  # launch_b2 <container> [extra-env...]
  local cont=$1; shift
  $CRE rm -f "$cont" >/dev/null 2>&1 || true
  $CRE run -d --name "$cont" \
    --device /dev/nvidia0 --device /dev/nvidia1 --device /dev/nvidia2 --device /dev/nvidia3 --device /dev/nvidia4 \
    --security-opt label=disable --privileged --shm-size=16g \
    -v /var/local/llm/gguf-models:/models \
    -p 8080:8080 \
    -e LLAMA_LOG_TIMESTAMPS=1 "$@" \
    --entrypoint /usr/local/cuda/bin/compute-sanitizer \
    "$DEV_IMG" \
      --tool memcheck --launch-timeout 1800 --error-exitcode 42 --print-limit 256 \
      /app/llama-server --port 8080 --host 0.0.0.0 \
      --model /models/Qwen3.5-4B-Q8_0.gguf --alias default \
      --ctx-size 175000 --n-gpu-layers all \
      --flash-attn on --cache-type-k q8_0 --cache-type-v q8_0 \
      --split-mode tensor --tensor-split 1,1,1,1,1 \
      --parallel 1 --jinja >> "$OUT" 2>&1
}

rcb=-1
if [ "$STAGE_START" != "c2" ]; then
  attempt=0
  ar_env=""
  while :; do
    attempt=$((attempt + 1))
    log "--- B2': 4B, 5 GPU, NO LB, sanitizer memcheck, attempt=$attempt AR=${ar_env:-default}"
    jlog "B2' attempt=$attempt start (AR=${ar_env:-default})"
    if ! launch_b2 "$CB" $ar_env; then
      log "FATAL: $CB не поднялся (attempt $attempt)"
      jlog "B2' attempt=$attempt infra-fail: container launch failed"
      rcb=13
      break
    fi
      run_battery "b2-smoke${attempt}-$RUNID" "$CB" 2700 1 "18000"
    rs=$?
    jlog "B2' attempt=$attempt smoke rc=$rs (Xid $(xid_count)/$BASELINE)"
    if [ $rs -eq 10 ]; then rcb=10; break; fi
    if [ $rs -ne 0 ]; then
      if [ "$ar_env" = "" ] && [ $attempt -eq 1 ]; then
        log "B2' smoke infra-fail (rc=$rs) — повтор с GGML_CUDA_ALLREDUCE=none"
        jlog "B2' smoke rc=$rs — retry with GGML_CUDA_ALLREDUCE=none"
        $CRE logs "$CB" --tail 100 >> "$OUT" 2>&1 || true
        ar_env="-e GGML_CUDA_ALLREDUCE=none"
        continue
      fi
      rcb=$rs
      break
    fi
      run_battery "b2-full${attempt}-$RUNID" "$CB" 5400 3 "170000"
    rf=$?
    jlog "B2' attempt=$attempt full rc=$rf (Xid $(xid_count)/$BASELINE)"
    rcb=$rf
    break
  done
else
  log "B2' skipped (STAGE_START=$STAGE_START)"
  jlog "B2' skipped (STAGE_START=$STAGE_START)"
fi

# ---------- C2 ----------
rcc=-1
if [ "$FORCE_C2" = "1" ]; then
  c2_ok=1
else
  c2_ok=0
  [ $rcb -eq 0 ] && [ "$(xid_count)" -eq "$BASELINE" ] && { c2_ok=1; }
fi
[ "$OC_OFF_ALREADY" = "1" ] && [ "${FORCE_C2:-0}" != "1" ] && { c2_ok=0; }
[ "$(elapsed)" -ge "$GLOBAL_TIMEOUT" ] && { c2_ok=0; }
if [ "$c2_ok" = "1" ]; then
  log "--- C2: ждём сигнал готовности драйвера (reload/OC — как подготовлено пользователем; $DRVREADY, таймаут 30 мин)"
  jlog "C2 waiting for driver-state signal ($DRVREADY, 30 min)"
  $CRE rm -f "$CB" >/dev/null 2>&1 || true
  sleep 3
  rm -f "$DRVREADY"
  got=0
  for w in $(seq 1 360); do
    [ -f "$DRVREADY" ] && { got=1; break; }
    sleep 5
  done
  if [ "$got" = "0" ]; then
    log "WARN: сигнала драйвера нет 30 мин — C2 пропущен (OC не менялся)"
    jlog "C2 SKIPPED: no driver-reload signal in 30 min"
    rcc=-1
  else
    sleep 10
    log "driver state ready (сигнал); clocks: $($CRE run --rm --device /dev/nvidia0 --security-opt label=disable --privileged --entrypoint /opt/nvidia/bin/nvidia-smi "$PROD_IMG" --query-gpu=index,clocks.mem,power.limit --format=csv,noheader 2>/dev/null | tr '\n' ' ')"
    jlog "C2 driver state ready (signal); battery 12x[${C2_SIZES:-170000 81000 18000}] CONC=${CONC:-1} start"
    C2_DONE=1
    $CRE rm -f "$CC" >/dev/null 2>&1 || true
    if ! $CRE run -d --name "$CC" \
        --device /dev/nvidia0 --device /dev/nvidia1 --device /dev/nvidia2 --device /dev/nvidia3 --device /dev/nvidia4 \
        --security-opt label=disable --privileged --shm-size=64g \
        -v /var/local/llm/gguf-models:/models -v /etc/llama:/root/llama:ro \
        -p 8080:8080 -e LLAMA_LOG_TIMESTAMPS=1 \
        "$PROD_IMG" --port 8080 --host 0.0.0.0 \
        --models-preset /root/llama/llama.ini >> "$OUT" 2>&1; then
      log "FATAL: $CC не поднялся"
      jlog "C2 infra-fail: container launch failed"
      rcc=13
    else
      run_battery "c2-$RUNID" "$CC" "${C2_WD:-5400}" "${C2_N:-12}" "${C2_SIZES:-170000 81000 18000}"
      rcc=$?
    fi
  fi
else
  { [ "$STAGE_START" != "c2" ] || [ "$FORCE_C2" = "1" ]; } && [ $rcb -ne 0 ] && [ "$rcb" -ne -1 ] && { log "C2 skipped (B2' rc=$rcb)"; jlog "C2 skipped (B2' rc=$rcb)"; }
  [ "$(xid_count)" -ne "$BASELINE" ] && [ "$FORCE_C2" != "1" ] && { log "C2 skipped (Xid вырос: $(xid_count)/$BASELINE)"; jlog "C2 skipped (Xid grew)"; }
  [ "$OC_OFF_ALREADY" = "1" ] && { log "C2 skipped (OC уже сброшен до запуска)"; jlog "C2 skipped (OC already off)"; }
  [ "$(elapsed)" -ge "$GLOBAL_TIMEOUT" ] && { log "C2 skipped (global timeout)"; jlog "C2 skipped (global timeout)"; }
fi

# ---------- итог ----------
XC=$(xid_count)
log "=== BLOCK3 DONE rca=$rca rcb=$rcb rcc=$rcc Xid=$XC/$BASELINE elapsed=$(elapsed)s $(date '+%F %T') ==="

restore_prod

sleep 15
OC_AFTER=$(oc_probe)
echo "A2'=$(tok $rca) B2'=$(tok $rcb) C2'=$(tok $rcc) [Xid $XC/$BASELINE, OC-after=${OC_AFTER:-unknown}]" > "$STATUS"
log "OC state after run: ${OC_AFTER:-unknown} (8301=on, 7501=off)"
case "${OC_AFTER:-}" in
  7501*)
    log "NOTE: OC off после прогона — прод работает БЕЗ OC; OC: resources/driver/set-card-properties.sh (хост, X)"
    jlog "NOTE: OC off after run; restore: resources/driver/set-card-properties.sh"
    ;;
esac
jlog "BLOCK3 DONE rca=$rca rcb=$rcb rcc=$rcc Xid=$XC/$BASELINE elapsed=$(elapsed)s; status: $(cat "$STATUS")"
exit 0
