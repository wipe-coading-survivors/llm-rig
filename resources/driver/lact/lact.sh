#!/bin/bash
# LACT wrapper: apply OC profile / monitor. Headless, no Xorg/Wayland.
# Values = current prod OC (report 2026-08-24): SM 0 / mem +1000 / PL 140W.
# Profiles (spec stage 16 stage 1): Default (top-level oc) / safe / idle /
# locked — per-profile params via SAFE_/IDLE_/LOCKED_ env (emit_gpu_blocks).
# mem_clock_offsets — NVML transfer-rate-домен (0.5 MHz на единицу):
# прод-env MEM_CLOCK_OFFSET=1000 (MHz памяти) → 2000 в конфиге (конверсия
# ×2 — та же, что в set-card-properties.sh; верифицировано: 2000 →
# clocks.max.memory 8501 — отчёт §5).
# gpu_clock_offsets — MHz как есть (без ×2), только Default-профиль:
# сдвигает рабочую точку кривой DVFS во всех pstates (grid-snapping:
# +50 → потолок 2145, не 2150); отрицательный сдвигает и idle, и load
# (1800-профиль: load 1612–1702), но display clocks.max.sm остаётся
# номинальным 2100 (verified 2026-08-27, offset-suite, отчёт
# docs/superpowers/reports/2026-08-27-lact-profiles-stage1-live-window.md).
set -euo pipefail
set -x


# значения — с override из env (стиль set-card-properties.sh: ${VAR:-default});
# env контейнера наследует -e юнита — podman exec видит sysconfig-значения
# (проверено 28.08: printenv и apply через exec), дефолты — только фоллбек
PWR_LIMIT=${PWR_LIMIT:-140}
# core clock offset, MHz as-is (signed; Default-профиль, gpu_clock_offsets)
CORE_CLOCK_OFFSET=${CORE_CLOCK_OFFSET:-0}
MEM_CLOCK_OFFSET=${MEM_CLOCK_OFFSET:-1000}
# PowerMizer mode (v0.10.0, top-level в блоке GPU; варианты как есть —
# отчёт §6): PreferMaximumPerformance — driver тянет к max perf в
# thermal-пределах; low-risk, комплементарен offsets
POWER_MIZER_MODE=${POWER_MIZER_MODE:-PreferMaximumPerformance}
FAN_MODE=${FAN_MODE:-curve}
# FAN_CURVE/FAN_STATIC — доли 0..=1 (единицы fan_control_settings v0.10.0:
# 0.3/0.4/0.65/0.8 → fan 30–42 % при 46–61 °C — отчёт §3.1/§4.1)
FAN_CURVE=${FAN_CURVE:-"45:0.30 65:0.40 70:0.65 75:0.80"}
FAN_STATIC=${FAN_STATIC:-0.30}
# serde-обязательные поля fan_control_settings (отчёт §3.1/§4.1);
# temperature_key на NVIDIA не используется (читается NVML-датчик Gpu)
FAN_TEMPERATURE_KEY=${FAN_TEMPERATURE_KEY:-edge}
FAN_INTERVAL_MS=${FAN_INTERVAL_MS:-500}
# per-profile params (spec stage 16 stage 1 §2; defaults = prod values)
# safe — thermal protection: PL + static fan + PM Auto (not max-perf)
SAFE_PL=${SAFE_PL:-120}
SAFE_FAN_STATIC=${SAFE_FAN_STATIC:-0.60}
SAFE_PM_MODE=${SAFE_PM_MODE:-Auto}
# idle — driver min PL (live), fan off (driver auto -> 0 % on cold)
IDLE_PL=${IDLE_PL:-100}
IDLE_PM_MODE=${IDLE_PM_MODE:-Auto}
# idle — лок часов памяти: драйвер не снижает memory clocks в idle при
# присутствии потребителя/занятой VRAM (владелец, 27.08); 405 = ближайшее
# к 400 (live 28.08: все 5 карт, вкл. LHR, P8, парк ~88 W); 0 -> без лока
# (fallback-паттерн, как LOCKED_MEM_CLOCK)
IDLE_MEM_CLOCK=${IDLE_MEM_CLOCK:-405}
# locked — deterministic bench profile: min=max locks hold at any load
# and in idle; LOCKED_MEM_CLOCK=0 -> no mem lock (fallback, spec §2);
# LOCKED_MEM_OFFSET — config domain (no x2), 0 -> no offsets block
LOCKED_CORE_CLOCK=${LOCKED_CORE_CLOCK:-2000}
LOCKED_MEM_CLOCK=${LOCKED_MEM_CLOCK:-8500}
LOCKED_MEM_OFFSET=${LOCKED_MEM_OFFSET:-2000}
LOCKED_PL=${LOCKED_PL:-140}
LOCKED_PM_MODE=${LOCKED_PM_MODE:-PreferMaximumPerformance}
# self-check bounded retry (spec stage 16 stage 1 §9): driver clock
# propagation lags the config hot-reload (live 28.08: 7301/8301 transient
# settles <10 s) - an immediate single check is unreliable
SELF_CHECK_RETRIES=${SELF_CHECK_RETRIES:-10}
SELF_CHECK_SLEEP=${SELF_CHECK_SLEEP:-2}
# per-card overrides, keyed by `lact cli list` id
# (format: "id|field=value field=value", entries separated by ';';
#  fields: power_cap (W, Default), mem_clock_offset (Default, prod-env
#  domain, x2 applied), core_clock_offset (MHz, Default, as-is, signed),
#  safe_power_cap (W), idle_power_cap (W),
#  locked_power_cap (W), locked_core_clock (MHz), locked_mem_clock (MHz),
#  locked_mem_offset (config domain, no x2); unfilled field -> profile
#  default; empty = none)
PER_CARD_OVERRIDES="${PER_CARD_OVERRIDES:-}"

