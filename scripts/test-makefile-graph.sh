#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
server_pid=
local_mk_backup=
local_mk_existed=0
log=$tmp/build.log
trap '
    if [ -n "${local_mk_backup:-}" ] && [ -f "$repo_root/local.mk" ]; then
        if [ "${local_mk_existed:-0}" = 1 ]; then
            cp "$local_mk_backup" "$repo_root/local.mk"
        else
            rm -f "$repo_root/local.mk"
        fi
    fi
    if [ -n "${server_pid:-}" ]; then kill "$server_pid" 2>/dev/null || true; fi
    "$repo_root/scripts/safe-rm" --under "$(dirname "$tmp")" "$tmp" 2>/dev/null || true
' EXIT INT TERM

# --- local HTTP server for redist URLs (size/etag for redist-check.sh) ---
port=18767
drv_url="http://127.0.0.1:$port/driver.run"
printf 'test-driver\n' > "$tmp/driver.run"
lact_url="http://127.0.0.1:$port/lact.rpm"
printf 'test-lact\n' > "$tmp/lact.rpm"

cat > "$tmp/server.py" <<'PY'
import functools
import http.server
import sys

port = int(sys.argv[1])
directory = sys.argv[2]

class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("ETag", '"test-etag"')
        super().end_headers()

    def log_message(self, *args):
        pass

http.server.ThreadingHTTPServer(
    ("127.0.0.1", port),
    functools.partial(Handler, directory=directory),
).serve_forever()
PY

python3 "$tmp/server.py" "$port" "$tmp" &
server_pid=$!

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if curl -fsS "$drv_url" > /dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
curl -fsS "$drv_url" > /dev/null
curl -fsS "$lact_url" > /dev/null

# --- fake koji layout (kernel + kernel-headers, for kernel-redist tests) ---
koji_url="http://127.0.0.1:$port/koji"
repo_base_url="http://127.0.0.1:$port/repo-base"
kver_test=7.1.4-200.fc44.x86_64
kmkdir=$tmp/koji/packages/kernel/7.1.4/200.fc44/x86_64
mkdir -p "$kmkdir"
printf 'core\n' > "$kmkdir/kernel-core-$kver_test.rpm"
printf 'modcore\n' > "$kmkdir/kernel-modules-core-$kver_test.rpm"
printf 'devel\n' > "$kmkdir/kernel-devel-$kver_test.rpm"
# second kernel version: present in kernel/, but NO kernel-headers series (exit-2 path)
kmkdir2=$tmp/koji/packages/kernel/8.0.0/100.fc44/x86_64
mkdir -p "$kmkdir2"
printf 'core\n' > "$kmkdir2/kernel-core-8.0.0-100.fc44.x86_64.rpm"
printf 'modcore\n' > "$kmkdir2/kernel-modules-core-8.0.0-100.fc44.x86_64.rpm"
printf 'devel\n' > "$kmkdir2/kernel-devel-8.0.0-100.fc44.x86_64.rpm"
for hr in 7.1.3/100.fc43 7.1.3/200.fc44 7.1.3/200.fc45 7.1.5/200.fc44; do
    mkdir -p "$tmp/koji/packages/kernel-headers/$hr/x86_64"
done
printf 'h43\n' > "$tmp/koji/packages/kernel-headers/7.1.3/100.fc43/x86_64/kernel-headers-7.1.3-100.fc43.x86_64.rpm"
printf 'h44\n' > "$tmp/koji/packages/kernel-headers/7.1.3/200.fc44/x86_64/kernel-headers-7.1.3-200.fc44.x86_64.rpm"
printf 'h45\n' > "$tmp/koji/packages/kernel-headers/7.1.3/200.fc45/x86_64/kernel-headers-7.1.3-200.fc45.x86_64.rpm"
printf 'hnew\n' > "$tmp/koji/packages/kernel-headers/7.1.5/200.fc44/x86_64/kernel-headers-7.1.5-200.fc44.x86_64.rpm"

# --- fake git repos (offline) ---
make_fake_repo() {
    dir=$1
    git init -q "$dir"
    git -C "$dir" config user.email test@test
    git -C "$dir" config user.name test
    printf 'x\n' > "$dir/README"
    git -C "$dir" add README
    git -C "$dir" commit -qm init
    git -C "$dir" branch -M master
}

make_fake_repo "$tmp/llama-repo"
git -C "$tmp/llama-repo" branch glm5next
git -C "$tmp/llama-repo" branch glm5/flash
make_fake_repo "$tmp/ogkm-repo"
git -C "$tmp/ogkm-repo" branch test

# working clones: recipes take the git pull/checkout path (offline)
git clone -q "$tmp/llama-repo" "$tmp/llama-cpp"
git clone -q "$tmp/ogkm-repo" "$tmp/ogkm"
git -C "$tmp/ogkm" checkout -q test
make_fake_repo "$tmp/nccl-repo"
git -C "$tmp/nccl-repo" tag test-nccl
# working clone on the tag: recipe takes the fetch/checkout path (offline)
git clone -q "$tmp/nccl-repo" "$tmp/nccl"
git -C "$tmp/nccl" checkout -q test-nccl

# --- fake CRE: log build calls; inspect --format "{{.Id}}" -> deterministic fake ID ---
cat > "$tmp/cre" <<'SH'
#!/bin/sh
log=${FAKE_LOG:?}
case "${1:-}" in
    inspect)
        if [ "$3" = "{{.Id}}" ]; then
            echo "sha256:fake-$(printf '%s' "$4" | tr ':' '-')"
            exit 0
        fi
        exit 1
        ;;
    image)
        exit 1
        ;;
    build)
        echo "build $*" >> "$log"
        ;;
esac
exit 0
SH
chmod +x "$tmp/cre"

# fake CRE with labels for the up-to-date path: key parsed from --format
# (arg layout: inspect --format <fmt> <image> -> fmt is $3)
cat > "$tmp/cre-labeled" <<'SH'
#!/bin/sh
case "${1:-}" in
    inspect)
        fmt=$3
        key=${fmt#*\"}
        key=${key%%\"*}
        [ -n "${FAKE_LABELS:-}" ] || exit 0
        sed -n "s@^${key}=@@p" "$FAKE_LABELS"
        ;;
esac
exit 0
SH
chmod +x "$tmp/cre-labeled"

export FAKE_LOG=$log
rm -f "$log"

pass=0
fail=0

ok() {
    pass=$((pass + 1))
    echo "ok - $1"
}

ko() {
    fail=$((fail + 1))
    echo "not ok - $1"
    echo "  expected: $2"
    echo "  actual:   $3"
}

make_target() {
    target=$1
    shift
    : > "$log"
    rc=0
    make_out=$(make -C "$repo_root" -s "$target" CRE="$tmp/cre" \
        NVIDIA_DRV_VER=test NVIDIA_CUDA_VER=test KVER=test-kver BUILDER_HOST=test-host \
        NVIDIA_DRV_RUN_URL="$drv_url" \
        KOJI_BASE_URL="$koji_url" \
        "$@" 2>&1) || rc=$?
    make_rc=$rc
}

expect_make_rc() {
    desc=$1
    exp_rc=$2
    if [ "$make_rc" -eq "$exp_rc" ]; then
        ok "$desc"
    else
        ko "$desc" "make rc=$exp_rc" "make rc=$make_rc out=$make_out"
    fi
}

expect_sequence() {
    desc=$1
    expected=$2
    actual=$(sed -n 's/.* -f \([^ ]*\) .*/\1/p' "$log" | paste -sd' ')
    if [ "$actual" = "$expected" ]; then
        ok "$desc"
    else
        ko "$desc" "sequence: $expected" "sequence: $actual"
    fi
}

expect_final_build_contains() {
    desc=$1
    pattern=$2
    last=$(tail -n 1 "$log")
    case "$last" in
        *"$pattern"*) ok "$desc" ;;
        *) ko "$desc" "final build contains: $pattern" "final build: $last" ;;
    esac
}

expect_log_contains() {
    desc=$1
    pattern=$2
    if grep -qF -- "$pattern" "$log"; then
        ok "$desc"
    else
        ko "$desc" "log contains: $pattern" "log: $(cat "$log")"
    fi
}

expect_no_from() {
    desc=$1
    if grep -q -- '--from' "$log"; then
        ko "$desc" "no --from in build calls" "count: $(grep -c -- '--from' "$log")"
    else
        ok "$desc"
    fi
}

# --- 1. make -n: syntax of all active targets ---
for t in nvidia-base kernel-devel kernel-redist kmod-oss kmod nvidia-redist-drv lact-redist \
         nvidia-xorg nvidia-cuda-devel nvidia-cuda-libs nvidia-nccl-devel \
          nvidia-nccl-libs nvidia-lact nvidia-lact-autoswitch nvidia-nccl llama-cpp-cuda llama-cpp-cuda-debug clean systemd llama-cpp-restart ; do
    rc=0
    make -C "$repo_root" -n -s "$t" CRE="$tmp/cre" \
        NVIDIA_DRV_VER=test NVIDIA_CUDA_VER=test KVER=test-kver BUILDER_HOST=test-host \
        NVIDIA_DRV_RUN_URL="$drv_url" > /dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        ok "make -n $t"
    else
        ko "make -n $t" "rc=0" "rc=$rc"
    fi
done

# --- 2. nvidia-base ---
make_target nvidia-base REPO_BASE_URL="$repo_base_url"
expect_make_rc "nvidia-base rc=0" 0
expect_sequence "nvidia-base sequence" "nvidia-base.containerfile"
expect_final_build_contains "nvidia-base REPO_BASE_URL" "--build-arg REPO_BASE_URL=$repo_base_url"
expect_final_build_contains "nvidia-base BASE_IMAGE" "--build-arg BASE_IMAGE=registry.fedoraproject.org/fedora-minimal:44"
expect_final_build_contains "nvidia-base tag" "-t nvidia-base:44"
expect_no_from "nvidia-base no --from"
if grep -q '^    which \\$' "$repo_root/nvidia-base.containerfile"; then
    ok "nvidia-base: which in install list"
else
    ko "nvidia-base: which in install list" "install list line 'which \'" "$(grep -n 'which' "$repo_root/nvidia-base.containerfile" || echo 'no which line')"
