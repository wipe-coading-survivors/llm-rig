#!/bin/sh
set -eu

usage() {
    echo "Usage: $0 [--force] <image> <koji-base-url> <kver>" >&2
    exit 64
}

force=0
if [ "${1:-}" = "--force" ]; then
    force=1
    shift
fi

[ "$#" -eq 3 ] || usage

image=$1
base=$2
kver=$3

if [ -z "${CRE:-}" ]; then
    if [ -e /run/.containerenv ]; then
        CRE=podman-remote
    else
        CRE=podman
    fi
fi

base=${base%/}

kver_dash=${kver#*-}
ver=${kver%%-*}
[ "$kver_dash" != "$kver" ] || { echo "ERROR: cannot parse kver: $kver" >&2; exit 2; }
rel=${kver_dash%.*}
karch=${kver_dash##*.}
[ "$rel" != "$kver_dash" ] || { echo "ERROR: cannot parse kver: $kver" >&2; exit 2; }
series=${ver%.*}
[ "$series" != "$ver" ] || { echo "ERROR: cannot parse kver: $kver" >&2; exit 2; }
fc=${rel#*.}
[ "$fc" != "$rel" ] || { echo "ERROR: cannot parse kver (no fcNN in release): $kver" >&2; exit 2; }

head_meta() { # $1=url; sets m_size/m_mtime (epoch); exit 2 on failure
    headers=$(curl -fsIL --max-time 30 "$1") || exit 2
    lower=$(printf '%s\n' "$headers" | tr '[:upper:]' '[:lower:]' | tr -d '\r')
    m_size=$(printf '%s\n' "$lower" | awk '/^content-length:/ { v = $2 } END { print v }')
    lm=$(printf '%s\n' "$lower" | awk '/^last-modified:/ { v = $0; sub(/^last-modified:[ \t]*/, "", v); m = v } END { print m }')
    [ -n "$m_size" ] && [ -n "$lm" ] || exit 2
    m_mtime=$(date -u -d "$lm" +%s) || exit 2
}

fetch_listing() { # $1=url; directory entries (no trailing /) one per line; exit 2 on failure
    curl -fsS --max-time 30 "$1" |
        grep -o 'href="[^"]*/"' |
        sed 's/^href="//; s|/"$||' |
        grep -vF -x -- '..' || exit 2
}

core_url="$base/packages/kernel/$ver/$rel/$karch/kernel-core-$kver.rpm"
modcore_url="$base/packages/kernel/$ver/$rel/$karch/kernel-modules-core-$kver.rpm"
devel_url="$base/packages/kernel/$ver/$rel/$karch/kernel-devel-$kver.rpm"

head_meta "$core_url"
core_size=$m_size
core_mtime=$m_mtime
head_meta "$modcore_url"
modcore_size=$m_size
modcore_mtime=$m_mtime
head_meta "$devel_url"
devel_size=$m_size
devel_mtime=$m_mtime

resolve_headers() { # sets headers_v/headers_r; exit 2 if nothing found
    target=$ver-$rel
    best_v=
    best_r=
    versions=$(fetch_listing "$base/packages/kernel-headers/") || exit 2
    less=$(
        {
            for v in $versions; do
                case $v in
                    "$series."*) printf '%s\n' "$v" ;;
                esac
            done
            printf '%s\n' "$ver"
        } |
        sort -V |
        awk -v t="$ver" '$0 == t { exit } { print }'
    )
    cands=$less
    if printf '%s\n' "$versions" | grep -qxF -- "$ver"; then
        cands="$less
$ver"
    fi
    [ -n "$cands" ] || exit 2
    for v in $cands; do
        rlist=$(fetch_listing "$base/packages/kernel-headers/$v/") || continue
        for r in $rlist; do
            case $r in
                *."$fc")
                    if [ "$v-$r" = "$target" ]; then
                        headers_v=$v
                        headers_r=$r
                        return 0
                    fi
                    ;;
            esac
        done
        best=$(
            {
                for r in $rlist; do
                    case $r in
                        *."$fc") printf '%s\n' "$v-$r" ;;
                    esac
                done
                printf '%s\n' "$target"
            } |
            sort -V |
            awk -v t="$target" '$0 == t { exit } { print }' |
            tail -n 1
        )
        [ -n "$best" ] && { best_v=$v; best_r=${best#"$v-"}; }
    done
    [ -n "$best_v" ] || exit 2
    headers_v=$best_v
    headers_r=$best_r
}

resolve_headers
headers_url="$base/packages/kernel-headers/$headers_v/$headers_r/$karch/kernel-headers-$headers_v-$headers_r.$karch.rpm"
head_meta "$headers_url"
headers_size=$m_size
headers_mtime=$m_mtime

rebuild_vals="$core_url $core_size $core_mtime $modcore_url $modcore_size $modcore_mtime $devel_url $devel_size $devel_mtime $headers_url $headers_size $headers_mtime"

get_label() {
    key=$1
    "$CRE" inspect --format "{{if .Config.Labels}}{{index .Config.Labels \"$key\"}}{{end}}" "$image" 2>/dev/null || true
}

check_pkg() {
    [ "$(get_label "com.llm-rig/kernel.redist.$1.url")" = "$2" ] || all_match=0
    [ "$(get_label "com.llm-rig/kernel.redist.$1.size")" = "$3" ] || all_match=0
    [ "$(get_label "com.llm-rig/kernel.redist.$1.mtime")" = "$4" ] || all_match=0
}

all_match=1
check_pkg core "$core_url" "$core_size" "$core_mtime"
check_pkg modules-core "$modcore_url" "$modcore_size" "$modcore_mtime"
check_pkg devel "$devel_url" "$devel_size" "$devel_mtime"
check_pkg headers "$headers_url" "$headers_size" "$headers_mtime"

if [ "$force" -eq 0 ] && [ "$all_match" -eq 1 ]; then
    printf 'up-to-date\n'
    exit 0
fi

printf 'rebuild %s\n' "$rebuild_vals"