LACT_BIN=${LACT_BIN:-/usr/bin/lact}
DAEMON_LOG=${DAEMON_LOG:-/var/log/lact/daemon.log}
DRM_SYSFS_DIR=/run/lact/drm-sysfs
SYSFS_PCI_ROOT=${SYSFS_PCI_ROOT:-/sys/bus/pci/devices}
CONFIG_FILE=${CONFIG_FILE:-/etc/lact/config.yaml}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# ---------- config generation (pure: no nvidia-smi/lact calls) ----------

# gpu_override_field ID FIELD -> value (empty when ID has no override)
gpu_override_field() {
    local id=$1 field=$2 entry oid spec
    for entry in ${PER_CARD_OVERRIDES//;/ }; do
        oid=${entry%%|*}
        if [ "$oid" != "$id" ]; then
            continue
        fi
        for spec in ${entry#*|}; do
            if [ "${spec%%=*}" = "$field" ]; then
                echo "${spec#*=}"
                return 0
            fi
        done
    done
    return 0
}

# validate_overrides — fail-loud on malformed entries/fields
validate_overrides() {
    local entry oid spec
    for entry in ${PER_CARD_OVERRIDES//;/ }; do
        case "$entry" in
            *"|"*) ;;
            *) die "override: entry without '|': $entry" ;;
        esac
        oid=${entry%%|*}
        if [ -z "$oid" ]; then
            die "override: empty id in entry: $entry"
        fi
        for spec in ${entry#*|}; do
            case "$spec" in
                *"="*) ;;
                *) die "override: field without '=' in entry: $entry" ;;
            esac
            case "${spec%%=*}" in
                power_cap|mem_clock_offset|core_clock_offset|safe_power_cap|idle_power_cap|locked_power_cap|locked_core_clock|locked_mem_clock|locked_mem_offset) ;;
                *) die "override: unknown field '${spec%%=*}' in entry: $entry" ;;
            esac
        done
    done
    return 0
}

