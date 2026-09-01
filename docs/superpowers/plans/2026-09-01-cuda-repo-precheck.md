# CUDA Repo Precheck (Этап 24) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Верифицировать 10 фактов спеки пре-чека (группы A–D) и
зафиксировать их в отчёте с заполненной таблицей решений. Без TDD:
результат — только отчёт; изменений сборки репозитория нет.

**Architecture:** Всё из toolbx через CRE (podman-remote). Стеджинг —
`/run/host/tmp/cuda-precheck` (на хосте `/tmp/cuda-precheck`).
Throwaway-образы: `cuda-precheck-devel:tmp` (nvidia-base:44 + NVIDIA-
репо + devel-набор + build-инструменты), `cuda-precheck-devel-weak:tmp`
(то же, weakdeps on — дельта), `cuda-precheck-libs:tmp` (nvidia-base:44
+ NVIDIA-репо + runtime-набор + driver userspace из
`nvidia-xorg:610.43.03`), `cuda-precheck-nccl:tmp` (devel + NCCL-
артефакты). GPU-проба (Task 3) — один маленький CUDA-запуск,
`--privileged` + `/dev/nvidia0` (паттерн `llama-cpp.service`), без
изменения состояния GPU/OC/драйвера.

**Tech Stack:** podman/podman-remote, fedora-minimal:44 (dnf5), NVIDIA
fedora44 dnf-репо (CUDA 13.3.1; driver-пакеты репо НЕ ставим), NCCL
v2.31.2-1, llama.cpp master (HEAD на момент исполнения), gcc15 / gcc16
(F44).

**Spec:** `docs/superpowers/specs/2026-09-01-cuda-repo-precheck.md`

## Global Constraints

- **CRE** по правилу `no-cre-hardcode`:
  `CRE=podman; [ -f /run/.containerenv ] && CRE=podman-remote`. В любых
  командах плана — только `$CRE`, никогда литерал.
- **rm-rf-guard:** зачистка стеджа — литеральный путь
  `/run/host/tmp/cuda-precheck` (допустимо без safe-rm).
- **english-commits:** сообщения коммитов — на английском.
- **Изменения репозитория** — только
  `docs/superpowers/reports/2026-09-01-cuda-repo-precheck.md`
  (создаётся/дополняется) и (только Task 6) `TODO.md`. Makefile /
  containerfiles / scripts / resources не трогаются.
- **Throwaway:** образы `cuda-precheck-*:tmp` и стедж — одноразовые, в
  сборку не входят; cleanup — Task 6.
- **GPU-проба** ненагружающая: один маленький запуск (Task 3); влияние
  на идущую генерацию — мигновено, фиксируется в отчёте.
- Известные факты на момент плана (01.09.2026, верифицировано в
  брейншторме, read-only):
  - репо содержит только CUDA **13.3.0/13.3.1**; driver-пакеты —
    610.43.02 / 610.57.04 (не ставятся); GPG key `73CD9B30.pub`,
    `gpgcheck=1`; repo-файл `cuda-fedora44.repo`;
  - F44: дефолтный gcc = **16** (16.2.1-2.fc44, updates), gcc15 =
    15.3.1-1.fc44;
  - кандидаты NEVRA (по листингу репо):
    - devel-набор: `cuda-minimal-build-13-3-13.3.1-1.x86_64`,
      `libcublas-devel-13-3-13.6.0.2-1.x86_64`,
      `libcufft-devel-13-3-12.3.0.29-1.x86_64`,
      `libcurand-devel-13-3-10.4.3.29-1.x86_64`,
      `libcusolver-devel-13-3-12.2.6.9-1.x86_64`,
      `libcusparse-devel-13-3-12.8.2.51-1.x86_64`,
      `libnvjitlink-devel-13-3-13.3.33-1.x86_64`;
    - runtime-набор: `cuda-cudart-13-3-13.3.29-1.x86_64`,
      `libcublas-13-3-13.6.0.2-1.x86_64`,
      `libcufft-13-3-12.3.0.29-1.x86_64`,
      `libcurand-13-3-10.4.3.29-1.x86_64`,
      `libcusolver-13-3-12.2.6.9-1.x86_64`,
      `libcusparse-13-3-12.8.2.51-1.x86_64`,
      `libnvjitlink-13-3-13.3.33-1.x86_64`,
      `libnvfatbin-13-3-13.3.29-1.x86_64`.
  Task 1 фиксирует итоговый список (репо мог измениться).