fi
if grep -q 'dnf5 config-manager' "$repo_root/nvidia-base.containerfile"; then
    ko "nvidia-base: no dnf5 config-manager (unified dnf)" "no 'dnf5 config-manager'" "$(grep -n 'dnf5 config-manager' "$repo_root/nvidia-base.containerfile")"
else
    ok "nvidia-base: no dnf5 config-manager (unified dnf)"
fi
if grep -q 'dnf config-manager setopt fedora.enabled=1 updates.enabled=1' "$repo_root/nvidia-base.containerfile"; then
    ok "nvidia-base: dnf config-manager"
else
    ko "nvidia-base: dnf config-manager" "line: dnf config-manager setopt fedora.enabled=1 updates.enabled=1" "$(grep -n 'config-manager' "$repo_root/nvidia-base.containerfile" || echo 'no config-manager line')"
fi

# --- 3. kernel-devel ---
make_target kernel-devel KVER=$kver_test
expect_make_rc "kernel-devel rc=0" 0
expect_sequence "kernel-devel sequence" "nvidia-base.containerfile kernel-redist.containerfile kernel-devel.containerfile"
expect_final_build_contains "kernel-devel BASE_IMAGE" "--build-arg BASE_IMAGE=nvidia-base:44"
expect_final_build_contains "kernel-devel KERNEL_REDIST_IMAGE" "--build-arg KERNEL_REDIST_IMAGE=kernel-redist:$kver_test"
expect_final_build_contains "kernel-devel KERNEL_REDIST_IMAGE_ID" "--build-arg KERNEL_REDIST_IMAGE_ID=sha256:fake-kernel-redist-$kver_test"
expect_final_build_contains "kernel-devel KVER arg" "--build-arg KVER=$kver_test"
expect_final_build_contains "kernel-devel tag" "-t kernel-devel:$kver_test"
kd_last=$(tail -n 1 "$log")
case "$kd_last" in
    *"--env KERNEL_VERSION"*)
        ko "kernel-devel: no --env KERNEL_VERSION (dead env)" "no '--env KERNEL_VERSION' in final build" "final build: $kd_last"
        ;;
    *)
        ok "kernel-devel: no --env KERNEL_VERSION (dead env)"
        ;;
esac
case "$kd_last" in
    *" -v "*)
        ko "kernel-devel: no -v (pkg-cache mount)" "no ' -v ' in final build" "final build: $kd_last"
        ;;
    *)
        ok "kernel-devel: no -v (pkg-cache mount)"
        ;;
esac
expect_no_from "kernel-devel no --from"

# --- 4. kmod-oss (git pull path: pre-created working dir) ---
make_target kmod-oss NVIDIA_OSS_KMOD="$tmp/ogkm" NVIDIA_OSS_KMOD_URL="$tmp/ogkm-repo" KVER=$kver_test
expect_make_rc "kmod-oss (pull) rc=0" 0
expect_sequence "kmod-oss sequence" "nvidia-base.containerfile kernel-redist.containerfile kernel-devel.containerfile nvidia-kmod-oss.containerfile"
expect_final_build_contains "kmod-oss KERNEL_DEVEL_IMAGE" "--build-arg KERNEL_DEVEL_IMAGE=kernel-devel:$kver_test"
expect_final_build_contains "kmod-oss BASE_IMAGE" "--build-arg BASE_IMAGE=nvidia-base:44"
expect_final_build_contains "kmod-oss HOSTNAME" "--env HOSTNAME=test-host"
expect_final_build_contains "kmod-oss KERNEL_VERSION" "--env KERNEL_VERSION=$kver_test"
expect_final_build_contains "kmod-oss tag" "-t nvidia-kmod-oss-test:$kver_test"
expect_no_from "kmod-oss no --from"

# clone path: only executable once the recipe uses the variable (offline via local repo)
if grep -qF 'git clone -o origin $(NVIDIA_OSS_KMOD_URL) $(NVIDIA_OSS_KMOD)' "$repo_root/Makefile"; then
    git -C "$tmp/ogkm-repo" checkout -q test
    printf 'bump\n' >> "$tmp/ogkm-repo/README"
    git -C "$tmp/ogkm-repo" commit -qam bump-test
    git -C "$tmp/ogkm-repo" checkout -q master
    "$repo_root/scripts/safe-rm" --under "$(dirname "$tmp")" "$tmp/ogkm"
    make_target kmod-oss NVIDIA_OSS_KMOD="$tmp/ogkm" NVIDIA_OSS_KMOD_URL="$tmp/ogkm-repo" KVER=$kver_test
    expect_make_rc "kmod-oss (clone) rc=0" 0
    expect_log_contains "kmod-oss (clone) local dir" "$tmp/ogkm"
    clone_tip=$(git -C "$tmp/ogkm" rev-parse HEAD)
    tag_tip=$(git -C "$tmp/ogkm-repo" rev-parse test)
    if [ "$clone_tip" = "$tag_tip" ]; then
        ok "kmod-oss (clone): HEAD at NVIDIA_DRV_VER (fresh-clone fix)"
    else
        ko "kmod-oss (clone): HEAD at NVIDIA_DRV_VER (fresh-clone fix)" "$tag_tip" "$clone_tip"
    fi
else
    ko "kmod-oss (clone) via NVIDIA_OSS_KMOD_URL" "git clone -o origin \$(NVIDIA_OSS_KMOD_URL) \$(NVIDIA_OSS_KMOD)" "not in Makefile"
fi

if [ -f "$tmp/ogkm/.containerignore" ] && grep -qxF -- '**/.git' "$tmp/ogkm/.containerignore"; then
    ok "kmod-oss: .containerignore in clone context"
else
    ko "kmod-oss: .containerignore in clone context" "file with single line '**/.git' in \$tmp/ogkm" "$(cat "$tmp/ogkm/.containerignore" 2>/dev/null || echo 'no file')"
fi

# --- 5. kmod ---
make_target kmod KVER=$kver_test
expect_make_rc "kmod rc=0" 0
expect_sequence "kmod sequence" "nvidia-base.containerfile kernel-redist.containerfile kernel-devel.containerfile nvidia-redist-drv.containerfile nvidia-kmod.containerfile"
expect_final_build_contains "kmod BASE_IMAGE" "--build-arg BASE_IMAGE=nvidia-base:44"
expect_final_build_contains "kmod KERNEL_DEVEL_IMAGE" "--build-arg KERNEL_DEVEL_IMAGE=kernel-devel:$kver_test"
expect_final_build_contains "kmod DRIVER_REDIST_IMAGE" "--build-arg DRIVER_REDIST_IMAGE=nvidia-redist-drv:test"
expect_final_build_contains "kmod KERNEL_DEVEL_IMAGE_ID" "--build-arg KERNEL_DEVEL_IMAGE_ID=sha256:fake-kernel-devel-$kver_test"
expect_final_build_contains "kmod DRIVER_REDIST_IMAGE_ID" "--build-arg DRIVER_REDIST_IMAGE_ID=sha256:fake-nvidia-redist-drv-test"
expect_final_build_contains "kmod KERNEL_VERSION" "--build-arg KERNEL_VERSION=$kver_test"
expect_final_build_contains "kmod tag" "-t nvidia-kmod-test:$kver_test"
expect_log_contains "kmod redist via variables" "-t nvidia-redist-drv:test"
expect_log_contains "kmod redist URL" "--build-arg DRIVER_URL=$drv_url"
expect_no_from "kmod no --from"
if grep -qF 'make modules -j $(nproc)' "$repo_root/nvidia-kmod.containerfile"; then
    ok "nvidia-kmod: make modules -j \$(nproc)"
else
    ko "nvidia-kmod: make modules -j \$(nproc)" "make modules -j \$(nproc)" "$(grep -n -- '-j ' "$repo_root/nvidia-kmod.containerfile" || echo 'no -j lines')"
fi
for pair in 'make modules -j $(nproc) KERNEL_UNAME=$kver' \
            'make modules_install -j $(nproc) KERNEL_UNAME=$kver'; do
    if grep -qF -- "$pair" "$repo_root/nvidia-kmod.containerfile"; then
        ok "nvidia-kmod containerfile: $pair (cross-build KDIR)"
    else
        ko "nvidia-kmod containerfile: $pair (cross-build KDIR)" "line in nvidia-kmod.containerfile" "not found"
    fi
done

# --- 6. nvidia-xorg ---
make_target nvidia-xorg
expect_make_rc "nvidia-xorg rc=0" 0
expect_sequence "nvidia-xorg sequence" "nvidia-base.containerfile nvidia-redist-drv.containerfile nvidia-xorg.containerfile"
expect_final_build_contains "nvidia-xorg BASE_IMAGE" "--build-arg BASE_IMAGE=nvidia-base:44"
expect_final_build_contains "nvidia-xorg DRIVER_REDIST_IMAGE" "--build-arg DRIVER_REDIST_IMAGE=nvidia-redist-drv:test"
expect_final_build_contains "nvidia-xorg DRIVER_REDIST_IMAGE_ID" "--build-arg DRIVER_REDIST_IMAGE_ID=sha256:fake-nvidia-redist-drv-test"
expect_final_build_contains "nvidia-xorg tag" "-t nvidia-xorg:test"
expect_no_from "nvidia-xorg no --from"

# --- 7. nvidia-cuda-devel ---
make_target nvidia-cuda-devel
expect_make_rc "nvidia-cuda-devel rc=0" 0
expect_sequence "nvidia-cuda-devel sequence" "nvidia-base.containerfile nvidia-redist-drv.containerfile nvidia-xorg.containerfile nvidia-cuda-devel.containerfile"
expect_final_build_contains "nvidia-cuda-devel BASE_IMAGE" "--build-arg BASE_IMAGE=nvidia-base:44"
expect_final_build_contains "nvidia-cuda-devel NVIDIA_XORG_IMAGE" "--build-arg NVIDIA_XORG_IMAGE=nvidia-xorg:test"
expect_final_build_contains "nvidia-cuda-devel NVIDIA_XORG_IMAGE_ID" "--build-arg NVIDIA_XORG_IMAGE_ID=sha256:fake-nvidia-xorg-test"
expect_final_build_contains "nvidia-cuda-devel CUDA_REPO_BASE" "--build-arg CUDA_REPO_BASE=https://developer.download.nvidia.com/compute/cuda/repos/fedora44/x86_64"
expect_final_build_contains "nvidia-cuda-devel CUDA_PKG_SERIES" "--build-arg CUDA_PKG_SERIES=test"
expect_final_build_contains "nvidia-cuda-devel CUDA_DEVEL_SET" "--build-arg CUDA_DEVEL_SET=cuda-minimal-build-test"
expect_final_build_contains "nvidia-cuda-devel tag" "-t nvidia-cuda-devel:test"
expect_no_from "nvidia-cuda-devel no --from"

