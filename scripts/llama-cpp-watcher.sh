#!/bin/bash
# llama-cpp-watcher.sh — прод-zombie-наблюдатель (Этап 10).
#
# Крахнувший (Xid 13) сервер не умирает, а висит: запросы таймаутятся,
# юнит «active», nvidia-smi «здоров» (мёртв только in-process
# CUDA-контекст). Надёжный сигнал — собственная строка сервера в
# журнале (под юнитом llama-cpp) — zombie-сигнатура (PATTERN ниже).
# Скрипт следит за потоком и киллит prod-контейнер — юнит
# (Restart=always + RestartSec=30) оживляет его сам (конвенция
# контрольной плоскости, спека stage15 3.1: триггер =
# container-уровень).
#
# Host-скрипт под юнитом llama-cpp-watcher.service; stdout — журнал:
# каждое действие — audit-строка.
set -u

UNIT=llama-cpp
CONTAINER=llama-cpp
PATTERN='CUDA error: an illegal memory access'
# D6 (30.08, live-окно): 2-я zombie-сигнатура из краш-каскада (cublas) —
# все 7 крахов каскада = zombie-смерти в 0.2-0.3 s после child-start,
# обе строки — одно корневое состояние
PATTERN_2='CUDA error: an internal operation failed'
COOLDOWN=120
# stage 27: crash-события для pin-политики lact-autoswitch (спека
# 2026-09-03-stage27-pin-safe-design.md §4.1); env-override — тесты
CRASH_EVENTS_FILE=${CRASH_EVENTS_FILE:-/run/lact-autoswitch/crashes}

log() { echo "[$(date '+%F %T')] $*"; }
err() { echo "[$(date '+%F %T')] ERR: $*"; }

LAST_ACT=0

act() {
  # $1 = строка-триггер (для audit-строки).
  local state
  state=$(systemctl is-active "$UNIT" 2>/dev/null || true)
  if [ "$state" != "active" ] && [ "$state" != "activating" ]; then
    log "skip: unit $UNIT is '$state' (осознанный стоп / обслуживание)"
    return 0
  fi
  err "zombie-сигнатура в журнале $UNIT: $1"
  record_crash_event
  if podman kill "$CONTAINER" 2>/dev/null; then
    log "killed $CONTAINER — юнит оживит (Restart=always, RestartSec=30)"
  else
    log "WARN: podman kill $CONTAINER не удался (контейнер уже исчез?)"
  fi
  LAST_ACT=$(date +%s)
}

record_crash_event() {
  mkdir -p "$(dirname "$CRASH_EVENTS_FILE")"
  echo "$(date +%s)" >> "$CRASH_EVENTS_FILE"
  tail -n 100 "$CRASH_EVENTS_FILE" > "$CRASH_EVENTS_FILE.tmp"
  mv "$CRASH_EVENTS_FILE.tmp" "$CRASH_EVENTS_FILE"
}

main() {
  local since line now
  local jargs=(-f -u "$UNIT")
  since=$(systemctl show -p ActiveEnterTimestamp --value "$UNIT" 2>/dev/null || true)
  [ -n "$since" ] && jargs+=(--since "$since")
  log "started: журнал -u $UNIT ${since:+(history с $since)}; паттерны: $PATTERN / $PATTERN_2; cooldown: ${COOLDOWN}s"
  while IFS= read -r line; do
    case $line in
    *"$PATTERN"*|*"$PATTERN_2"*)
      now=$(date +%s)
      if [ "$LAST_ACT" -eq 0 ] || [ $((now - LAST_ACT)) -ge "$COOLDOWN" ]; then
        act "$line"
      else
        log "повтор паттерна — cooldown активен, skip"
      fi
      ;;
    esac
  done < <(journalctl "${jargs[@]}" 2>/dev/null)
  log "поток журнала закрыт — exit (юнит Restart=always поднимет watcher)"
}

main "$@"