## File Structure

- Create: `docs/superpowers/reports/2026-09-01-cuda-repo-precheck.md` —
  отчёт: создаётся в Task 1 (шапка + §1), дополняется Task 2–5
  (§2–§5), финализируется Task 6 (таблица решений, риски, cleanup).
- Modify: `TODO.md` — только Task 6 (чекбокс пре-чека).
- Throwaway (вне репозитория, на хосте): `/run/host/tmp/cuda-precheck/`
  — containerfiles, hello.cu, клоны NCCL/llama, логи, снимки.

---

### Task 1: Состояние репо — NEVRA-инвентаризация + метаданные (без сборки)

**Files:**
- Create: `docs/superpowers/reports/2026-09-01-cuda-repo-precheck.md`

**Interfaces:**
- Consumes: ничего (первая задача).
- Produces: итоговый список NEVRA (devel + runtime) с размерами/датами,
  содержимое `cuda-fedora44.repo`, GPG key ID, факт о
  driver-пакетах репо — в §1 отчёта; Tasks 2–5 берут NEVRA оттуда.

- [ ] **Step 1: Стеджинг**

```bash
mkdir -p /run/host/tmp/cuda-precheck
```

- [ ] **Step 2: Метаданные репо**

```bash
S=/run/host/tmp/cuda-precheck
curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/fedora44/x86_64/ \
  -o $S/repo-index.html
curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/fedora44/x86_64/cuda-fedora44.repo \
  -o $S/cuda-fedora44.repo
curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/fedora44/x86_64/73CD9B30.pub \
  -o $S/nvidia-gpg.asc
cat $S/cuda-fedora44.repo
gpg --show-keys $S/nvidia-gpg.asc 2>/dev/null | head -5
```

Expected: содержимое .repo (baseurl + gpgkey), GPG key ID в выводе.

- [ ] **Step 3: NEVRA-инвентаризация**

```bash
S=/run/host/tmp/cuda-precheck
python3 - "$S/repo-index.html" > $S/nevra-inventory.txt <<'EOF'
import re, sys, html
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
rows = re.findall(r'<a href="([^"]+\.rpm)">[^<]*</a>\s*<[^>]*>([\d.]+[KMGT]B)</a>\s*<[^>]*>([^<]+)</a>', text, re.S)
keep = []
for name, size, date in rows:
    if re.match(r'^(cuda-|libcu|libcublas|libcufft|libcurand|libcusolver|libcusparse|libnpp|libnv|cccl|nvjitlink)', name):
        keep.append(f"{name}  {size}  {date}")
    elif re.match(r'^nvidia-driver-6', name):
        keep.append(f"{name}  {size}  {date}   # driver pkg (NOT installed)")
print("\n".join(sorted(keep)))
EOF
cat $S/nevra-inventory.txt
```

Expected: все 15 NEVRA-кандидатов из Global Constraints присутствуют
(размер/дата зафиксированы); driver-пакеты — с пометкой. Если NEVRA
из кандидатов отсутствует/имеет другую версию — факт в §1, список
Tasks 2–5 корректируется по инвентаризации.

- [ ] **Step 4: Отчёт — шапка + §1**

Создать `docs/superpowers/reports/2026-09-01-cuda-repo-precheck.md`:

```markdown
# Пре-чек: CUDA toolkit через NVIDIA fedora44 dnf-репо (Этап 24)

- Дата: 01.09.2026 (дополняется по ходу)
- Статус: в работе → завершён (обновить в Task 6)
- Спека: `docs/superpowers/specs/2026-09-01-cuda-repo-precheck.md`

## 1. Состояние репо

- Repo-файл: <цитата cuda-fedora44.repo>
- GPG: key ID <...> (73CD9B30.pub)
- CUDA-версии в репо: 13.3.0 / 13.3.1 (13.2 — отсутствует)
- Driver-пакеты в репо: 610.43.02 / 610.57.04 (не ставятся)
- NEVRA devel-набора: <список из nevra-inventory.txt с размерами/датами>
- NEVRA runtime-набора: <аналогично>
```