# emit_gpu_blocks GPU_INDENT PROFILE PSTATES IDS — per-profile parameter
# set (spec stage 16 stage 1 §2):
#   default: PL PWR_LIMIT, fan FAN_MODE (FAN_CURVE/FAN_STATIC), PM
#            POWER_MIZER_MODE, offsets MEM_CLOCK_OFFSET x2, core offset
#            CORE_CLOCK_OFFSET (MHz as-is; 0 -> no gpu_clock_offsets)
#   safe:    PL SAFE_PL, static fan SAFE_FAN_STATIC, PM SAFE_PM_MODE
#   idle:    PL IDLE_PL, fan off (driver auto), PM IDLE_PM_MODE, mem lock
#            IDLE_MEM_CLOCK (min=max; 0 -> no mem lock, fallback spec §9)
#   locked:  PL LOCKED_PL, fan as default, PM LOCKED_PM_MODE, core lock
#            LOCKED_CORE_CLOCK (min=max), mem lock LOCKED_MEM_CLOCK
#            (min=max; 0 -> no mem lock, fallback spec §2), offsets
#            LOCKED_MEM_OFFSET (config domain; 0 -> no block)
emit_gpu_blocks() {
    local g=$1 profile=$2 pstates=$3 ids=$4
    local k="$g  " f="$g    " s="$g      " c="$g        "
    local id pair t v pc_power pc_offset pc_core pc_mem pc_coreoff p
    local power_cap pm fan_mode static_val mem_offset core_offset core_lock mem_lock pl_field
    case "$profile" in
        default)
            power_cap=$PWR_LIMIT
            fan_mode=$FAN_MODE
            static_val=$FAN_STATIC
            pm=$POWER_MIZER_MODE
            mem_offset=$(( MEM_CLOCK_OFFSET * 2 ))
            core_offset=$CORE_CLOCK_OFFSET
            core_lock=
            mem_lock=
            pl_field=power_cap
            ;;
        safe)
            power_cap=$SAFE_PL
            fan_mode=static
            static_val=$SAFE_FAN_STATIC
            pm=$SAFE_PM_MODE
            mem_offset=0
            core_offset=0
            core_lock=
            mem_lock=
            pl_field=safe_power_cap
            ;;
        idle)
            power_cap=$IDLE_PL
            fan_mode=off
            static_val=
            pm=$IDLE_PM_MODE
            mem_offset=0
            core_offset=0
            core_lock=
            mem_lock=$IDLE_MEM_CLOCK
            pl_field=idle_power_cap
            ;;
        locked)
            power_cap=$LOCKED_PL
            fan_mode=$FAN_MODE
            static_val=$FAN_STATIC
            pm=$LOCKED_PM_MODE
            mem_offset=$LOCKED_MEM_OFFSET
            core_offset=0
            core_lock=$LOCKED_CORE_CLOCK
            mem_lock=$LOCKED_MEM_CLOCK
            pl_field=locked_power_cap
            ;;
        *)
            die "emit_gpu_blocks: unknown profile '$profile'"
            ;;
    esac
    echo "${g}gpus:"
    for id in $ids; do
        # per-card working vars: re-init from profile defaults every iteration
        # (a card without override must not inherit the previous card's value)
        pc_power=$power_cap
        pc_offset=$mem_offset
        pc_core=$core_lock
        pc_mem=$mem_lock
        pc_coreoff=$core_offset
        echo "${k}\"$id\":"
        if [ "$fan_mode" = "off" ]; then
            echo "${f}fan_control_enabled: false"
        else
            echo "${f}fan_control_enabled: true"
            echo "${f}fan_control_settings:"
            if [ "$fan_mode" = "curve" ]; then
                echo "${s}mode: curve"
            else
                echo "${s}mode: static"
                echo "${s}static_speed: $static_val"
            fi
            # curve — serde-required even in mode: static (live 27.08: daemon
            # "missing field 'curve'" on the safe block); inert in static
            echo "${s}curve:"
            for pair in $FAN_CURVE; do
                t=${pair%%:*}
                v=${pair##*:}
                echo "${c}$t: $v"
            done
            echo "${s}temperature_key: $FAN_TEMPERATURE_KEY"
            echo "${s}interval_ms: $FAN_INTERVAL_MS"
        fi
        v=$(gpu_override_field "$id" "$pl_field")
        if [ -n "$v" ]; then
            pc_power=$v
        fi
        echo "${f}power_cap: $pc_power"
        echo "${f}power_mizer_mode: $pm"
        if [ -n "$pc_core" ]; then
            v=$(gpu_override_field "$id" locked_core_clock)
            if [ -n "$v" ]; then
                pc_core=$v
            fi
            echo "${f}min_core_clock: $pc_core"
            echo "${f}max_core_clock: $pc_core"
        fi
        if [ -n "$pc_mem" ] && [ "$pc_mem" != "0" ]; then
            v=$(gpu_override_field "$id" locked_mem_clock)
            if [ -n "$v" ]; then
                pc_mem=$v
            fi
            echo "${f}min_memory_clock: $pc_mem"
            echo "${f}max_memory_clock: $pc_mem"
        fi
        if [ "$profile" = "default" ]; then
            v=$(gpu_override_field "$id" mem_clock_offset)
            if [ -n "$v" ]; then
                case "$v" in
                    ''|*[!0-9]*) die "override: mem_clock_offset must be numeric: $v" ;;
                esac
                pc_offset=$(( v * 2 ))
            fi
        elif [ "$profile" = "locked" ]; then
            v=$(gpu_override_field "$id" locked_mem_offset)
            if [ -n "$v" ]; then
                pc_offset=$v
            fi
        fi
        if [ "$pc_offset" != "0" ]; then
            echo "${f}mem_clock_offsets:"
            for p in $pstates; do
                echo "${s}$p: $pc_offset"
            done
        fi
        if [ "$profile" = "default" ]; then
            v=$(gpu_override_field "$id" core_clock_offset)
            if [ -n "$v" ]; then
                case "${v#-}" in
                    ''|*[!0-9]*) die "override: core_clock_offset must be signed numeric: $v" ;;
                esac
                pc_coreoff=$v
            fi
        fi
        if [ "$pc_coreoff" != "0" ]; then
            echo "${f}gpu_clock_offsets:"
            for p in $pstates; do
                echo "${s}$p: $pc_coreoff"
            done
        fi
    done
}