# --- 8. nvidia-cuda-libs ---
make_target nvidia-cuda-libs
expect_make_rc "nvidia-cuda-libs rc=0" 0
expect_sequence "nvidia-cuda-libs sequence" "nvidia-base.containerfile nvidia-redist-drv.containerfile nvidia-xorg.containerfile nvidia-cuda-libs.containerfile"
expect_final_build_contains "nvidia-cuda-libs BASE_IMAGE" "--build-arg BASE_IMAGE=nvidia-base:44"
expect_final_build_contains "nvidia-cuda-libs NVIDIA_XORG_IMAGE" "--build-arg NVIDIA_XORG_IMAGE=nvidia-xorg:test"
expect_final_build_contains "nvidia-cuda-libs NVIDIA_XORG_IMAGE_ID" "--build-arg NVIDIA_XORG_IMAGE_ID=sha256:fake-nvidia-xorg-test"
expect_final_build_contains "nvidia-cuda-libs CUDA_REPO_BASE" "--build-arg CUDA_REPO_BASE=https://developer.download.nvidia.com/compute/cuda/repos/fedora44/x86_64"
expect_final_build_contains "nvidia-cuda-libs CUDA_PKG_SERIES" "--build-arg CUDA_PKG_SERIES=test"
expect_final_build_contains "nvidia-cuda-libs CUDA_RUNTIME_SET" "--build-arg CUDA_RUNTIME_SET=cuda-cudart-test"
expect_final_build_contains "nvidia-cuda-libs tag" "-t nvidia-cuda-libs:test"
expect_no_from "nvidia-cuda-libs no --from"

# --- 9. llama-cpp-cuda (git pull path: pre-created working dir) ---
make_target llama-cpp-cuda LLAMA_CPP="$tmp/llama-cpp" \
    NCCL="$tmp/nccl" NCCL_REPO="$tmp/nccl-repo" NCCL_REF=test-nccl
expect_make_rc "llama-cpp-cuda (pull) rc=0" 0
expect_sequence "llama-cpp-cuda sequence" "nvidia-base.containerfile nvidia-redist-drv.containerfile nvidia-xorg.containerfile nvidia-cuda-devel.containerfile nvidia-nccl-devel.containerfile nvidia-cuda-libs.containerfile nvidia-nccl-libs.containerfile llama-cpp-cuda.containerfile"
expect_final_build_contains "llama-cpp-cuda BASE_IMAGE" "--build-arg BASE_IMAGE=nvidia-nccl-libs-cuda-test:test-nccl"
expect_final_build_contains "llama-cpp-cuda CUDA_DEVEL_IMAGE" "--build-arg CUDA_DEVEL_IMAGE=nvidia-nccl-devel-cuda-test:test-nccl"
expect_final_build_contains "llama-cpp-cuda NVCC" "--build-arg NVCC=/usr/local/cuda/bin/nvcc"
expect_final_build_contains "llama-cpp-cuda CUDA_ARCH" "--build-arg CUDA_ARCH=86"
expect_final_build_contains "llama-cpp-cuda GCC_VER" "--build-arg GCC_VER=15"
expect_final_build_contains "llama-cpp-cuda tag" "-t llama-cpp-cuda:test"
expect_final_build_contains "llama-cpp-cuda REF arg (default)" "--build-arg LLAMA_CPP_REF=master"
expect_final_build_contains "llama-cpp-cuda REPO arg (default)" "--build-arg LLAMA_CPP_REPO=https://github.com/ggml-org/llama.cpp.git"
expect_final_build_contains "llama-cpp-cuda SHA arg (default)" "--build-arg LLAMA_CPP_SHA=$(git -C "$tmp/llama-cpp" rev-parse HEAD)"
expect_no_from "llama-cpp-cuda no --from"
# fetch form follows remote branch tip
printf 'bump\n' >> "$tmp/llama-repo/README"
git -C "$tmp/llama-repo" commit -qam bump
make_target llama-cpp-cuda LLAMA_CPP="$tmp/llama-cpp" \
    NCCL="$tmp/nccl" NCCL_REPO="$tmp/nccl-repo" NCCL_REF=test-nccl
expect_make_rc "llama-cpp-cuda (fetch follows remote) rc=0" 0
llama_tip=$(git -C "$tmp/llama-cpp" rev-parse HEAD)
remote_tip=$(git -C "$tmp/llama-repo" rev-parse master)
if [ "$llama_tip" = "$remote_tip" ]; then
    ok "llama-cpp-cuda: HEAD follows remote master tip"
else
    ko "llama-cpp-cuda: HEAD follows remote master tip" "$remote_tip" "$llama_tip"
fi

# clone path: only executable once the recipe uses the variables (offline via local repo)
if grep -qF 'git clone -o origin --branch $(LLAMA_CPP_REF) $(LLAMA_CPP_REPO) $(LLAMA_CPP)' "$repo_root/Makefile"; then
    "$repo_root/scripts/safe-rm" --under "$(dirname "$tmp")" "$tmp/llama-cpp"
    make_target llama-cpp-cuda LLAMA_CPP="$tmp/llama-cpp" LLAMA_CPP_REPO="$tmp/llama-repo" \
        NCCL="$tmp/nccl" NCCL_REPO="$tmp/nccl-repo" NCCL_REF=test-nccl
    expect_make_rc "llama-cpp-cuda (clone) rc=0" 0
    expect_log_contains "llama-cpp-cuda (clone) local dir" "$tmp/llama-cpp"
else
    ko "llama-cpp-cuda (clone) via LLAMA_CPP_REPO" "git clone -o origin --branch \$(LLAMA_CPP_REF) \$(LLAMA_CPP_REPO) \$(LLAMA_CPP)" "not in Makefile"
fi

if [ -f "$tmp/llama-cpp/.containerignore" ] && grep -qxF -- '**/.git' "$tmp/llama-cpp/.containerignore"; then
    ok "llama-cpp-cuda: .containerignore in clone context"
else
    ko "llama-cpp-cuda: .containerignore in clone context" "file with single line '**/.git' in \$tmp/llama-cpp" "$(cat "$tmp/llama-cpp/.containerignore" 2>/dev/null || echo 'no file')"
fi

# --- 10. llama-cpp-cuda-debug ---
make_target llama-cpp-cuda-debug LLAMA_CPP="$tmp/llama-cpp" \
    NCCL="$tmp/nccl" NCCL_REPO="$tmp/nccl-repo" NCCL_REF=test-nccl
expect_make_rc "llama-cpp-cuda-debug rc=0" 0
expect_sequence "llama-cpp-cuda-debug sequence" "nvidia-base.containerfile nvidia-redist-drv.containerfile nvidia-xorg.containerfile nvidia-cuda-devel.containerfile nvidia-nccl-devel.containerfile nvidia-cuda-libs.containerfile nvidia-nccl-libs.containerfile llama-cpp-cuda.containerfile llama-cpp-cuda-debug.containerfile"
expect_final_build_contains "llama-cpp-cuda-debug BASE_IMAGE" "--build-arg BASE_IMAGE=nvidia-nccl-devel-cuda-test:test-nccl"
expect_final_build_contains "llama-cpp-cuda-debug LLAMA_IMAGE" "--build-arg LLAMA_IMAGE=llama-cpp-cuda:test"
expect_final_build_contains "llama-cpp-cuda-debug tag" "-t llama-cpp-cuda-debug:test"
expect_no_from "llama-cpp-cuda-debug no --from"

# --- 10a. llama-cpp-cuda fork naming (variant between llama-cpp and cuda) ---
make_target llama-cpp-cuda LLAMA_CPP="$tmp/llama-cpp" LLAMA_CPP_REPO="$tmp/llama-repo" \
    LLAMA_CPP_REF=glm5next \
    NCCL="$tmp/nccl" NCCL_REPO="$tmp/nccl-repo" NCCL_REF=test-nccl
expect_make_rc "llama-cpp-cuda (fork) rc=0" 0
expect_final_build_contains "llama-cpp-cuda (fork) tag" "-t llama-cpp-glm5next-cuda:test"
expect_final_build_contains "llama-cpp-cuda (fork) REF arg" "--build-arg LLAMA_CPP_REF=glm5next"
expect_final_build_contains "llama-cpp-cuda (fork) SHA arg" "--build-arg LLAMA_CPP_SHA=$(git -C "$tmp/llama-repo" rev-parse glm5next)"

make_target llama-cpp-cuda-debug LLAMA_CPP="$tmp/llama-cpp" LLAMA_CPP_REPO="$tmp/llama-repo" \
    LLAMA_CPP_REF=glm5next \
    NCCL="$tmp/nccl" NCCL_REPO="$tmp/nccl-repo" NCCL_REF=test-nccl
expect_make_rc "llama-cpp-cuda-debug (fork) rc=0" 0
expect_final_build_contains "llama-cpp-cuda-debug (fork) LLAMA_IMAGE" "--build-arg LLAMA_IMAGE=llama-cpp-glm5next-cuda:test"
expect_final_build_contains "llama-cpp-cuda-debug (fork) tag" "-t llama-cpp-glm5next-cuda-debug:test"

make_target llama-cpp-cuda LLAMA_CPP="$tmp/llama-cpp" LLAMA_CPP_REPO="$tmp/llama-repo" \
    LLAMA_CPP_REF=glm5/flash \
    NCCL="$tmp/nccl" NCCL_REPO="$tmp/nccl-repo" NCCL_REF=test-nccl
expect_make_rc "llama-cpp-cuda (fork slash) rc=0" 0
expect_final_build_contains "llama-cpp-cuda (fork slash) tag" "-t llama-cpp-glm5-flash-cuda:test"