Заполнить из фактов Steps 2–3 (сырые файлы в стедже; в отчёт —
выжимка).

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/reports/2026-09-01-cuda-repo-precheck.md
git commit -m "docs: stage 24 precheck report - repo state (CUDA 13.3.1 NEVRA inventory, repo file, gpg key)"
```

---

### Task 2: Devel-образ + механика dnf5 (пп.1–5 спеки)

**Files:**
- Modify: `docs/superpowers/reports/2026-09-01-cuda-repo-precheck.md`
  (добавить §2)

**Interfaces:**
- Consumes: из §1 — итоговые NEVRA devel-набора.
- Produces: образы `cuda-precheck-devel:tmp` (weakdeps off) и
  `cuda-precheck-devel-weak:tmp` (weakdeps on); факты: репо+GPG на dnf5,
  установка точного NEVRA, режим отказа на несуществующий NEVRA,
  размещение файлов, ldconfig, размеры (оба варианта) — в §2.
  Tasks 3–5 используют `cuda-precheck-devel:tmp`.

- [ ] **Step 1: Containerfile devel-образа (стедж)**

```bash
S=/run/host/tmp/cuda-precheck
cat > $S/cuda-precheck-devel.containerfile <<'EOF'
FROM nvidia-base:44
RUN set -euxo pipefail ; \
  curl -fsSL \
    https://developer.download.nvidia.com/compute/cuda/repos/fedora44/x86_64/cuda-fedora44.repo \
    -o /etc/yum.repos.d/cuda-fedora44.repo ; \
  dnf makecache
RUN dnf -y --setopt=install_weak_deps=False \
  install \
    gcc15{,-c++} make python3 git which cmake ninja-build \
    <DEVEL_NEVRA...> \
  && dnf clean all
EOF
```

`<DEVEL_NEVRA...>` — из §1 (каждый NEVRA отдельной строкой в RUN;
соблюдать правило `no-inline-comments`: без завершающих комментариев в
containerfile). Аналогично `cuda-precheck-devel-weak.containerfile` —
тот же, но без `--setopt=install_weak_deps=False`.

- [ ] **Step 2: Сборка обоих образов**

```bash
CRE=podman; [ -f /run/.containerenv ] && CRE=podman-remote
S=/run/host/tmp/cuda-precheck
$CRE build -f $S/cuda-precheck-devel.containerfile -t cuda-precheck-devel:tmp $S 2>&1 | tee $S/build-devel.log
$CRE build -f $S/cuda-precheck-devel-weak.containerfile -t cuda-precheck-devel-weak:tmp $S 2>&1 | tee $S/build-devel-weak.log
grep -E "^(Installed|Downloading|Importing)" $S/build-devel.log
```

Expected: обе сборки успешны; в логах — dnf-списки установленных
пакетов (с ними дельта weakdeps, Step 5). Aномалия (GPG-ошибка,
недоступный NEVRA) — факт в §2 + сообщить координатору.

- [ ] **Step 3: Факты репо+GPG, NEVRA, режим отказа**

```bash
CRE=podman; [ -f /run/.containerenv ] && CRE=podman-remote
$CRE run --rm cuda-precheck-devel:tmp bash -c '
  echo "=== repolist ==="; dnf repolist
  echo "=== installed cuda pkgs ==="; rpm -qa | grep -Ei "cuda|libcublas|libcufft|libcurand|libcusolver|libcusparse|libnvjitlink|libnvfatbin|cccl" | sort
  echo "=== bad NEVRA (expect fail-loud) ==="
  dnf install -y cuda-nvcc-13-3-0.0.0-1.x86_64.rpm; echo "exit=$?"