# config_header -> top-level fields of the v6 schema (report §3.1): the
# `daemon` block has no serde default — a config without it is rejected at
# parse with "missing field `daemon`" (verified: first live window, config.rs:31)
config_header() {
    echo "version: 6"
    echo "daemon:"
    echo "  log_level: info"
    echo "  disable_clocks_cleanup: false"
    echo "apply_settings_timer: 5"
}

# render_config PSTATES IDS -> config YAML v6 on stdout
render_config() {
    local pstates=$1 ids=$2
    if [ -z "$pstates" ]; then
        die "render: empty pstates"
    fi
    if [ -z "$ids" ]; then
        die "render: empty gpu ids"
    fi
    validate_overrides
    config_header
    echo "current_profile: null"
    echo "auto_switch_profiles: false"
    emit_gpu_blocks "" default "$pstates" "$ids"
    echo "profiles:"
    echo "  safe:"
    emit_gpu_blocks "    " safe "$pstates" "$ids"
    echo "  idle:"
    emit_gpu_blocks "    " idle "$pstates" "$ids"
    echo "  locked:"
    emit_gpu_blocks "    " locked "$pstates" "$ids"
}

# ---------- daemon/apply/monitor (live verification — Task 4) ----------

# lact_ids -> space-separated GPU ids from `lact cli list` (field 2)
lact_ids() {
    "$LACT_BIN" cli list | awk '{print $2}' | paste -sd' '
}

