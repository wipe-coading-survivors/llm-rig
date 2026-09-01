#!/bin/sh
set -eu

usage() {
    echo "Usage: $0 [--force] <url> <image> <label-prefix>" >&2
    exit 64
}

force=0
if [ "${1:-}" = "--force" ]; then
    force=1
    shift
fi

[ "$#" -eq 3 ] || usage

url=$1
image=$2
prefix=$3

if [ -z "${CRE:-}" ]; then
    if [ -e /run/.containerenv ]; then
        CRE=podman-remote
    else
        CRE=podman
    fi
fi

headers=$(curl -fsIL --max-time 30 "$url") || exit 2

lower_headers=$(printf '%s\n' "$headers" | tr '[:upper:]' '[:lower:]' | tr -d '\r')
size=$(printf '%s\n' "$lower_headers" | awk '/^content-length:/ { v = $2 } END { print v }')
etag=$(printf '%s\n' "$lower_headers" | awk '/^etag:/ { v = $2 } END { print v }')

get_label() {
    key=$1
    "$CRE" inspect --format "{{if .Config.Labels}}{{index .Config.Labels \"$key\"}}{{end}}" "$image" 2>/dev/null || true
}

label_url=$(get_label "$prefix.url")
label_size=$(get_label "$prefix.size")
label_etag=$(get_label "$prefix.etag")

if [ "$force" -eq 1 ]; then
    printf 'rebuild %s %s\n' "$size" "$etag"
    exit 0
fi

if [ "$label_url" = "$url" ] && [ "$label_size" = "$size" ] && [ "$label_etag" = "$etag" ]; then
    printf 'up-to-date\n'
else
    printf 'rebuild %s %s\n' "$size" "$etag"
fi