' 2>&1 | tee /run/host/tmp/cuda-precheck/probe-repo.txt
```

Expected: repolist показывает cuda-fedora44-x86_64 (enabled, GPG OK);
список = ровно devel-набор + инструменты (weakdeps off); bad NEVRA —
ошибка dnf с ненулевым exit (зафиксировать текст + код).

- [ ] **Step 4: Размещение файлов + ldconfig**

```bash
CRE=podman; [ -f /run/.containerenv ] && CRE=podman-remote
$CRE run --rm cuda-precheck-devel:tmp bash -c '
  set -e
  echo "=== rpm -ql key pkgs (trimmed) ==="
  for p in cuda-nvcc cuda-cudart cuda-cudart-devel libcublas libcublas-devel libnvjitlink cccl cuda-culibos-devel; do
    echo "--- $p"; rpm -ql $p 2>/dev/null | grep -E "^/(usr|opt)" | head -8
  done
  echo "=== /usr/local/cuda* ==="; ls -la /usr/local/ | grep -i cuda
  echo "=== /etc/ld.so.conf.d ==="; ls /etc/ld.so.conf.d/
  echo "=== ldconfig -p (key libs) ==="
  ldconfig -p | grep -E "libcudart|libcublas|libcufft|libcurand|libcusolver|libcusparse|libnvJitLink|libnvfatbin" || echo "NONE"
' 2>&1 | tee /run/host/tmp/cuda-precheck/probe-placement.txt
```

Expected: пути nvcc/cudart/lib'ей (какие в `/usr/lib64`, какие в
`/usr/local/cuda-13.3/…`); наличие/отсутствие symlink `/usr/local/cuda`;
что резолвится через ldconfig и из каких каталогов.

- [ ] **Step 5: Размеры + weakdeps-дельта**

```bash
CRE=podman; [ -f /run/.containerenv ] && CRE=podman-remote
S=/run/host/tmp/cuda-precheck
$CRE run --rm cuda-precheck-devel:tmp bash -c '
  echo "=== set sizes (installed) ==="
  rpm -qa --queryformat "%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH} %{SIZE}\n" \
    | grep -Ei "cuda|libcublas|libcufft|libcurand|libcusolver|libcusparse|libnvjitlink|libnvfatbin|cccl" | sort
  echo "=== dir sizes ==="; du -sh /usr/local/cuda-13.3 2>/dev/null; du -sh /usr/lib64
' | tee $S/probe-sizes.txt
# weakdeps-дельта: сравнить списки "Installed" из build-логов
diff <(grep -A100 "^Installed" $S/build-devel.log | sort) \
     <(grep -A100 "^Installed" $S/build-devel-weak.log | sort) | tee $S/weakdeps-delta.txt || true
$CRE run --rm cuda-precheck-devel-weak:tmp bash -c 'rpm -qa --queryformat "%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH} %{SIZE}\n" | sort' > $S/weak-qa.txt
$CRE run --rm cuda-precheck-devel:tmp bash -c 'rpm -qa --queryformat "%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH} %{SIZE}\n" | sort' > $S/noweak-qa.txt
diff $S/noweak-qa.txt $S/weak-qa.txt | tee $S/weakdeps-qa-delta.txt || true
```

Expected: размер devel-набора (weakdeps off) + полный список дельты
weakdeps (пакеты + размер).

- [ ] **Step 6: Отчёт §2**

Добавить в отчёт:

```markdown
## 2. dnf5 × репо, механика установки (pp.1–5)