# --- 11. nvidia-nccl-devel (git fetch/checkout path: pre-created working dir) ---
make_target nvidia-nccl-devel NCCL="$tmp/nccl" NCCL_REPO="$tmp/nccl-repo" NCCL_REF=test-nccl
expect_make_rc "nvidia-nccl-devel (fetch) rc=0" 0
expect_sequence "nvidia-nccl-devel sequence" "nvidia-base.containerfile nvidia-redist-drv.containerfile nvidia-xorg.containerfile nvidia-cuda-devel.containerfile nvidia-nccl-devel.containerfile"
expect_final_build_contains "nvidia-nccl-devel CUDA_DEVEL_IMAGE" "--build-arg CUDA_DEVEL_IMAGE=nvidia-cuda-devel:test"
expect_final_build_contains "nvidia-nccl-devel NVCC" "--build-arg NVCC=/usr/local/cuda/bin/nvcc"
expect_final_build_contains "nvidia-nccl-devel CUDA_ARCH" "--build-arg CUDA_ARCH=86"
expect_final_build_contains "nvidia-nccl-devel CUDA_VER" "--build-arg CUDA_VER=test"
expect_final_build_contains "nvidia-nccl-devel GCC_VER" "--build-arg GCC_VER=15"
expect_final_build_contains "nvidia-nccl-devel tag" "-t nvidia-nccl-devel-cuda-test:test-nccl"
expect_no_from "nvidia-nccl-devel no --from"

# clone path: only executable once the recipe uses the variables (offline via local repo)
if grep -qF 'git clone -o origin --branch $(NCCL_REF) $(NCCL_REPO) $(NCCL)' "$repo_root/Makefile"; then
    "$repo_root/scripts/safe-rm" --under "$(dirname "$tmp")" "$tmp/nccl"
    make_target nvidia-nccl-devel NCCL="$tmp/nccl" NCCL_REPO="$tmp/nccl-repo" NCCL_REF=test-nccl
    expect_make_rc "nvidia-nccl-devel (clone) rc=0" 0
    expect_log_contains "nvidia-nccl-devel (clone) local dir" "$tmp/nccl"
else
    ko "nvidia-nccl-devel (clone) via NCCL_REPO" "git clone -o origin --branch \$(NCCL_REF) \$(NCCL_REPO) \$(NCCL)" "not in Makefile"
fi

if [ -f "$tmp/nccl/.containerignore" ] && grep -qxF -- '**/.git' "$tmp/nccl/.containerignore"; then
    ok "nvidia-nccl-devel: .containerignore in clone context"
else
    ko "nvidia-nccl-devel: .containerignore in clone context" "file with single line '**/.git' in \$tmp/nccl" "$(cat "$tmp/nccl/.containerignore" 2>/dev/null || echo 'no file')"
fi

# --- 12. nvidia-nccl-libs ---
make_target nvidia-nccl-libs NCCL="$tmp/nccl" NCCL_REPO="$tmp/nccl-repo" NCCL_REF=test-nccl
expect_make_rc "nvidia-nccl-libs rc=0" 0
expect_sequence "nvidia-nccl-libs sequence" "nvidia-base.containerfile nvidia-redist-drv.containerfile nvidia-xorg.containerfile nvidia-cuda-devel.containerfile nvidia-nccl-devel.containerfile nvidia-cuda-libs.containerfile nvidia-nccl-libs.containerfile"
expect_final_build_contains "nvidia-nccl-libs NCCL_DEVEL_IMAGE" "--build-arg NCCL_DEVEL_IMAGE=nvidia-nccl-devel-cuda-test:test-nccl"
expect_final_build_contains "nvidia-nccl-libs NCCL_DEVEL_IMAGE_ID" "--build-arg NCCL_DEVEL_IMAGE_ID=sha256:fake-nvidia-nccl-devel-cuda-test-test-nccl"
expect_final_build_contains "nvidia-nccl-libs BASE_IMAGE" "--build-arg BASE_IMAGE=nvidia-cuda-libs:test"
expect_final_build_contains "nvidia-nccl-libs CUDA_VER" "--build-arg CUDA_VER=test"
expect_final_build_contains "nvidia-nccl-libs tag" "-t nvidia-nccl-libs-cuda-test:test-nccl"
expect_no_from "nvidia-nccl-libs no --from"

# --- 13. nvidia-nccl (meta: prerequisites only, same sequence as nvidia-nccl-libs) ---
make_target nvidia-nccl NCCL="$tmp/nccl" NCCL_REPO="$tmp/nccl-repo" NCCL_REF=test-nccl
expect_make_rc "nvidia-nccl rc=0" 0
expect_sequence "nvidia-nccl sequence" "nvidia-base.containerfile nvidia-redist-drv.containerfile nvidia-xorg.containerfile nvidia-cuda-devel.containerfile nvidia-nccl-devel.containerfile nvidia-cuda-libs.containerfile nvidia-nccl-libs.containerfile"
expect_final_build_contains "nvidia-nccl final tag" "-t nvidia-nccl-libs-cuda-test:test-nccl"
expect_no_from "nvidia-nccl no --from"

# --- 14. git blocks use unified fetch form with variables (static) ---
for pair in 'git fetch origin $(LLAMA_CPP_REF)' 'git fetch origin $(NVIDIA_DRV_VER)' 'git fetch origin $(NCCL_REF)'; do
    if grep -qF -- "$pair" "$repo_root/Makefile"; then
        ok "git block: $pair"
    else
        ko "git block: $pair" "$pair" "$(grep -n 'git fetch' "$repo_root/Makefile" || echo 'no git fetch lines')"
    fi
done
if grep -qF 'git checkout -f FETCH_HEAD' "$repo_root/Makefile"; then
    ok "git blocks: checkout -f FETCH_HEAD"
else
    ko "git blocks: checkout -f FETCH_HEAD" "git checkout -f FETCH_HEAD" "$(grep -n 'checkout' "$repo_root/Makefile" || echo 'no checkout lines')"
fi
if grep -q 'git pull' "$repo_root/Makefile"; then
    ko "Makefile: no git pull (fetch form)" "no 'git pull'" "$(grep -n 'git pull' "$repo_root/Makefile")"
else
    ok "Makefile: no git pull (fetch form)"
fi

# --- 15. no --from in active Makefile lines ---
if grep -v '^[[:space:]]*#' "$repo_root/Makefile" | grep -q -- '--from'; then
    ko "Makefile: no --from (active lines)" "no --from" "$(grep -n -- '--from' "$repo_root/Makefile")"
else
    ok "Makefile: no --from (active lines)"
fi

