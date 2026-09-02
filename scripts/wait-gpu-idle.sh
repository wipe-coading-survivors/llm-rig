#!/bin/bash
# Ожидание GPU-idle по демону lact-autoswitch: поле 2 последней строки
# /run/lact-autoswitch/history.log == I (демон переводит профиль в Idle
# после TIME_IDLE секунд без запросов — строка I уже «подтверждённый
# простой»).
#
# usage:
#   wait-gpu-idle.sh --status    текущее состояние; rc 0 = idle, 1 = busy
#   wait-gpu-idle.sh [TIMEOUT]   ждать idle (сек, по умолчанию 900);
#                                rc 0 = idle, 124 = timeout, 2 = нет лога
#
# Путь к истории переопределяется WAIT_GPU_IDLE_HIST (тесты).
set -eu

HIST="${WAIT_GPU_IDLE_HIST:-}"
if [ -z "$HIST" ]; then
    for c in /run/host/run/lact-autoswitch/history.log \
             /run/lact-autoswitch/history.log; do
        [ -f "$c" ] && HIST="$c" && break
    done
fi
if [ -z "$HIST" ] || [ ! -f "$HIST" ]; then
    echo "wait-gpu-idle: history.log not found" >&2
    exit 2
fi

state() { tail -1 "$HIST" | cut -d, -f2; }

case "${1:---status}" in
    --status)
        s=$(state)
        echo "state=$s"
        [ "$s" = I ]
        ;;
    *)
        timeout=$1
        case "$timeout" in
            ''|*[!0-9]*) echo "wait-gpu-idle: TIMEOUT must be a positive integer" >&2; exit 2;;
        esac
        start=$(date +%s)
        while :; do
            s=$(state)
            if [ "$s" = I ]; then
                echo "idle (state=I, $HIST)"
                exit 0
            fi
            now=$(date +%s)
            if [ $((now - start)) -ge "$timeout" ]; then
                echo "wait-gpu-idle: timeout after ${timeout}s (last state=$s)" >&2
                exit 124
            fi
            sleep 5
        done
        ;;
esac