# pstates_from_snapshot SNAPSHOT_TAR_GZ -> "0 2 3 5 8" (mem_offsets keys)
pstates_from_snapshot() {
    local snap=$1
    tar -xOf "$snap" info.json | awk '
        /"mem_offsets"[[:space:]]*:[[:space:]]*\{/ {
            inmem = 1
            match($0, /[^ ]/)
            ind = RSTART - 1
            next
        }
        inmem {
            match($0, /[^ ]/)
            if (RSTART - 1 <= ind) {
                inmem = 0
                next
            }
            if (match($0, /^[ ]*"[0-9]+":/)) {
                s = $0
                gsub(/[^0-9]/, "", s)
                print s
            }
        }
    ' | sort -n | uniq | paste -sd' '
}

# snapshot_pstates -> run `lact cli snapshot`, extract pstates
snapshot_pstates() {
    local out snap
    out=$("$LACT_BIN" cli snapshot)
    snap=$(printf '%s\n' "$out" | sed -n 's/^Generated debug snapshot in //p')
    if [ -z "$snap" ]; then
        die "snapshot: path not found in cli output: $out"
    fi
    pstates_from_snapshot "$snap"
}

# wait_reload — after a $CONFIG_FILE write: wait for "configuration reloaded"
# in the NEW daemon-log lines (R6 guard: failed reload + profile set resets
# GPUs via cleanup without apply — report §4.1)
wait_reload() {
    local before new i
    before=$(wc -l < "$DAEMON_LOG" 2>/dev/null || echo 0)
    for i in $(seq 1 60); do
        new=$(tail -n +"$(( before + 1 ))" "$DAEMON_LOG" 2>/dev/null || true)
        if printf '%s\n' "$new" | grep -q 'configuration reloaded'; then
            echo "wait_reload: ok"
            return 0
        fi
        sleep 0.5
    done
    tail -n 50 "$DAEMON_LOG" >&2 || true
    die "wait_reload: no 'configuration reloaded' in daemon log (parse error?)"
}

# self_check PROFILE — card-0 verification (spec stage 16 stage 1 §3):
#   Default: clocks.max.memory 7501 + MEM_CLOCK_OFFSET (hard; D3 stage 10:
#            был хардкод 8501 = база + дефолт offset 1000, ломал apply при
#            prod MEM_CLOCK_OFFSET=1100 -> 8601), power.limit PWR_LIMIT (hard)
#   safe:    clocks.max.memory 7501 (hard), power.limit SAFE_PL (hard),
#            fan speed informational (driver % not guaranteed precise)
#   idle:    clocks.max.memory 7501 (hard), power.limit IDLE_PL (hard),
#            fan speed informational, clocks.current.memory in
#            [IDLE_MEM_CLOCK-10, IDLE_MEM_CLOCK+10] (hard, when
#            IDLE_MEM_CLOCK != 0)
#   locked:  clocks.current.sm in [LOCKED_CORE_CLOCK-100, LOCKED_CORE_CLOCK]
#            (hard), clocks.current.memory in [LOCKED_MEM_CLOCK-100,
#            7501 + LOCKED_MEM_OFFSET/2] (hard; window: transients/
#            throttle-reasons), power.limit LOCKED_PL (hard)
self_check() {
    local profile=$1 maxmem pl sm mem mem_lo mem_hi fan pl_exp out mem_exp
    case "$profile" in
        Default)
            pl_exp=$PWR_LIMIT
            mem_exp=$(( 7501 + MEM_CLOCK_OFFSET ))
            maxmem=$(nvidia-smi -i 0 --query-gpu=clocks.max.memory --format=csv,noheader | grep -o '[0-9]*' | head -1)
            if [ "$maxmem" != "$mem_exp" ]; then
                die "self-check: clocks.max.memory=$maxmem (expect $mem_exp, profile=Default)"
            fi
            out="max.mem=$maxmem MHz"
            ;;
        safe)
            pl_exp=$SAFE_PL
            maxmem=$(nvidia-smi -i 0 --query-gpu=clocks.max.memory --format=csv,noheader | grep -o '[0-9]*' | head -1)
            if [ "$maxmem" != "7501" ]; then
                die "self-check: clocks.max.memory=$maxmem (expect 7501, profile=safe)"
            fi
            fan=$(nvidia-smi -i 0 --query-gpu=fan.speed --format=csv,noheader,nounits)
            out="max.mem=$maxmem MHz, fan.info=${fan}%"
            ;;
        idle)
            pl_exp=$IDLE_PL
            maxmem=$(nvidia-smi -i 0 --query-gpu=clocks.max.memory --format=csv,noheader | grep -o '[0-9]*' | head -1)
            if [ "$maxmem" != "7501" ]; then
                die "self-check: clocks.max.memory=$maxmem (expect 7501, profile=idle)"
            fi
            fan=$(nvidia-smi -i 0 --query-gpu=fan.speed --format=csv,noheader,nounits)
            out="max.mem=$maxmem MHz, fan.info=${fan}%"
            if [ "$IDLE_MEM_CLOCK" != "0" ]; then
                mem=$(nvidia-smi -i 0 --query-gpu=clocks.current.memory --format=csv,noheader,nounits)
                case "$mem" in
                    ''|*[!0-9]*) die "self-check: clocks.current.memory not numeric: '$mem' (profile=idle)" ;;
                esac
                if [ "$mem" -lt $((IDLE_MEM_CLOCK - 10)) ] || [ "$mem" -gt $((IDLE_MEM_CLOCK + 10)) ]; then
                    die "self-check: clocks.current.memory=$mem (expect ~$IDLE_MEM_CLOCK, profile=idle)"
                fi
                out="$out, cur.mem=$mem MHz"
            fi
            ;;
        locked)
            pl_exp=$LOCKED_PL
            sm=$(nvidia-smi -i 0 --query-gpu=clocks.current.sm --format=csv,noheader,nounits)
            mem=$(nvidia-smi -i 0 --query-gpu=clocks.current.memory --format=csv,noheader,nounits)
            case "$sm" in
                ''|*[!0-9]*) die "self-check: clocks.current.sm not numeric: '$sm' (profile=locked)" ;;
            esac
            case "$mem" in
                ''|*[!0-9]*) die "self-check: clocks.current.memory not numeric: '$mem' (profile=locked)" ;;
            esac
            if [ "$sm" -lt $(( LOCKED_CORE_CLOCK - 100 )) ] || [ "$sm" -gt "$LOCKED_CORE_CLOCK" ]; then
                die "self-check: clocks.current.sm=$sm (expect [$(( LOCKED_CORE_CLOCK - 100 ))..$LOCKED_CORE_CLOCK], profile=locked)"
            fi
            mem_lo=$(( LOCKED_MEM_CLOCK - 100 ))
            mem_hi=$(( 7501 + LOCKED_MEM_OFFSET / 2 ))
            if [ "$mem" -lt "$mem_lo" ] || [ "$mem" -gt "$mem_hi" ]; then
                die "self-check: clocks.current.memory=$mem (expect [${mem_lo}..${mem_hi}], profile=locked)"
            fi
            out="sm=$sm MHz, mem=$mem MHz"
            ;;
        *)
            die "self-check: unknown profile '$profile' (Default|safe|idle|locked)"
            ;;
    esac
    pl=$(nvidia-smi -i 0 --query-gpu=power.limit --format=csv,noheader | awk '{print $1}')
    if [ "${pl%%.*}" != "$pl_exp" ]; then
        die "self-check: power.limit=$pl W (expect ${pl_exp}.00, profile=$profile)"
    fi
    # best-effort: Power Management Mode (report §6.2 — driver 610.43.03
    # support is a hypothesis, captured in the live window)
    nvidia-smi -i 0 -q -d POWER 2>/dev/null | grep -i 'power management mode' || true
    echo "self-check: OK (profile=$profile, $out, power.limit=$pl W)"
}

