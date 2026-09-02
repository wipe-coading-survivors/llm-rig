#!/bin/sh
# Check: no sensitive values in tracked files (stage 19).
# Scope: all tracked files, full scope incl. docs/ (memo
# 2026-09-01-no-sensitive-docs-scope: llm-rig carries its own process
# docs from stage 24; the stage-19 ':!docs' exclusion — for the archive
# repo's historical process docs — no longer applies).
# 1) Values from local.mk (if the file exists): each VALUE must not
#    appear in any in-scope tracked file (grep -F, fixed string).
#    local.mk is untracked -> it does not catch itself;
#    local.mk.example carries only RFC 5737 (192.0.2.0/24) and the
#    example.com placeholder -> no intersection with either part.
# 2) Generic (always, incl. without local.mk — CI-compatible): private
#    IP ranges (10/8, 172.16/12, 192.168/16) with numeric boundaries
#    in in-scope tracked files. 127.0.0.1 (loopback) and 192.0.2.x
#    (TEST-NET) are out of scope on purpose. A candidate directly
#    preceded by '-' is a version fragment, not an IP (RPM NEVRA,
#    e.g. libcurand-13-3-10.4.3.29-1: the cuRAND version matches the
#    10/8 branch); real IPs in this repo's file types are never
#    glued to '-'.
# Any other hit in an in-scope tracked file = fail.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd -- "$repo_root"
pass=0
fail=0

ok() { pass=$((pass + 1)); echo "ok - $1"; }
ko() { fail=$((fail + 1)); echo "not ok - $1"; echo "  expected: $2"; echo "  actual:   $3"; }

tracked_grep() { # args: grep flags... (scope: all tracked files)
    git -C "$repo_root" ls-files -z | xargs -0 -r grep "$@" 2>/dev/null || true
}

if [ -f "$repo_root/local.mk" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in
            ''|\#*) continue ;;
            *=*) ;;
            *) continue ;;
        esac
        v=${line#*=}
        v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -n "$v" ] || continue
        hits=$(tracked_grep -Fn -- "$v")
        if [ -n "$hits" ]; then
            ko "no '$v' (local.mk) in tracked files" "no match" "$hits"
        else
            ok "no '$v' (local.mk) in tracked files"
        fi
    done < "$repo_root/local.mk"
else
    ok "local.mk absent — values check skipped (generic part only)"
fi

pat='(^|[^0-9.-])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3})([^0-9.]|$)'
hits=$(tracked_grep -nE -- "$pat")
if [ -n "$hits" ]; then
    ko "no private-IP range in tracked files" "no match" "$hits"
else
    ok "no private-IP range in tracked files"
fi

echo "# pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
