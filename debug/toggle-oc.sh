#!/bin/bash
# toggle-oc.sh <on|off> — смена OC GPU через LACT-контейнер (образ nvidia-lact).
# on:  профиль Default (OC: mem offsets → clocks.max.memory 8501)
# off: профиль safe (без offsets → 7501)
# Опционально (ручной per-card режим, A/B-протокол):
#   PER_CARD_OVERRIDES="id|power_cap=130" — env для apply (id из `lact cli list`
#   в контейнере); оверрайды живут в конфиге (рендер), а не в ad-hoc-вызове:
#   ad-hoc nvidia-smi -pl НЕ является каналом конфигурации — живёт лишь до
#   следующего apply/stop (stop = полный сброс — отчёт §4.3/§5).
# Верификация 8501/7501 — в self-check lact.sh (дубль здесь убран).
set -euo pipefail

MODE=${1:?usage: toggle-oc.sh <on|off>}
case $MODE in on|off) ;; *) echo "bad mode: $MODE (on|off)" >&2; exit 2 ;; esac

CRE=podman
[ -f /run/.containerenv ] && CRE=podman-remote

NVIDIA_DRV_VER=${NVIDIA_DRV_VER:-610.43.03}
LACT_VER=${LACT_VER:-v0.10.0}
HOST_ROOT=""
[ -f /run/.containerenv ] && HOST_ROOT=/run/host
SYSCONFIG=$HOST_ROOT/etc/sysconfig/nvidia-card-setting
NAME=nvidia-card-setting

if [ "$($CRE inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo false)" != "true" ]; then
    # Контейнер не работает (exited/нет): (re)старт паттерном
    # nvidia-card-setting.service — rm -f до старта + --name (иначе
    # exited-контейнеры накапливаются на хосте), env из того же
    # sysconfig, что и юнит.
    [ -f "$SYSCONFIG" ] || { echo "ERROR: контейнер $NAME не запущен и $SYSCONFIG не найден (make systemd?)" >&2; exit 2; }
    mkdir -p "$HOST_ROOT/run/lactd"
    rm -f "$HOST_ROOT/run/lactd/lactd.sock"
    $CRE rm -f "$NAME"
    LACT_IMAGE=$(sed -n 's/^LACT_IMAGE=//p' "$SYSCONFIG")
    [ -n "$LACT_IMAGE" ] || LACT_IMAGE="nvidia-lact-$NVIDIA_DRV_VER:$LACT_VER"
    $CRE run --name "$NAME" --privileged -u 0 \
        -v /etc/lact:/etc/lact:z -v /run/lactd:/run/lactd:z \
        -e LACT_DAEMON_SOCKET_PATH=/run/lactd/lactd.sock \
        --env-file "$SYSCONFIG" \
        "$LACT_IMAGE" /lact.sh daemon
    echo "OK: контейнер $NAME запущен вне systemd-юнита (systemctl start nvidia-card-setting — под юнит)"
    i=0
    while [ "$i" -lt 30 ] && [ -z "$($CRE exec "$NAME" /usr/bin/lact cli list 2>/dev/null | head -1)" ]; do
        sleep 1
        i=$(( i + 1 ))
    done
fi
LACT_CONT=$NAME

if [ "$MODE" = "on" ]; then PROFILE=""; else PROFILE="safe"; fi
if [ -n "${PER_CARD_OVERRIDES:-}" ]; then
  $CRE exec -e PER_CARD_OVERRIDES="$PER_CARD_OVERRIDES" "$LACT_CONT" /lact.sh apply $PROFILE
else
  $CRE exec "$LACT_CONT" /lact.sh apply $PROFILE
fi
echo "OK: OC $MODE (container=$LACT_CONT; verify — lact.sh self-check)"
