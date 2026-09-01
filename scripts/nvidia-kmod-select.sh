#!/bin/bash
# nvidia-kmod-select.sh — nvidia-kmod.service ExecStartPre (Этап 18).
#
# На боте переписывает тег KMOD_IMAGE в /etc/sysconfig/nvidia-kmod
# под текущее ядро (uname -r). Значение make systemd — deploy-time
# (имя образа включая префикс DRV — источник: Makefile);
# runtime-значение определяет бот: пересчитывается только тег,
# имя берётся из файла.
# Нет образа под текущее ядро — fail-loud с командой сборки
# (юнит остаётся в Restart=on-failure-цикле, но причина в
# журнале, а не «unable to find image» podman'а).
# Атомарная запись (tmp + mv в том же каталоге), mode 0644;
# остальной контент файла сохраняется (заменяется только
# строка KMOD_IMAGE).
set -eu

FILE=${KMOD_SYSCONFIG_FILE:-/etc/sysconfig/nvidia-kmod}

die() { echo "nvidia-kmod-select: $*" >&2; exit 1; }

[ -f "$FILE" ] || die "no $FILE (make systemd?)"

img=$(grep '^KMOD_IMAGE=' "$FILE" | head -n 1 | cut -d= -f2-)
[ -n "$img" ] || die "no KMOD_IMAGE in $FILE (make systemd?)"

name=${img%%:*}
[ -n "$name" ] || die "empty image name in $FILE"

CRE=podman
if [ -e /run/.containerenv ]; then
    CRE=podman-remote
fi

kver=$(uname -r)
want="$name:$kver"

if ! "$CRE" image exists "$want"; then
    die "no image $want for kernel $kver; build it in toolbx: make kmod KVER=$kver, then: systemctl restart nvidia-kmod"
fi

if [ "$want" != "$img" ]; then
    tmp=$(mktemp "${FILE}.XXXXXX")
    chmod 644 "$tmp"
    sed "s|^KMOD_IMAGE=.*|KMOD_IMAGE=$want|" "$FILE" > "$tmp"
    mv "$tmp" "$FILE"
fi