- Репо+GPG (п.1): <repolist, импорт ключа, транзакция — OK/не OK>
- NEVRA-пин (п.2): установка по точному NEVRA — OK; несуществующий NEVRA — <текст ошибки, exit code>
- weakdeps (п.3): валиден; дельта = <список пакетов, суммарный размер>
- Размещение (п.4): nvcc → <путь>; libcudart/libnvJitLink → <каталоги>; /usr/local/cuda symlink: есть/нет; ld.so.conf.d: <содержимое>; ldconfig: <что резолвится, из каких каталогов>
- Размеры (п.5): devel-набор (weakdeps off) = <размер>; +weakdeps = <размер>
```

- [ ] **Step 7: Commit**

```bash
git add docs/superpowers/reports/2026-09-01-cuda-repo-precheck.md
git commit -m "docs: stage 24 precheck report - dnf5 x nvidia repo mechanics (gpg, nevra pins, weakdeps delta, file placement, sizes)"
```

---

### Task 3: hello-cuda на GPU — достаточность runtime-набора (п.6)

**Files:**
- Modify: `docs/superpowers/reports/2026-09-01-cuda-repo-precheck.md`
  (добавить §3)

**Interfaces:**
- Consumes: `cuda-precheck-devel:tmp` (nvcc 13.3.1, Task 2),
  `nvidia-xorg:610.43.03` (driver userspace), NEVRA runtime-набора из §1.
- Produces: `cuda-precheck-libs:tmp`; факт: достаточен ли runtime-набор
  из 8 пакетов для реального CUDA-программы (или список
  дополняющих пакетов) — в §3.

- [ ] **Step 1: hello.cu (стедж)**

```bash
S=/run/host/tmp/cuda-precheck
cat > $S/hello.cu <<'EOF'
#include <cstdio>
#include <cstdlib>
__global__ void add(const float* a, const float* b, float* c, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) c[i] = a[i] + b[i];
}
int main() {
    const int n = 1024;
    float *a, *b, *c;
    cudaMallocManaged(&a, n * sizeof(float));
    cudaMallocManaged(&b, n * sizeof(float));
    cudaMallocManaged(&c, n * sizeof(float));
    for (int i = 0; i < n; i++) { a[i] = i; b[i] = 2.0f * i; }
    add<<<n / 256, 256>>>(a, b, c, n);
    cudaDeviceSynchronize();
    float expect = 0;
    for (int i = 0; i < n; i++) expect += 3.0f * i;
    float got = 0;
    for (int i = 0; i < n; i++) got += c[i];
    printf("sum got=%.1f expect=%.1f\n", got, expect);
    return (got == expect) ? 0 : 1;
}
EOF
```

- [ ] **Step 2: Компиляция (devel-образ)**

```bash
CRE=podman; [ -f /run/.containerenv ] && CRE=podman-remote
S=/run/host/tmp/cuda-precheck
$CRE run --rm -v /tmp/cuda-precheck:/s:z cuda-precheck-devel:tmp \
  bash -c '/usr/local/cuda/bin/nvcc -ccbin g++-15 -arch=sm_86 -o /s/hello /s/hello.cu'
file $S/hello
```

Expected: бинарник собран (nvcc 13.3.1, host g++15 — как в
прод-цепи). Запуск без GPU в этом шаге не нужен (только сборка).

- [ ] **Step 3: Runtime-образ (libs)**

Containerfile в стедже — зеркалит прод-цепь (копирует driver userspace
из `nvidia-xorg` тем же набором путей, что
`nvidia-cuda-devel.containerfile`):

```bash
S=/run/host/tmp/cuda-precheck
cat > $S/cuda-precheck-libs.containerfile <<'EOF'
FROM nvidia-xorg:610.43.03 as drv
FROM nvidia-base:44
COPY hello /hello
RUN set -euxo pipefail ; \
  curl -fsSL \
    https://developer.download.nvidia.com/compute/cuda/repos/fedora44/x86_64/cuda-fedora44.repo \
    -o /etc/yum.repos.d/cuda-fedora44.repo ; \
  dnf -y --setopt=install_weak_deps=False install <RUNTIME_NEVRA...> && dnf clean all
RUN --mount=type=bind,from=drv,source=/,target=/mnt/drv-libs \
  set -euxo pipefail ; \
  cp -arv /mnt/drv-libs/opt/nvidia/ /opt/nvidia/ && \
  cp -av /mnt/drv-libs/usr/lib64/libcuda* /usr/lib64/ && \
  cp -av /mnt/drv-libs/usr/lib64/libnvidia* /usr/lib64/ && \
  ln -s /opt/nvidia/10_local.conf /etc/ld.so.conf.d/ && \
  ldconfig