cmd_apply() {
    local profile=${1:-Default} ids pstates
    case "$profile" in
        Default|default) profile=Default ;;
        safe|idle|locked) ;;
        *) die "apply: unknown profile '$profile' (Default|safe|idle|locked)" ;;
    esac
    nvidia-smi -pm 1 > /dev/null
    ids=$(lact_ids) || ids=""
    if [ -z "$ids" ]; then
        die "apply: no GPUs in lact cli list (daemon running?)"
    fi
    pstates=$(snapshot_pstates)
    if [ -z "$pstates" ]; then
        die "apply: no mem_offsets pstates in snapshot"
    fi
    render_config "$pstates" "$ids" > "${CONFIG_FILE}.tmp"
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    wait_reload
    "$LACT_BIN" cli profile set "$profile"
    # driver clock propagation lags the config reload (live 28.08: 7301/8301
    # transient settles <10 s) - bounded retry; the subshell isolates
    # self_check's die, last attempt output kept for the final message
    local attempt out=""
    for attempt in $(seq 1 "$SELF_CHECK_RETRIES"); do
        if out=$(self_check "$profile" 2>&1); then
            printf '%s\n' "$out"
            return 0
        fi
        [ "$attempt" -lt "$SELF_CHECK_RETRIES" ] && sleep "$SELF_CHECK_SLEEP"
    done
    die "apply: self-check did not settle after $SELF_CHECK_RETRIES attempts (profile=$profile): $out"
}