# --- 16. containerfiles: FROM via ARG (or scratch) + comment line above ---
cf_files="$repo_root/nvidia-base.containerfile $repo_root/kernel-devel.containerfile $repo_root/kernel-redist.containerfile $repo_root/nvidia-kmod-oss.containerfile $repo_root/nvidia-kmod.containerfile $repo_root/nvidia-xorg.containerfile $repo_root/nvidia-cuda-devel.containerfile $repo_root/nvidia-cuda-libs.containerfile $repo_root/llama-cpp-cuda.containerfile $repo_root/nvidia-redist-drv.containerfile $repo_root/nvidia-nccl-devel.containerfile $repo_root/nvidia-nccl-libs.containerfile $repo_root/llama-cpp-cuda-debug.containerfile $repo_root/lact-redist.containerfile $repo_root/nvidia-lact.containerfile $repo_root/nvidia-lact-autoswitch.containerfile"
bad_from=$(awk '
    FNR == 1 { prev = "" }
    /^FROM/ {
        if ($0 !~ /^FROM[ \t]+(\$\{?[A-Z_]+\}?|scratch)([ \t]+(as|AS)[ \t]+[A-Za-z0-9_-]+)?$/ || prev !~ /^#/) {
            print "  " FILENAME ":" FNR ": " $0
        }
    }
    { prev = $0 }
' $cf_files)
if [ -z "$bad_from" ]; then
    ok "containerfiles: all FROM via ARG (or scratch) with comment line above"
else
    ko "containerfiles: all FROM via ARG (or scratch) with comment line above" "every FROM is \$ARG/scratch + # comment line above" "$bad_from"
fi

# --- 16b. llama-cpp-cuda containerfile: ARG + LABEL (bare $VAR form) ---
for pair in 'ARG LLAMA_CPP_REF' 'ARG LLAMA_CPP_REPO' 'ARG LLAMA_CPP_SHA' \
            'com.llm-rig/llama-cpp.ref="$LLAMA_CPP_REF"' \
            'com.llm-rig/llama-cpp.repo="$LLAMA_CPP_REPO"' \
            'com.llm-rig/llama-cpp.sha="$LLAMA_CPP_SHA"'; do
    if grep -qF -- "$pair" "$repo_root/llama-cpp-cuda.containerfile"; then
        ok "llama-cpp-cuda containerfile: $pair"
    else
        ko "llama-cpp-cuda containerfile: $pair" "line in llama-cpp-cuda.containerfile" "not found"
    fi
done

# --- 16c. containerfiles: FROM via braced ${VAR} (no bare $VAR) ---
bare_from=$(grep -Hn '^FROM \$[A-Za-z_]' "$repo_root/"*.containerfile || true)
if [ -z "$bare_from" ]; then
    ok "containerfiles: FROM via braced \${VAR}"
else
    ko "containerfiles: FROM via braced \${VAR}" "no bare \$VAR in FROM" "$bare_from"
fi

# --- 16d. llama-cpp-cuda: builder in /llama (no NCCL tree leak) ---
if grep -qxF 'WORKDIR /llama' "$repo_root/llama-cpp-cuda.containerfile" && \
   grep -qxF 'COPY --from=builder /llama/build/bin/ /app/' "$repo_root/llama-cpp-cuda.containerfile" && \
   [ "$(grep -c '^WORKDIR /app$' "$repo_root/llama-cpp-cuda.containerfile")" = "1" ]; then
    ok "llama-cpp-cuda: builder in /llama (no NCCL tree leak)"
else
    ko "llama-cpp-cuda: builder in /llama (no NCCL tree leak)" "WORKDIR /llama + COPY --from=builder /llama/build/bin/ /app/, one WORKDIR /app (final)" "$(grep -n 'WORKDIR\|COPY --from=builder' "$repo_root/llama-cpp-cuda.containerfile")"
fi
if grep -q 'rm -f /tmp/installer.run' "$repo_root/nvidia-xorg.containerfile"; then
    ko "nvidia-xorg: dead rm line removed" "no 'rm -f /tmp/installer.run'" "$(grep -n 'rm -f /tmp/installer.run' "$repo_root/nvidia-xorg.containerfile")"
else
    ok "nvidia-xorg: dead rm line removed"
fi
if grep -qxF '    ModulePath "/usr/lib64/xorg/modules"' "$repo_root/resources/driver/etc/X11/xorg.conf.d/10-nvidia.conf"; then
    ok "xorg.conf: ModulePath /usr/lib64/xorg/modules"
else
    ko "xorg.conf: ModulePath /usr/lib64/xorg/modules" 'line:     ModulePath "/usr/lib64/xorg/modules"' "$(cat "$repo_root/resources/driver/etc/X11/xorg.conf.d/10-nvidia.conf" 2>/dev/null)"
fi

# --- 16e. kernel-redist containerfile: ARG + LABEL ---
for pair in 'ARG HEADERS_URL' 'com.llm-rig/kernel.version="$KVER"'; do
    if grep -qF -- "$pair" "$repo_root/kernel-redist.containerfile"; then
        ok "kernel-redist containerfile: $pair"
    else
        ko "kernel-redist containerfile: $pair" "line in kernel-redist.containerfile" "not found"
    fi
done

# --- 16f. stage 6 statics: pkg-cache mechanism removed ---
if grep -q 'PKG_CACHE_DIR' "$repo_root/Makefile"; then
    ko "Makefile: PKG_CACHE_DIR removed" "no PKG_CACHE_DIR" "$(grep -n 'PKG_CACHE_DIR' "$repo_root/Makefile")"
else
    ok "Makefile: PKG_CACHE_DIR removed"
fi
if grep -qxF 'pkg-cache' "$repo_root/.gitignore"; then
    ko ".gitignore: pkg-cache line removed" "no 'pkg-cache' line" "$(grep -n 'pkg-cache' "$repo_root/.gitignore")"
else
    ok ".gitignore: pkg-cache line removed"
fi
if grep -q 'koji' "$repo_root/kernel-devel.containerfile"; then
    ko "kernel-devel.containerfile: koji removed" "no 'koji'" "$(grep -n 'koji' "$repo_root/kernel-devel.containerfile")"
else
    ok "kernel-devel.containerfile: koji removed"
fi
for pair in 'FROM ${KERNEL_REDIST_IMAGE} as rpms' '--mount=type=bind,from=rpms,source=/,target=/mnt/rpms' 'dnf install -y /mnt/rpms/kernel-*.rpm'; do
    if grep -qF -- "$pair" "$repo_root/kernel-devel.containerfile"; then
        ok "kernel-devel.containerfile: $pair"
    else
        ko "kernel-devel.containerfile: $pair" "line in kernel-devel.containerfile" "not found"
    fi
done

# --- 16g. stage 17 statics: kernel-chain cache-key ARGs + verification ---
for pair in 'ARG KVER' 'ARG KERNEL_REDIST_IMAGE_ID' 'rpm -q' 'test -f /usr/src/kernels/${KVER}/.config'; do
    if grep -qF -- "$pair" "$repo_root/kernel-devel.containerfile"; then
        ok "kernel-devel containerfile: $pair"
    else
        ko "kernel-devel containerfile: $pair" "line in kernel-devel.containerfile" "not found"
    fi
done
if awk '/^FROM \${KERNEL_DEVEL_IMAGE} as builder$/ { f = 1; next }
       f && /^FROM / { exit }
       f && /^ARG KERNEL_VERSION$/ { found = 1 }
       END { exit !found }' "$repo_root/nvidia-kmod.containerfile"; then
    ok "nvidia-kmod containerfile: in-scope ARG KERNEL_VERSION in builder"
else
    ko "nvidia-kmod containerfile: in-scope ARG KERNEL_VERSION in builder" "ARG KERNEL_VERSION between 'FROM \${KERNEL_DEVEL_IMAGE} as builder' and next FROM" "$(grep -n 'ARG KERNEL_VERSION' "$repo_root/nvidia-kmod.containerfile")"
fi
for pair in 'ARG KERNEL_DEVEL_IMAGE_ID' '[ ! -f /usr/src/kernels/$kver/.config ]'; do
    if grep -qF -- "$pair" "$repo_root/nvidia-kmod.containerfile"; then
        ok "nvidia-kmod containerfile: $pair"
    else
        ko "nvidia-kmod containerfile: $pair" "line in nvidia-kmod.containerfile" "not found"
    fi
done
if [ "$(grep -cxF 'ARG DRIVER_REDIST_IMAGE_ID' "$repo_root/nvidia-kmod.containerfile")" -ge 2 ]; then
    ok "nvidia-kmod containerfile: ARG DRIVER_REDIST_IMAGE_ID x2 (builder + final)"
else
    ko "nvidia-kmod containerfile: ARG DRIVER_REDIST_IMAGE_ID x2 (builder + final)" ">=2 exact lines" "count: $(grep -cxF 'ARG DRIVER_REDIST_IMAGE_ID' "$repo_root/nvidia-kmod.containerfile")"
fi

# --- 16h. stage 17 statics: remaining consumer containerfiles ---
if grep -qF -- 'ARG DRIVER_REDIST_IMAGE_ID' "$repo_root/nvidia-xorg.containerfile"; then
    ok "nvidia-xorg containerfile: ARG DRIVER_REDIST_IMAGE_ID"
else
    ko "nvidia-xorg containerfile: ARG DRIVER_REDIST_IMAGE_ID" "line in nvidia-xorg.containerfile" "not found"
fi
for pair in 'ARG DRIVER_REDIST_IMAGE_ID' 'ARG LACT_REDIST_IMAGE_ID'; do
    if grep -qF -- "$pair" "$repo_root/nvidia-lact.containerfile"; then
        ok "nvidia-lact containerfile: $pair"
    else
        ko "nvidia-lact containerfile: $pair" "line in nvidia-lact.containerfile" "not found"
    fi
done
for pair in 'ARG NVIDIA_XORG_IMAGE_ID' 'ARG CUDA_PKG_SERIES'; do
    if grep -qF -- "$pair" "$repo_root/nvidia-cuda-devel.containerfile"; then
        ok "nvidia-cuda-devel containerfile: $pair"
    else
        ko "nvidia-cuda-devel containerfile: $pair" "line in nvidia-cuda-devel.containerfile" "not found"
    fi
done
for pair in 'ARG NVIDIA_XORG_IMAGE_ID' 'ARG CUDA_PKG_SERIES'; do
    if grep -qF -- "$pair" "$repo_root/nvidia-cuda-libs.containerfile"; then
        ok "nvidia-cuda-libs containerfile: $pair"
    else
        ko "nvidia-cuda-libs containerfile: $pair" "line in nvidia-cuda-libs.containerfile" "not found"
    fi
done
if grep -qF -- 'ARG NCCL_DEVEL_IMAGE_ID' "$repo_root/nvidia-nccl-libs.containerfile"; then
    ok "nvidia-nccl-libs containerfile: ARG NCCL_DEVEL_IMAGE_ID"
else
    ko "nvidia-nccl-libs containerfile: ARG NCCL_DEVEL_IMAGE_ID" "line in nvidia-nccl-libs.containerfile" "not found"
fi

# --- 16i. stage 24 statics: CUDA from NVIDIA dnf repo ---
for pair in 'curl -fsLo /etc/yum.repos.d/cuda-fedora44.repo $CUDA_REPO_BASE/cuda-fedora44.repo' \
            'dnf install -y --setopt=install_weak_deps=False $CUDA_DEVEL_SET' \
            'rpm -qa | grep -- "-${CUDA_PKG_SERIES}-" | sort > /usr/local/cuda-installed.txt'; do
    if grep -qF -- "$pair" "$repo_root/nvidia-cuda-devel.containerfile"; then
        ok "nvidia-cuda-devel containerfile: $pair"
    else
        ko "nvidia-cuda-devel containerfile: $pair" "line in nvidia-cuda-devel.containerfile" "not found"
    fi
done
for pair in 'curl -fsLo /etc/yum.repos.d/cuda-fedora44.repo $CUDA_REPO_BASE/cuda-fedora44.repo' \
            'dnf install -y --setopt=install_weak_deps=False $CUDA_RUNTIME_SET numactl' \
            'rpm -qa | grep -- "-${CUDA_PKG_SERIES}-" | sort > /usr/local/cuda-installed.txt'; do
    if grep -qF -- "$pair" "$repo_root/nvidia-cuda-libs.containerfile"; then
        ok "nvidia-cuda-libs containerfile: $pair"
    else
        ko "nvidia-cuda-libs containerfile: $pair" "line in nvidia-cuda-libs.containerfile" "not found"
    fi
done
for bad in 'CUDA_REDIST' 'cuda-redist' 'installer.sh' '/opt/cuda'; do
    if grep -qF -- "$bad" "$repo_root/nvidia-cuda-devel.containerfile"; then
        ko "nvidia-cuda-devel containerfile: no $bad" "no '$bad'" "$(grep -nF -- "$bad" "$repo_root/nvidia-cuda-devel.containerfile")"
    else
        ok "nvidia-cuda-devel containerfile: no $bad"
    fi
done
for bad in 'CUDA_DEVEL' 'as cuda' 'from=cuda' '/opt/cuda'; do
    if grep -qF -- "$bad" "$repo_root/nvidia-cuda-libs.containerfile"; then
        ko "nvidia-cuda-libs containerfile: no $bad" "no '$bad'" "$(grep -nF -- "$bad" "$repo_root/nvidia-cuda-libs.containerfile")"
    else
        ok "nvidia-cuda-libs containerfile: no $bad"
    fi
done
for bad in 'NVIDIA_REDIST_CUDA' 'NVIDIA_CUDA_URL' 'NVIDIA_CUDA_132' 'nvidia-redist-cuda'; do
    if grep -q -- "$bad" "$repo_root/Makefile"; then
        ko "Makefile: no $bad" "no '$bad' in Makefile" "$(grep -n -- "$bad" "$repo_root/Makefile")"
    else
        ok "Makefile: no $bad"
    fi
done
for pair in '--build-arg "CUDA_DEVEL_SET=$(CUDA_DEVEL_SET)"' '--build-arg "CUDA_RUNTIME_SET=$(CUDA_RUNTIME_SET)"'; do
    if grep -qF -- "$pair" "$repo_root/Makefile"; then
        ok "Makefile: quoted SET build-arg"
    else
        ko "Makefile: quoted SET build-arg" "line: $pair" "$(grep -n 'CUDA_DEVEL_SET=\|CUDA_RUNTIME_SET=' "$repo_root/Makefile")"
    fi
done
if [ -e "$repo_root/nvidia-redist-cuda.containerfile" ]; then
    ko "nvidia-redist-cuda.containerfile removed" "file absent" "present"
else
    ok "nvidia-redist-cuda.containerfile removed"
fi
for pair in 'ARG NVCC=/usr/local/cuda/bin/nvcc' '-DNCCL_ROOT=/usr/local/cuda'; do
    if grep -qF -- "$pair" "$repo_root/llama-cpp-cuda.containerfile"; then
        ok "llama-cpp-cuda containerfile: $pair"
    else
        ko "llama-cpp-cuda containerfile: $pair" "line in llama-cpp-cuda.containerfile" "not found"
    fi
done
for pair in 'ARG NVCC=/usr/local/cuda/bin/nvcc' 'cp -aP build/lib/libnccl* /usr/local/cuda-${CUDA_VER}/lib64/'; do
    if grep -qF -- "$pair" "$repo_root/nvidia-nccl-devel.containerfile"; then
        ok "nvidia-nccl-devel containerfile: $pair"
    else
        ko "nvidia-nccl-devel containerfile: $pair" "line in nvidia-nccl-devel.containerfile" "not found"
    fi
done
for pair in '--mount=type=bind,from=nccl-src,source=/usr/local/cuda-${CUDA_VER},target=/mnt/nccl' \
            'cp -aP /mnt/nccl/lib64/libnccl.so* /usr/local/cuda-${CUDA_VER}/lib64/'; do
    if grep -qF -- "$pair" "$repo_root/nvidia-nccl-libs.containerfile"; then
        ok "nvidia-nccl-libs containerfile: $pair"
    else
        ko "nvidia-nccl-libs containerfile: $pair" "line in nvidia-nccl-libs.containerfile" "not found"
    fi
done
if grep -qF -- '--entrypoint /usr/local/cuda/bin/compute-sanitizer' "$repo_root/debug/repro-llama-block3-run.sh"; then
    ok "repro-llama-block3-run.sh: sanitizer entrypoint /usr/local/cuda"
else
    ko "repro-llama-block3-run.sh: sanitizer entrypoint /usr/local/cuda" "--entrypoint /usr/local/cuda/bin/compute-sanitizer" "$(grep -n 'compute-sanitizer' "$repo_root/debug/repro-llama-block3-run.sh")"
fi

# --- 17. lact-redist ---
make_target lact-redist LACT_URL="$lact_url"
expect_make_rc "lact-redist rc=0" 0
expect_sequence "lact-redist sequence" "lact-redist.containerfile"
expect_final_build_contains "lact-redist LACT_URL" "--build-arg LACT_URL=$lact_url"
expect_final_build_contains "lact-redist LACT_VER" "--build-arg LACT_VER=v0.10.0"
expect_final_build_contains "lact-redist tag" "-t lact-redist:v0.10.0"
expect_no_from "lact-redist no --from"

# --- 18. nvidia-lact ---
make_target nvidia-lact LACT_URL="$lact_url"
expect_make_rc "nvidia-lact rc=0" 0
expect_sequence "nvidia-lact sequence" "nvidia-base.containerfile nvidia-redist-drv.containerfile lact-redist.containerfile nvidia-lact.containerfile"
expect_final_build_contains "nvidia-lact BASE_IMAGE" "--build-arg BASE_IMAGE=nvidia-base:44"
expect_final_build_contains "nvidia-lact DRIVER_REDIST_IMAGE" "--build-arg DRIVER_REDIST_IMAGE=nvidia-redist-drv:test"
expect_final_build_contains "nvidia-lact LACT_REDIST_IMAGE" "--build-arg LACT_REDIST_IMAGE=lact-redist:v0.10.0"
expect_final_build_contains "nvidia-lact DRIVER_REDIST_IMAGE_ID" "--build-arg DRIVER_REDIST_IMAGE_ID=sha256:fake-nvidia-redist-drv-test"
expect_final_build_contains "nvidia-lact LACT_REDIST_IMAGE_ID" "--build-arg LACT_REDIST_IMAGE_ID=sha256:fake-lact-redist-v0.10.0"
expect_final_build_contains "nvidia-lact tag" "-t nvidia-lact-test:v0.10.0"
expect_no_from "nvidia-lact no --from"
if grep -qx -- 'ENV PATH=$PATH:/opt/nvidia/bin' "$repo_root/nvidia-lact.containerfile"; then
    ok "nvidia-lact containerfile: ENV PATH +/opt/nvidia/bin"
else
    ko "nvidia-lact containerfile: ENV PATH +/opt/nvidia/bin" "exact line in nvidia-lact.containerfile" "line not found"
fi

# --- 19. systemd (fake HOST_ROOT/SYSTEMDCTL: deploy layout, sysconfig content, enable list) ---
mkdir -p "$tmp/hostroot"
cat > "$tmp/fake-systemctl" <<'SH'
#!/bin/sh
echo "fake-systemctl $*" >> "${FAKE_LOG:?}"
SH
chmod +x "$tmp/fake-systemctl"

# local.mk: operator's file (if any) backed up, test stub written;
# restored by the EXIT trap
local_mk_backup="$tmp/local.mk.operator"
if [ -f "$repo_root/local.mk" ]; then
    local_mk_existed=1
    cp "$repo_root/local.mk" "$local_mk_backup"
else
    local_mk_existed=0
fi
printf 'LLAMA_HOST = 127.0.0.1\nLLM_NFS_SERVER = 127.0.0.1\n' > "$repo_root/local.mk"

make_target systemd HOST_ROOT="$tmp/hostroot" SYSTEMDCTL="$tmp/fake-systemctl"
expect_make_rc "systemd rc=0" 0

for pair in resources/driver/nvidia-kmod.service \
            resources/driver/nvidia-card-setting.service \
            resources/driver/lact-autoswitch.service \
            resources/llama/llama-cpp.service \
            resources/llama/llama-cpp-watcher.service ; do
    base=${pair##*/}
    if cmp -s "$repo_root/$pair" "$tmp/hostroot/etc/systemd/system/$base"; then
        ok "systemd deploy: $base"
    else
        ko "systemd deploy: $base" "identical to $pair" "differs"
    fi
done

# var-local-llm.mount: sed-substituted at deploy (not byte-identical to the repo file)
if grep -qx 'What=127.0.0.1:/mnt/sas/llm' "$tmp/hostroot/etc/systemd/system/var-local-llm.mount"; then
    ok "systemd deploy: var-local-llm.mount What substituted"
else
    ko "systemd deploy: var-local-llm.mount What substituted" "What=127.0.0.1:/mnt/sas/llm" "$(grep '^What=' "$tmp/hostroot/etc/systemd/system/var-local-llm.mount" 2>/dev/null)"
fi
if grep -q '@LLM_NFS_SERVER@' "$tmp/hostroot/etc/systemd/system/var-local-llm.mount"; then
    ko "systemd deploy: var-local-llm.mount no placeholder" "no @LLM_NFS_SERVER@" "$(grep -n '@LLM_NFS_SERVER@' "$tmp/hostroot/etc/systemd/system/var-local-llm.mount")"
else
    ok "systemd deploy: var-local-llm.mount no placeholder"
fi

# Stage-10/18 usr/local/bin scripts: content identical to the repo + mode 0755.
for pair in scripts/llama-cpp-watcher.sh \
            scripts/nvidia-kmod-select.sh ; do
    base=${pair##*/}
    dep="$tmp/hostroot/usr/local/bin/$base"
    if [ ! -f "$dep" ]; then
        ko "systemd deploy: $base" "copied to hostroot/usr/local/bin" "absent"
        continue
    fi
    if cmp -s "$repo_root/$pair" "$dep"; then
        ok "systemd deploy: $base"
    else
        ko "systemd deploy: $base" "identical to $pair" "differs"
    fi
    mode=$(stat -c %a "$dep")
    if [ "$mode" = "755" ]; then
        ok "systemd deploy: $base mode 755"
    else
        ko "systemd deploy: $base mode 755" "755" "$mode"
    fi
done

syscfg() { # desc file line
    if grep -qx -- "$3" "$2"; then
        ok "$1"
    else
        ko "$1" "line: $3" "file: $(cat "$2" 2>/dev/null)"
    fi
}
sys="$tmp/hostroot/etc/sysconfig"
syscfg "sysconfig nvidia-kmod KMOD_IMAGE" "$sys/nvidia-kmod" "KMOD_IMAGE=nvidia-kmod-test:test-kver"
syscfg "sysconfig card-setting LACT_IMAGE" "$sys/nvidia-card-setting" "LACT_IMAGE=nvidia-lact-test:v0.10.0"
syscfg "sysconfig card-setting PWR_LIMIT" "$sys/nvidia-card-setting" "PWR_LIMIT=140"
syscfg "sysconfig card-setting MEM_CLOCK_OFFSET" "$sys/nvidia-card-setting" "MEM_CLOCK_OFFSET=1000"
syscfg "sysconfig card-setting CORE_CLOCK_OFFSET" "$sys/nvidia-card-setting" "CORE_CLOCK_OFFSET=0"
syscfg "sysconfig card-setting FAN_MODE" "$sys/nvidia-card-setting" "FAN_MODE=curve"
syscfg "sysconfig card-setting FAN_CURVE" "$sys/nvidia-card-setting" "FAN_CURVE=45:0.30 65:0.40 70:0.65 75:0.80"
syscfg "sysconfig card-setting PER_CARD_OVERRIDES empty" "$sys/nvidia-card-setting" "PER_CARD_OVERRIDES="
syscfg "sysconfig card-setting SAFE_PL" "$sys/nvidia-card-setting" "SAFE_PL=120"
syscfg "sysconfig card-setting SAFE_FAN_STATIC" "$sys/nvidia-card-setting" "SAFE_FAN_STATIC=0.60"
syscfg "sysconfig card-setting SAFE_PM_MODE" "$sys/nvidia-card-setting" "SAFE_PM_MODE=Auto"
syscfg "sysconfig card-setting IDLE_PL" "$sys/nvidia-card-setting" "IDLE_PL=100"
syscfg "sysconfig card-setting IDLE_MEM_CLOCK" "$sys/nvidia-card-setting" "IDLE_MEM_CLOCK=405"
syscfg "sysconfig card-setting IDLE_PM_MODE" "$sys/nvidia-card-setting" "IDLE_PM_MODE=Auto"
syscfg "sysconfig card-setting LOCKED_CORE_CLOCK" "$sys/nvidia-card-setting" "LOCKED_CORE_CLOCK=2000"
syscfg "sysconfig card-setting LOCKED_MEM_CLOCK" "$sys/nvidia-card-setting" "LOCKED_MEM_CLOCK=8500"
syscfg "sysconfig card-setting LOCKED_MEM_OFFSET" "$sys/nvidia-card-setting" "LOCKED_MEM_OFFSET=2000"
syscfg "sysconfig card-setting LOCKED_PL" "$sys/nvidia-card-setting" "LOCKED_PL=140"
syscfg "sysconfig card-setting LOCKED_PM_MODE" "$sys/nvidia-card-setting" "LOCKED_PM_MODE=PreferMaximumPerformance"
syscfg "sysconfig lact-autoswitch LACT_AUTOSWITCH_IMAGE" "$sys/lact-autoswitch" "LACT_AUTOSWITCH_IMAGE=nvidia-lact-autoswitch-test:v0.10.0"
syscfg "sysconfig lact-autoswitch LLAMA_URL" "$sys/lact-autoswitch" "LLAMA_URL=http://127.0.0.1:8080"
syscfg "sysconfig lact-autoswitch LLAMA_MODEL" "$sys/lact-autoswitch" "LLAMA_MODEL=default"
syscfg "sysconfig lact-autoswitch LLAMA_KEYS_FILE" "$sys/lact-autoswitch" "LLAMA_KEYS_FILE=/etc/llama/llama-cpp-keys.txt"
syscfg "sysconfig lact-autoswitch KEY_MARKER" "$sys/lact-autoswitch" "KEY_MARKER=lact-autoswitch"
syscfg "sysconfig lact-autoswitch POLL_INTERVAL" "$sys/lact-autoswitch" "POLL_INTERVAL=5"
syscfg "sysconfig lact-autoswitch THERMAL_EVERY" "$sys/lact-autoswitch" "THERMAL_EVERY=3"
syscfg "sysconfig lact-autoswitch TIME_IDLE" "$sys/lact-autoswitch" "TIME_IDLE=120"
syscfg "sysconfig lact-autoswitch TIME_DOWN" "$sys/lact-autoswitch" "TIME_DOWN=300"
syscfg "sysconfig lact-autoswitch TEMP_SAFE" "$sys/lact-autoswitch" "TEMP_SAFE=82"
syscfg "sysconfig lact-autoswitch TIME_SAFE_DUR" "$sys/lact-autoswitch" "TIME_SAFE_DUR=300"
syscfg "sysconfig lact-autoswitch TEMP_SAFE_BACK_DELTA" "$sys/lact-autoswitch" "TEMP_SAFE_BACK_DELTA=4"
syscfg "sysconfig lact-autoswitch TIME_SAFE_BACK_DUR" "$sys/lact-autoswitch" "TIME_SAFE_BACK_DUR=300"
syscfg "sysconfig lact-autoswitch TIME_DOWN_LACT" "$sys/lact-autoswitch" "TIME_DOWN_LACT=60"
syscfg "sysconfig lact-autoswitch FALLBACK_PL" "$sys/lact-autoswitch" "FALLBACK_PL=120"
syscfg "sysconfig lact-autoswitch HISTORY_LINES" "$sys/lact-autoswitch" "HISTORY_LINES=2000"
syscfg "sysconfig llama-cpp LLAMA_IMAGE" "$sys/llama-cpp" "LLAMA_IMAGE=llama-cpp-cuda:test"
syscfg "sysconfig llama-cpp LLAMA_LOG_TIMESTAMPS" "$sys/llama-cpp" "LLAMA_LOG_TIMESTAMPS=1"
syscfg "sysconfig llama-cpp LLAMA_PORT" "$sys/llama-cpp" "LLAMA_PORT=8080"
syscfg "sysconfig llama-cpp LLAMA_SHM_SIZE" "$sys/llama-cpp" "LLAMA_SHM_SIZE=64g"

expect_log_contains "systemd: daemon-reload" "fake-systemctl daemon-reload"
expect_log_contains "systemd: enable prod stack" "fake-systemctl enable nvidia-kmod.service nvidia-card-setting.service llama-cpp.service var-local-llm.mount lact-autoswitch.service"
if grep -q "pydorok" "$log"; then
    ko "systemd: pydorok not enabled" "no pydorok in systemctl calls" "$(grep -n pydorok "$log")"
else
    ok "systemd: pydorok not enabled"
fi

# fail-loud: no local.mk -> make systemd refuses before touching HOST_ROOT
rm -f "$repo_root/local.mk"
make_target systemd HOST_ROOT="$tmp/hostroot-fail" SYSTEMDCTL="$tmp/fake-systemctl"
expect_make_rc "systemd fail-loud rc=2 (no local.mk)" 2
if [ -e "$tmp/hostroot-fail" ]; then
    ko "systemd fail-loud: HOST_ROOT untouched" "no $tmp/hostroot-fail" "exists (created before refusal)"
else
    ok "systemd fail-loud: HOST_ROOT untouched"
fi
# the fail-loud echo lands in make's stderr (make_out), not in the fake-logged $log
if printf '%s' "$make_out" | grep -qF -- "ERROR: no local.mk"; then
    ok "systemd fail-loud message"
else
    ko "systemd fail-loud message" "make output contains: ERROR: no local.mk" "make out: $make_out"
fi
printf 'LLAMA_HOST = 127.0.0.1\nLLM_NFS_SERVER = 127.0.0.1\n' > "$repo_root/local.mk"

# --- 20. nvidia-lact-autoswitch (edge nvidia-lact-autoswitch -> nvidia-lact) ---
make_target nvidia-lact-autoswitch LACT_URL="$lact_url"
expect_make_rc "nvidia-lact-autoswitch rc=0" 0
expect_sequence "nvidia-lact-autoswitch sequence" "nvidia-base.containerfile nvidia-redist-drv.containerfile lact-redist.containerfile nvidia-lact.containerfile nvidia-lact-autoswitch.containerfile"
expect_final_build_contains "nvidia-lact-autoswitch LACT_IMAGE" "--build-arg LACT_IMAGE=nvidia-lact-test:v0.10.0"
expect_final_build_contains "nvidia-lact-autoswitch tag" "-t nvidia-lact-autoswitch-test:v0.10.0"
expect_no_from "nvidia-lact-autoswitch no --from"

# --- 21a. Makefile recipe indent convention ---
bad_cont=$(awk '
    prev ~ /\\[ \t]*$/ {
        if ($0 ~ /^[ \t]/ && $0 !~ /^\t  [^ \t]/) { print FILENAME ":" FNR ": " $0 }
    }
    { prev = $0 }
' "$repo_root/Makefile")
if [ -z "$bad_cont" ]; then
    ok "Makefile: continuation lines TAB+2sp"
else
    ko "Makefile: continuation lines TAB+2sp" "continuation = TAB + 2 spaces" "$bad_cont"
fi
bad_start=$(awk '
    prev !~ /\\[ \t]*$/ {
        if ($0 ~ /^\t[ \t]/) { print FILENAME ":" FNR ": " $0 }
    }
    { prev = $0 }
' "$repo_root/Makefile")
if [ -z "$bad_start" ]; then
    ok "Makefile: command lines start with single TAB"
else
    ko "Makefile: command lines start with single TAB" "no TAB+whitespace command starts" "$bad_start"
fi

# --- 21. dead commented targets and containerfiles removed ---
if grep -qE '^#(torch|jupyter|text-gen-webui):' "$repo_root/Makefile"; then
    ko "Makefile: no dead commented targets" "no '#torch:'/'#jupyter:'/'#text-gen-webui:' lines" "$(grep -nE '^#(torch|jupyter|text-gen-webui):' "$repo_root/Makefile")"
else
    ok "Makefile: no dead commented targets"
fi
if [ -e "$repo_root/torch.containerfile" ] || [ -e "$repo_root/jupyter.containerfile" ]; then
    ko "dead containerfiles removed" "torch.containerfile and jupyter.containerfile absent" "present"
else
    ok "dead containerfiles removed"
fi

# --- 22. kernel-check.sh (direct invocation, fake koji layout) ---
kc() { # kernel-check.sh "$@"; sets kc_out/kc_rc; CRE via KC_CRE (default $tmp/cre)
    kc_rc=0
    kc_out=$(CRE=${KC_CRE:-$tmp/cre} "$repo_root/scripts/kernel-check.sh" "$@" 2>/dev/null) || kc_rc=$?
}

kc kernel-redist:test http://127.0.0.1:1 "$kver_test"
if [ "$kc_rc" -eq 2 ]; then
    ok "kernel-check: unreachable base rc=2"
else
    ko "kernel-check: unreachable base rc=2" "rc=2" "rc=$kc_rc out=$kc_out"
fi

kc kernel-redist:test "$koji_url" 8.0.0-100.fc44.x86_64
if [ "$kc_rc" -eq 2 ]; then
    ok "kernel-check: no headers series (empty candidates) rc=2"
else
    ko "kernel-check: no headers series (empty candidates) rc=2" "rc=2" "rc=$kc_rc out=$kc_out"
fi

kc kernel-redist:test "$koji_url" "$kver_test"
if [ "$kc_rc" -ne 0 ]; then
    ko "kernel-check: rebuild rc=0" "rc=0" "rc=$kc_rc out=$kc_out"
else
    ok "kernel-check: rebuild rc=0"
fi
set -- $kc_out
if [ "$#" -eq 13 ] && [ "${1:-}" = "rebuild" ]; then
    ok "kernel-check: rebuild 12 values"
else
    ko "kernel-check: rebuild 12 values" "'rebuild' + 12 single-token values" "words=$#: $kc_out"
fi
core_url_t=${2:-}; core_size_t=${3:-}; core_mtime_t=${4:-}
modcore_url_t=${5:-}; modcore_size_t=${6:-}; modcore_mtime_t=${7:-}
devel_url_t=${8:-}; devel_size_t=${9:-}; devel_mtime_t=${10:-}
headers_url_t=${11:-}; headers_size_t=${12:-}; headers_mtime_t=${13:-}

kf() { # desc actual expected
    if [ "$2" = "$3" ]; then
        ok "kernel-check: $1"
    else
        ko "kernel-check: $1" "$3" "$2"
    fi
}
kf "CORE_URL" "$core_url_t" "$koji_url/packages/kernel/7.1.4/200.fc44/x86_64/kernel-core-$kver_test.rpm"
kf "CORE_SIZE" "$core_size_t" "5"
kf "MODCORE_URL" "$modcore_url_t" "$koji_url/packages/kernel/7.1.4/200.fc44/x86_64/kernel-modules-core-$kver_test.rpm"
kf "MODCORE_SIZE" "$modcore_size_t" "8"
kf "DEVEL_URL" "$devel_url_t" "$koji_url/packages/kernel/7.1.4/200.fc44/x86_64/kernel-devel-$kver_test.rpm"
kf "DEVEL_SIZE" "$devel_size_t" "6"
kf "HEADERS_URL (fallback: series, fcNN, <= kver)" "$headers_url_t" "$koji_url/packages/kernel-headers/7.1.3/200.fc44/x86_64/kernel-headers-7.1.3-200.fc44.x86_64.rpm"
kf "HEADERS_SIZE" "$headers_size_t" "4"
for e in "$core_mtime_t" "$modcore_mtime_t" "$devel_mtime_t" "$headers_mtime_t"; do
    case $e in
        ''|*[!0-9]*) ko "kernel-check: mtime is epoch seconds" "digits" "$e" ;;
        *) ok "kernel-check: mtime is epoch seconds" ;;
    esac
done

kc --force kernel-redist:test "$koji_url" "$kver_test"
set -- $kc_out
if [ "$kc_rc" -eq 0 ] && [ "${1:-}" = "rebuild" ] && [ "$#" -eq 13 ]; then
    ok "kernel-check: --force always rebuild"
else
    ko "kernel-check: --force always rebuild" "rc=0, rebuild + 12 values" "rc=$kc_rc out=$kc_out"
fi

{
    echo "com.llm-rig/kernel.redist.core.url=$core_url_t"
    echo "com.llm-rig/kernel.redist.core.size=$core_size_t"
    echo "com.llm-rig/kernel.redist.core.mtime=$core_mtime_t"
    echo "com.llm-rig/kernel.redist.modules-core.url=$modcore_url_t"
    echo "com.llm-rig/kernel.redist.modules-core.size=$modcore_size_t"
    echo "com.llm-rig/kernel.redist.modules-core.mtime=$modcore_mtime_t"
    echo "com.llm-rig/kernel.redist.devel.url=$devel_url_t"
    echo "com.llm-rig/kernel.redist.devel.size=$devel_size_t"
    echo "com.llm-rig/kernel.redist.devel.mtime=$devel_mtime_t"
    echo "com.llm-rig/kernel.redist.headers.url=$headers_url_t"
    echo "com.llm-rig/kernel.redist.headers.size=$headers_size_t"
    echo "com.llm-rig/kernel.redist.headers.mtime=$headers_mtime_t"
} > "$tmp/labels"

KC_CRE=$tmp/cre-labeled
FAKE_LABELS="$tmp/labels"
export FAKE_LABELS
kc kernel-redist:test "$koji_url" "$kver_test"
if [ "$kc_rc" -eq 0 ] && [ "$kc_out" = "up-to-date" ]; then
    ok "kernel-check: labels match -> up-to-date"
else
    ko "kernel-check: labels match -> up-to-date" "up-to-date" "rc=$kc_rc out=$kc_out"
fi

sed 's/^com.llm-rig\/kernel.redist.core.size=.*/com.llm-rig\/kernel.redist.core.size=999/' \
    "$tmp/labels" > "$tmp/labels-bad"
FAKE_LABELS="$tmp/labels-bad"
kc kernel-redist:test "$koji_url" "$kver_test"
set -- $kc_out
if [ "$kc_rc" -eq 0 ] && [ "${1:-}" = "rebuild" ] && [ "$#" -eq 13 ]; then
    ok "kernel-check: labels differ -> rebuild"
else
    ko "kernel-check: labels differ -> rebuild" "rc=0, rebuild + 12 values" "rc=$kc_rc out=$kc_out"
fi

# --- 23. kernel-redist (make: fake koji layout; headers fallback / exact / unreachable) ---
make_target kernel-redist KVER=$kver_test
expect_make_rc "kernel-redist rc=0" 0
expect_sequence "kernel-redist sequence" "kernel-redist.containerfile"
expect_final_build_contains "kernel-redist KVER" "--build-arg KVER=$kver_test"
expect_final_build_contains "kernel-redist CORE_URL" "--build-arg CORE_URL=$koji_url/packages/kernel/7.1.4/200.fc44/x86_64/kernel-core-$kver_test.rpm"
expect_final_build_contains "kernel-redist MODCORE_URL" "--build-arg MODCORE_URL=$koji_url/packages/kernel/7.1.4/200.fc44/x86_64/kernel-modules-core-$kver_test.rpm"
expect_final_build_contains "kernel-redist DEVEL_URL" "--build-arg DEVEL_URL=$koji_url/packages/kernel/7.1.4/200.fc44/x86_64/kernel-devel-$kver_test.rpm"
expect_final_build_contains "kernel-redist HEADERS_URL (fallback <=)" "--build-arg HEADERS_URL=$koji_url/packages/kernel-headers/7.1.3/200.fc44/x86_64/kernel-headers-7.1.3-200.fc44.x86_64.rpm"
expect_final_build_contains "kernel-redist tag" "-t kernel-redist:$kver_test"

mkdir -p "$tmp/koji/packages/kernel-headers/7.1.4/200.fc44/x86_64"
printf 'h44new\n' > "$tmp/koji/packages/kernel-headers/7.1.4/200.fc44/x86_64/kernel-headers-7.1.4-200.fc44.x86_64.rpm"
make_target kernel-redist KVER=$kver_test
expect_make_rc "kernel-redist (exact headers) rc=0" 0
expect_final_build_contains "kernel-redist HEADERS_URL (exact)" "--build-arg HEADERS_URL=$koji_url/packages/kernel-headers/7.1.4/200.fc44/x86_64/kernel-headers-7.1.4-200.fc44.x86_64.rpm"

make_target kernel-redist KVER=$kver_test KOJI_BASE_URL=http://127.0.0.1:1
expect_make_rc "kernel-redist (unreachable) rc=2" 2

make_target kernel-redist KVER=$kver_test KOJI_BASE_URL=http://127.0.0.1:1 FORCE=1
expect_make_rc "kernel-redist (unreachable, FORCE) rc=2" 2

# --- 24. llama-cpp-restart (recipe plumbing; setsid stubbed — скрипт не запускается) ---
mkdir -p "$tmp/setsid-stub"
cat > "$tmp/setsid-stub/setsid" <<'SH'
#!/bin/sh
echo "stub-setsid $*" >> "${FAKE_SETSID_LOG:?}"
exit 0
SH
chmod +x "$tmp/setsid-stub/setsid"
FAKE_SETSID_LOG="$tmp/setsid.log"
export FAKE_SETSID_LOG
: > "$FAKE_SETSID_LOG"

PATH="$tmp/setsid-stub:$PATH" make_target llama-cpp-restart MODE=check \
    HOST_ROOT="$tmp/hostroot" SYSTEMDCTL="$tmp/fake-systemctl" RESTART_LOG="$tmp/restart.log"
expect_make_rc "llama-cpp-restart rc=0" 0
for frag in \
    'stub-setsid -f env CRE=' \
    "HOST_ROOT=$tmp/hostroot" \
    "SYSTEMDCTL=$tmp/fake-systemctl" \
    'LLAMA_URL=http://127.0.0.1:8080' \
    'LLAMA_MODEL=default' \
    'LLAMA_KEYS_FILE=/etc/llama/llama-cpp-keys.txt' \
    'LLAMA_CONTAINER=llama-cpp' \
    'OPENCODE_CONFIG= ./scripts/llama-cpp-restart.sh check --idle-timeout 30 --ready-timeout 600' ; do
    if grep -qF -- "$frag" "$FAKE_SETSID_LOG"; then
        ok "llama-cpp-restart recipe: $frag"
    else
        ko "llama-cpp-restart recipe: $frag" "in stub-setsid log" "$(cat "$FAKE_SETSID_LOG")"
    fi
done
if printf '%s' "$make_out" | grep -qF "llama-cpp-restart: started (log=$tmp/restart.log"; then
    ok "llama-cpp-restart: started-echo"
else
    ko "llama-cpp-restart: started-echo" "echo with RESTART_LOG" "make out: $make_out"
fi

# fail-loud: no local.mk -> отказ до setsid
rm -f "$repo_root/local.mk"
: > "$FAKE_SETSID_LOG"
PATH="$tmp/setsid-stub:$PATH" make_target llama-cpp-restart MODE=check \
    HOST_ROOT="$tmp/hostroot" SYSTEMDCTL="$tmp/fake-systemctl" RESTART_LOG="$tmp/restart.log"
expect_make_rc "llama-cpp-restart fail-loud rc=2 (no local.mk)" 2
if printf '%s' "$make_out" | grep -qF -- "ERROR: no local.mk"; then
    ok "llama-cpp-restart fail-loud message"
else
    ko "llama-cpp-restart fail-loud message" "make output contains: ERROR: no local.mk" "make out: $make_out"
fi
if [ -s "$FAKE_SETSID_LOG" ]; then
    ko "llama-cpp-restart fail-loud: setsid not run" "empty stub log" "$(cat "$FAKE_SETSID_LOG")"
else
    ok "llama-cpp-restart fail-loud: setsid not run"
fi
printf 'LLAMA_HOST = 127.0.0.1\nLLM_NFS_SERVER = 127.0.0.1\n' > "$repo_root/local.mk"

echo "# pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