EOF
CRE=podman; [ -f /run/.containerenv ] && CRE=podman-remote
$CRE build -f $S/cuda-precheck-libs.containerfile -t cuda-precheck-libs:tmp $S 2>&1 | tee $S/build-libs.log
```

`<RUNTIME_NEVRA...>` — 8 NEVRA из §1. Expected: сборка успешна.

- [ ] **Step 4: Запуск на GPU (ненагружающая проба)**

```bash
CRE=podman; [ -f /run/.containerenv ] && CRE=podman-remote
$CRE run --rm --privileged --device /dev/nvidia0 cuda-precheck-libs:tmp /hello
echo "exit=$?"
$CRE run --rm cuda-precheck-libs:tmp ldd /hello
```

Expected: `sum got=... expect=...` (совпадение), exit 0; `ldd` — всё
резолвится. При неудаче: `ldd | grep "not found"` → список
недостающих lib → факт в §3 (какие пакеты добавить в runtime-набор).

- [ ] **Step 5: Отчёт §3**

```markdown
## 3. hello-cuda на GPU (п.6)

- Компиляция: nvcc 13.3.1, -ccbin g++-15, sm_86 — OK
- Запуск: <вывод sum, exit code>, dev=/dev/nvidia0, --privileged
  (паттерн llama-cpp.service); влияние на генерацию — мигновено (один
  маленький запуск)
- ldd: all resolved / <недостающие>
- Вывод: runtime-набор из 8 пакетов достаточен / добавить: <список>
```

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/reports/2026-09-01-cuda-repo-precheck.md
git commit -m "docs: stage 24 precheck report - hello-cuda on gpu with dnf runtime set (sufficiency, ldd)"
```

---

### Task 4: Сборка NCCL — g++15 (п.7) и g++16 (п.8)

**Files:**
- Modify: `docs/superpowers/reports/2026-09-01-cuda-repo-precheck.md`
  (добавить §4)

**Interfaces:**
- Consumes: `cuda-precheck-devel:tmp` (Task 2), NCCL v2.31.2-1 (тег из
  `Makefile`).
- Produces: NCCL-сборка (g++15) — `$S/nccl-build15/` (lib, include, bin;
  использует Task 5); факты: сборка на g++15 (п.7), сборка на g++16
  (п.8) — в §4.

- [ ] **Step 1: Клон NCCL (стедж)**

```bash
S=/run/host/tmp/cuda-precheck
git clone --branch v2.31.2-1 --depth 1 https://github.com/NVIDIA/nccl.git $S/nccl15
cp -a $S/nccl15 $S/nccl16
```

- [ ] **Step 2: Сборка g++15 (базовый эквивалент прод-стадии)**

Команда — из `nvidia-nccl-devel.containerfile` (CUDA_HOME + NVCC_GENCODE
под 13.3/наш CUDA_ARCH=86):

```bash
CRE=podman; [ -f /run/.containerenv ] && CRE=podman-remote
S=/run/host/tmp/cuda-precheck
$CRE run --rm -v /tmp/cuda-precheck:/s:z cuda-precheck-devel:tmp bash -c '
  set -euxo pipefail
  cd /s/nccl15
  make -j$(nproc) src.build \
    CUDA_HOME=/usr/local/cuda-13.3 \
    CXX=g++-15 \
    NVCC_GENCODE="-gencode=arch=compute_86,code=sm_86"
  ls -la build/lib/ build/include/nccl.h
' 2>&1 | tee $S/nccl15.log | tail -20
```

Expected: сборка завершена, `build/lib/libnccl.so*` +
`build/include/nccl.h` на месте. При ошибке — точный текст в §4
(причина: CUDA 13.3 × g++15 — риск для основной спеки).

- [ ] **Step 3: Сборка g++16 (дефолт F44)**

```bash
CRE=podman; [ -f /run/.containerenv ] && CRE=podman-remote
S=/run/host/tmp/cuda-precheck
$CRE run --rm -v /tmp/cuda-precheck:/s:z cuda-precheck-devel:tmp bash -c '
  set -euxo pipefail
  cd /s/nccl16
  g++ --version | head -1
  make -j$(nproc) src.build \
    CUDA_HOME=/usr/local/cuda-13.3 \
    NVCC_GENCODE="-gencode=arch=compute_86,code=sm_86"
  ls -la build/lib/libnccl.so*
' 2>&1 | tee $S/nccl16.log | tail -20
echo "exit=${PIPESTATUS[0]}"
```

