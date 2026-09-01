#!/bin/bash
# oc-log.sh — логгер (debug-инструмент, не прод-путь): каждые N сек —
# lact.sh monitor через CRE exec → дописать в файл с таймстампом.
# Usage: oc-log.sh [period_s] [file] [duration_s (0 = до Ctrl-C)]
set -euo pipefail

PERIOD=${1:-10}
FILE=${2:-oc-log-$(date +%Y%m%d-%H%M%S).log}
DURATION=${3:-0}

CRE=podman
[ -f /run/.containerenv ] && CRE=podman-remote

NAME=nvidia-card-setting
[ "$($CRE inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo false)" = "true" ] || {
    echo "ERROR: контейнер $NAME не запущен (systemctl start nvidia-card-setting?)" >&2; exit 2; }
LACT_CONT=$NAME

start=$(date +%s)
echo "# oc-log start $(date -Is) container=$LACT_CONT period=${PERIOD}s" >> "$FILE"
while :; do
  ts=$(date -Is)
  echo "$ts" >> "$FILE"
  if $CRE exec "$LACT_CONT" /lact.sh monitor >> "$FILE" 2>&1; then
    :
  else
    echo "$ts ERROR: monitor failed" >> "$FILE"
  fi
  if [ "$DURATION" != "0" ] && [ $(( $(date +%s) - start )) -ge "$DURATION" ]; then
    break
  fi
  sleep "$PERIOD"
done
echo "OK: log written to $FILE"