# pci_sysfs_bdf NVIDIASMI_BDF -> the $SYSFS_PCI_ROOT dir name for the BDF
# (nvidia-smi pci.bus_id prints an 8-hex-digit PCI domain, the kernel sysfs
# uses the shortest form: 00000000:03:00.0 -> 0000:03:00.0; both forms are
# tried against the real sysfs); non-zero rc + empty out when missing
pci_sysfs_bdf() {
    local bdf=$1 dom=${1%%:*} rest=${1#*:} d
    for d in "$dom" "$(printf '%04x' "$(( 16#$dom ))")"; do
        if [ -d "$SYSFS_PCI_ROOT/$d:$rest" ]; then
            printf '%s' "$d:$rest"
            return 0
        fi
    done
    return 1
}

cmd_daemon() {
    local bdfs expected real=0 ue bdf i dpid target
    bdfs=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader)
    if [ -z "$bdfs" ]; then
        die "daemon: nvidia-smi reports no GPUs"
    fi
    expected=$(printf '%s\n' "$bdfs" | wc -l)

    # drm-sysfs auto-detection (spec §11): real card nodes with DRIVER=nvidia
    for ue in /sys/class/drm/card*/device/uevent; do
        [ -r "$ue" ] || continue
        case "$(basename "$(dirname "$(dirname "$ue")")")" in
            *-* ) continue ;;
        esac
        if grep -q '^DRIVER=nvidia$' "$ue" 2>/dev/null; then
            real=$(( real + 1 ))
        fi
    done

    if [ "$real" -gt 0 ]; then
        echo "daemon: $real nvidia card node(s) in /sys/class/drm (nvidia_drm) — native enumeration"
    else
        echo "daemon: no nvidia card nodes in /sys/class/drm — building synthetic drm-sysfs"
        mkdir -p "$DRM_SYSFS_DIR"
        i=0
        for bdf in $bdfs; do
            target=$(pci_sysfs_bdf "$bdf") ||
                die "daemon: no $SYSFS_PCI_ROOT entry for BDF $bdf (PCI domain format?)"
            mkdir -p "$DRM_SYSFS_DIR/card$(( 100 + i ))"
            ln -sfn "$SYSFS_PCI_ROOT/$target" "$DRM_SYSFS_DIR/card$(( 100 + i ))/device"
            i=$(( i + 1 ))
        done
        export _LACT_DRM_SYSFS_PATH="$DRM_SYSFS_DIR"
    fi

    mkdir -p /etc/lact /var/log/lact
    # skeleton config — the daemon loads it at start (report §3.3(c)); it
    # must parse, so it carries the required daemon block (config.rs:31)
    { config_header; echo "gpus: {}"; } > "$CONFIG_FILE"

    # client shim (lact-client v0.10.0): `lact cli` does not read
    # LACT_DAEMON_SOCKET_PATH — it checks the hardcoded /run/lactd.sock;
    # with a custom socket path, point the client at the shared socket
    if [ -n "${LACT_DAEMON_SOCKET_PATH:-}" ]; then
        ln -sfn "${LACT_DAEMON_SOCKET_PATH}" /run/lactd.sock
    fi

    # baseline like wait_reload: only NEW log lines count (a
    # `podman restart` of a long-lived container keeps the old log, where a
    # stale "initialized N GPUs" line would satisfy the gate)
    local before
    before=$(wc -l < "$DAEMON_LOG" 2>/dev/null || echo 0)

    "$LACT_BIN" daemon >> "$DAEMON_LOG" 2>&1 &
    dpid=$!
    trap 'kill -TERM "$dpid" 2>/dev/null || true; wait "$dpid"; exit 0' TERM INT

    i=0
    while [ "$i" -lt 120 ]; do
        if ! kill -0 "$dpid" 2>/dev/null; then
            tail -n 50 "$DAEMON_LOG" >&2 || true
            die "daemon: process exited during start"
        fi
        if tail -n +"$(( before + 1 ))" "$DAEMON_LOG" 2>/dev/null | grep -q "initialized $expected GPUs"; then
            break
        fi
        sleep 1
        i=$(( i + 1 ))
    done
    if ! tail -n +"$(( before + 1 ))" "$DAEMON_LOG" 2>/dev/null | grep -q "initialized $expected GPUs"; then
        tail -n 50 "$DAEMON_LOG" >&2 || true
        die "daemon: 'initialized $expected GPUs' not in new daemon log"
    fi

    # entrypoint gate (spec §11): the daemon must see ALL cards before render
    local listed
    listed=$("$LACT_BIN" cli list | wc -l)
    if [ "$listed" != "$expected" ]; then
        die "daemon gate: lact cli list shows $listed GPUs, expected $expected"
    fi

    local ids pstates
    ids=$(lact_ids)
    pstates=$(snapshot_pstates)
    if [ -z "$pstates" ]; then
        die "daemon: no mem_offsets pstates in snapshot"
    fi
    echo "daemon: ids: $ids"
    echo "daemon: pstates: $pstates"

    render_config "$pstates" "$ids" > "${CONFIG_FILE}.tmp"
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    wait_reload

    echo "daemon: config applied (hot-reload) — running (log: $DAEMON_LOG)"
    wait "$dpid"
}

cmd_monitor() {
    local ids
    ids=$(lact_ids) || ids=""
    if [ -z "$ids" ]; then
        die "monitor: no GPUs in lact cli list (daemon running?)"
    fi
    printf '%-3s %-34s %-24s %-5s %-6s %-8s %-5s %-9s %-6s %-9s %-6s %-8s %-11s %-6s %-6s\n' \
        IDX GPU_ID NAME T.C HOT.C VRAMC.C FAN.% FANMODE RPM SM.MHZ MEM.MHZ MEMMAX.MHZ W/LIMITW VRAMMiB PM
    printf '%s\n' "----------------------------------------------------------------------------------------------------------------------------------------------------------------"
    local smi_rows
    smi_rows=$(nvidia-smi --query-gpu=name,temperature.gpu,fan.speed,clocks.current.sm,clocks.current.memory,clocks.max.memory,power.draw,power.limit,memory.used,memory.total,persistence_mode --format=csv,noheader,nounits)
    local i=0 id row name temp fan sm mem memmax pw plist vram pm stats tline hotspot vramtemp fanmode rpm
    local max_t=0 max_h=0 sum_w=0 min_mm=999999
    for id in $ids; do
        i=$(( i + 1 ))
        row=$(printf '%s\n' "$smi_rows" | sed -n "${i}p")
        name=$(printf '%s' "$row" | awk -F',' '{print $1}')
        temp=$(printf '%s' "$row" | awk -F',' '{gsub(/ /, "", $2); print $2}')
        fan=$(printf '%s' "$row" | awk -F',' '{gsub(/ /, "", $3); print $3}')
        sm=$(printf '%s' "$row" | awk -F',' '{gsub(/ /, "", $4); print $4}')
        mem=$(printf '%s' "$row" | awk -F',' '{gsub(/ /, "", $5); print $5}')
        memmax=$(printf '%s' "$row" | awk -F',' '{gsub(/ /, "", $6); print $6}')
        pw=$(printf '%s' "$row" | awk -F',' '{gsub(/ /, "", $7); print $7}')
        plist=$(printf '%s' "$row" | awk -F',' '{gsub(/ /, "", $8); print $8}')
        vram=$(printf '%s' "$row" | awk -F',' '{gsub(/ /, "", $9); gsub(/ /, "", $10); print $9 "/" $10}')
        pm=$(printf '%s' "$row" | awk -F',' '{gsub(/ /, "", $11); print $11}')
        stats=$("$LACT_BIN" cli -g "$id" stats 2>/dev/null || true)
        tline=$(printf '%s\n' "$stats" | sed -n 's/^Temperatures:.*GPU Hotspot: \([0-9]*\)°C, VRAM: \([0-9]*\)°C$/HOT \1 VRAM \2/p')
        hotspot=$(printf '%s' "$tline" | grep -o 'HOT [0-9]*' | grep -o '[0-9]*' || true)
        vramtemp=$(printf '%s' "$tline" | grep -o 'VRAM [0-9]*' | grep -o '[0-9]*' || true)
        fanmode=$(printf '%s\n' "$stats" | sed -n 's/^Fan Control Mode: //p')
        rpm=$(printf '%s\n' "$stats" | sed -n 's/^Fan Speed: [0-9][0-9]*% (\([0-9][0-9]*\) RPM).*/\1/p')
        [ -n "$hotspot" ] || hotspot="-"
        [ -n "$vramtemp" ] || vramtemp="-"
        [ -n "$fanmode" ] || fanmode="-"
        [ -n "$rpm" ] || rpm="-"
        printf '%-3s %-34s %-24s %-5s %-6s %-8s %-5s %-9s %-6s %-9s %-6s %-8s %-11s %-6s %-6s\n' \
            "$(( i - 1 ))" "$id" "$name" "$temp" "$hotspot" "$vramtemp" "$fan" "$fanmode" "$rpm" "$sm" "$mem" "$memmax" "$pw/$plist" "$vram" "$pm"
        if [ "$temp" -gt "$max_t" ] 2>/dev/null; then max_t=$temp; fi
        if [ "$hotspot" != "-" ] && [ "$hotspot" -gt "$max_h" ] 2>/dev/null; then max_h=$hotspot; fi
        sum_w=$(awk -v a="$sum_w" -v b="$pw" 'BEGIN { printf "%.1f", a + b }')
        if [ "$memmax" -lt "$min_mm" ] 2>/dev/null; then min_mm=$memmax; fi
    done
    printf 'SUMMARY: %s GPUs, max temp %s C, max hotspot %s C, total power %s W, min mem-max %s MHz\n' \
        "$i" "$max_t" "$max_h" "$sum_w" "$min_mm"
}

usage() {
    cat >&2 <<'EOF'
usage: lact.sh <command>
  daemon             container entrypoint (drm-sysfs, skeleton config,
                     start /usr/bin/lact daemon, render config from live
                     IDs via hot-reload, wait on the daemon)
  apply <profile>    re-apply the profile (Default|safe|idle|locked):
                     render config -> hot-reload -> profile set ->
                     self-check (bounded retry: driver settle after
                     hot-reload)
  monitor            one-shot per-GPU table (nvidia-smi + lact cli stats)
  render PSTATES IDS internal/test: print config YAML to stdout
EOF
    exit 64
}

[ "$#" -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
    daemon)
        cmd_daemon "$@"
        ;;
    apply)
        cmd_apply "${1:-Default}"
        ;;
    monitor)
        cmd_monitor
        ;;
    render)
        [ "$#" -eq 2 ] || usage
        render_config "$1" "$2"
        ;;
    *)
        usage
        ;;
esac
