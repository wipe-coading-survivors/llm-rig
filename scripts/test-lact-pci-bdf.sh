#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lact_sh="$repo_root/resources/driver/lact/lact.sh"

if [ ! -f "$lact_sh" ]; then
    echo "not ok - lact.sh exists"
    exit 1
fi

tmp=$(mktemp -d)
trap '"$repo_root/scripts/safe-rm" --under "$(dirname "$tmp")" "$tmp" 2>/dev/null || true' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok - $1"; }
ko() { fail=$((fail + 1)); echo "not ok - $1"; echo "  expected: $2"; echo "  actual:   $3"; }

fn=$(sed -n '/^pci_sysfs_bdf()/,/^}/p' "$lact_sh")
if [ -z "$fn" ]; then
    echo "not ok - pci_sysfs_bdf extracted from lact.sh"
    echo "  expected: function body"
    echo "  actual:   not found"
    echo "# pass=0 fail=1"
    exit 1
fi
eval "$fn"

# fixture: kernel sysfs with the shortest (4-hex-digit) domain form
mkdir -p "$tmp/pci4/0000:03:00.0"
SYSFS_PCI_ROOT="$tmp/pci4"
out=$(pci_sysfs_bdf "00000000:03:00.0") && rc=0 || rc=$?
if [ "$rc" = "0" ] && [ "$out" = "0000:03:00.0" ]; then
    ok "8-digit nvidia-smi BDF -> 4-digit sysfs dir"
else
    ko "8-digit nvidia-smi BDF -> 4-digit sysfs dir" "rc=0, 0000:03:00.0" "rc=$rc, out=$out"
fi

# fixture: sysfs keeping the 8-digit form — original form found first
mkdir -p "$tmp/pci8/00000000:81:00.0"
SYSFS_PCI_ROOT="$tmp/pci8"
out=$(pci_sysfs_bdf "00000000:81:00.0") && rc=0 || rc=$?
if [ "$rc" = "0" ] && [ "$out" = "00000000:81:00.0" ]; then
    ok "original 8-digit sysfs form"
else
    ko "original 8-digit sysfs form" "rc=0, 00000000:81:00.0" "rc=$rc, out=$out"
fi

# fixture: non-zero domain conversion (00000001 -> 0001)
mkdir -p "$tmp/pci1/0001:05:00.0"
SYSFS_PCI_ROOT="$tmp/pci1"
out=$(pci_sysfs_bdf "00000001:05:00.0") && rc=0 || rc=$?
if [ "$rc" = "0" ] && [ "$out" = "0001:05:00.0" ]; then
    ok "non-zero domain conversion"
else
    ko "non-zero domain conversion" "rc=0, 0001:05:00.0" "rc=$rc, out=$out"
fi

# fixture: no matching dir at all -> fail loud (non-zero rc, empty out)
mkdir -p "$tmp/pcino"
SYSFS_PCI_ROOT="$tmp/pcino"
out=$(pci_sysfs_bdf "00000000:ff:00.0") && rc=0 || rc=$?
if [ "$rc" != "0" ] && [ -z "$out" ]; then
    ok "missing device dir fails loud"
else
    ko "missing device dir fails loud" "non-zero rc, empty out" "rc=$rc, out=$out"
fi

echo "# pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