Expected: либо сборка (факт: g++16 работает — рекомендация для
переворота `GCC_VER`), либо ошибка (точный текст — факт; `GCC_VER`
остаётся 15). Оба исхода валидны.

- [ ] **Step 4: Отчёт §4**

```markdown
## 4. Сборка NCCL v2.31.2-1 на 13.3.1 (пп.7–8)

- g++15 (п.7): <успех/ошибка; время сборки; libnccl.so на месте>
- g++16 (п.8): <успех/ошибка; при ошибке — точный текст; версия g++>
- Вывод для GCC_VER: <рекомендация по таблице решений>
```

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/reports/2026-09-01-cuda-repo-precheck.md
git commit -m "docs: stage 24 precheck report - nccl build probes on cuda 13.3.1 (gcc15 baseline, gcc16 default)"
```

---

### Task 5: llama.cpp cmake-configure (п.9)

**Files:**
- Modify: `docs/superpowers/reports/2026-09-01-cuda-repo-precheck.md`
  (добавить §5)

**Interfaces:**
- Consumes: `cuda-precheck-devel:tmp`, NCCL-сборка g++15 из Task 4
  (`$S/nccl15/build`), llama.cpp master (HEAD на момент исполнения).
- Produces: факт: cmake-configure определяет CUDA 13.3.1 + NCCL по
  путям `/usr/local/cuda` — в §5.

- [ ] **Step 1: NCCL-образ (артефакты как в прод-цепи)**

NCCL размещается по `CUDA_HOME/{lib64,include,bin}` — как делают наши
`nvidia-nccl-devel`/`nvidia-nccl-libs`:

```bash
CRE=podman; [ -f /run/.containerenv ] && CRE=podman-remote
S=/run/host/tmp/cuda-precheck
cat > $S/cuda-precheck-nccl.containerfile <<'EOF'
FROM cuda-precheck-devel:tmp
COPY nccl15/build/lib /usr/local/cuda-13.3/lib64-nccl
COPY nccl15/build/include /usr/local/cuda-13.3/include-nccl
RUN set -euxo pipefail ; \
  dnf -y --setopt=install_weak_deps=False install \
    cuda-driver-devel-13-3-13.3.29-1.x86_64 \
  && dnf clean all ; \
  cp -aP /usr/local/cuda-13.3/lib64-nccl/libnccl* /usr/local/cuda-13.3/lib64/ && \
  cp -a /usr/local/cuda-13.3/include-nccl/nccl.h /usr/local/cuda-13.3/include-nccl/nccl_device.h /usr/local/cuda-13.3/include-nccl/nccl_device /usr/local/cuda-13.3/include/ && \
  rm -rf /usr/local/cuda-13.3/lib64-nccl /usr/local/cuda-13.3/include-nccl
EOF
$CRE build -f $S/cuda-precheck-nccl.containerfile -t cuda-precheck-nccl:tmp $S 2>&1 | tee $S/build-nccl-img.log
```

Context = `$S` (в нём `nccl15/build/{lib,include}`). Expected: сборка
OK. (Если в `nccl15/build` нет каталогов — Task 4 не завершён успешно:
вернуться к Task 4.)

- [ ] **Step 2: Клон llama.cpp**

```bash
S=/run/host/tmp/cuda-precheck
git clone --branch master --depth 1 https://github.com/ggml-org/llama.cpp.git $S/llama
git -C $S/llama log --oneline -1
```

- [ ] **Step 3: cmake configure**

Флаги — из `llama-cpp-cuda.containerfile`, адаптированные под
`/usr/local/cuda`:

```bash
CRE=podman; [ -f /run/.containerenv ] && CRE=podman-remote
S=/run/host/tmp/cuda-precheck
$CRE run --rm -v /tmp/cuda-precheck:/s:z cuda-precheck-nccl:tmp bash -c '
  set -euxo pipefail
  cd /s/llama
  cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=/usr/bin/gcc-15 \
    -DCMAKE_CXX_COMPILER=/usr/bin/g++-15 \
    -DCMAKE_CUDA_ARCHITECTURES=86 \
    -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc \
    -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-15 \
    -DGGML_CUDA=ON \
    -DGGML_CUDA_FORCE_MMQ=ON \
    -DGGML_CUDA_NCCL=ON \
    -DNCCL_ROOT=/usr/local/cuda \
    -GNinja
