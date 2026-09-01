#!/bin/bash
# Merge-generate /etc/sysconfig/<name>.
# Build keys (--build): value always from the argument (Makefile is the source
# of truth); key position in the file is kept.
# Exception (stage 18): KMOD_IMAGE (nvidia-kmod) — the Makefile value is
# deploy-time (source of the image name incl. the DRV prefix); the runtime
# tag is pinned to uname -r at boot by nvidia-kmod.service ExecStartPre
# (scripts/nvidia-kmod-select.sh).
# Default keys (--default): existing file value wins, default applied only if
# the key is absent (appended at the end).
# Unknown keys and comment lines in the file are preserved.
# Atomic write (tmp + mv in the same dir), mode 0644. Values are written
# without quotes (systemd: everything after '=' is the value; no re-split).
set -eu

usage() {
    echo "usage: sysconfig-gen.sh <sysconfig-dir> <name> [--build K=v]... [--default K=v]..." >&2
    exit 2
}

[ $# -ge 2 ] || usage
dir=$1
name=$2
shift 2
if [[ ! $name =~ ^[A-Za-z0-9_-]+$ ]]; then usage; fi
[ -d "$dir" ] || { echo "error: sysconfig dir not found: $dir" >&2; exit 1; }

build_kv=()
default_kv=()
while [ $# -gt 0 ]; do
    case $1 in
        --build)   [ $# -ge 2 ] || usage; build_kv+=("$2");   shift 2 ;;
        --default) [ $# -ge 2 ] || usage; default_kv+=("$2"); shift 2 ;;
        *) usage ;;
    esac
done
[ ${#build_kv[@]} -gt 0 ] || usage

declare -A build_val=() default_val=() seen=()
for kv in "${build_kv[@]}"; do
    case $kv in *=*) ;; *) usage ;; esac
    build_val[${kv%%=*}]=${kv#*=}
done
for kv in "${default_kv[@]}"; do
    case $kv in *=*) ;; *) usage ;; esac
    default_val[${kv%%=*}]=${kv#*=}
done

target="$dir/$name"
tmp=$(mktemp "$dir/.sysconfig-gen.XXXXXX")
chmod 644 "$tmp"
trap 'rm -f "$tmp"' EXIT

if [ -f "$target" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            k=${BASH_REMATCH[1]}
            if [ -n "${build_val[$k]+x}" ]; then
                printf '%s=%s\n' "$k" "${build_val[$k]}" >> "$tmp"
                seen[$k]=1
            else
                printf '%s\n' "$line" >> "$tmp"
                if [ -n "${default_val[$k]+x}" ]; then seen[$k]=1; fi
            fi
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$target"
    for kv in "${build_kv[@]}" "${default_kv[@]}"; do
        k=${kv%%=*}; v=${kv#*=}
        if [ -z "${seen[$k]+x}" ]; then
            printf '%s=%s\n' "$k" "$v" >> "$tmp"
        fi
    done
else
    for kv in "${build_kv[@]}" "${default_kv[@]}"; do
        printf '%s\n' "$kv" >> "$tmp"
    done
fi

mv "$tmp" "$target"