' 2>&1 | tee $S/llama-configure.log | tail -30
```

Expected: configure успешен; в выводе cmake — версия CUDA toolkit
(13.3.73) и nvcc; NCCL определён (NCCL_ROOT). Дефект плана, исправлен
при исполнении: configure проваливается на Generate
(`CUDA::cuda_driver` не найден), т.к. 7 NEVRA devel-набора не несут
`libcuda.so`-стаб; в containerfile выше добавлен
`cuda-driver-devel-13-3-13.3.29-1` (стаб), после чего configure
проходит. При иной ошибке детекции — точный текст в §5
(корректировка путей для основной спеки).

- [ ] **Step 4: Отчёт §5**

```markdown
## 5. llama.cpp cmake-configure на 13.3.1 (п.9)

- llama.cpp: <commit HEAD master>
- Configure: OK/ошибка; CUDA version по выводу cmake: <...>
- NCCL: определён по NCCL_ROOT=/usr/local/cuda — да/нет
- Вывод для NVCC/NCCL_ROOT в основной спеке: <...>
```

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/reports/2026-09-01-cuda-repo-precheck.md
git commit -m "docs: stage 24 precheck report - llama.cpp cmake configure on cuda 13.3.1 (toolkit + nccl detection via /usr/local/cuda)"
```

---

### Task 6: Финализация отчёта — таблица решений, риски, cleanup

**Files:**
- Modify: `docs/superpowers/reports/2026-09-01-cuda-repo-precheck.md`
  (таблица решений, риски, throwaway-инвентарь, статус → завершён)
- Modify: `TODO.md` (чекбокс пре-чека → `[x]`)

**Interfaces:**
- Consumes: §1–§5 отчёта.
- Produces: завершённый отчёт — основа основной спеки
  `2026-09-01-cuda-repo-design.md` (отдельная работа координатора).

- [ ] **Step 1: Таблица решений**

Заполнить все 8 строк таблицы из спеки по фактам §1–§5 (каждая строка —
конкретный исход А или Б + факт-основание).

- [ ] **Step 2: Риски для основной спеки**

Раздел «Риски для основной спеки»: по заполненной таблице — что
корректируется в дизайне (набор пакетов, ldconfig-стратегия, пути,
GCC_VER, способы пиннинга).

- [ ] **Step 3: Cleanup throwaway-артефактов**

```bash
CRE=podman; [ -f /run/.containerenv ] && CRE=podman-remote
$CRE rmi cuda-precheck-devel:tmp cuda-precheck-devel-weak:tmp cuda-precheck-libs:tmp cuda-precheck-nccl:tmp || true
rm -rf /run/host/tmp/cuda-precheck
```

(путь — литерал, допустимо без safe-rm; `|| true` — образ мог не
построиться при аномалии.) Перечень удалённых артефактов — в отчёт
(раздел «Throwaway-инвентарь»).

- [ ] **Step 4: TODO.md + статус отчёта**

- `TODO.md`: `- [ ] Пре-чек: ...` → `- [x] Пре-чек: ...` (Этап 24).
- Отчёт: статус → «завершён», дата.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/reports/2026-09-01-cuda-repo-precheck.md TODO.md
git commit -m "docs: stage 24 precheck complete - decision table, risks for main spec, throwaway cleanup; TODO checkbox"
```

- [ ] **Step 6: Handoff координатору**

Сообщить: отчёт завершён → координатор пишет основную спеку
(`docs/superpowers/specs/2026-09-01-cuda-repo-design.md`) по фактам
отчёта → ревью пользователем → план реализации (writing-plans) →
исполнение (SDD) → live-окно.
