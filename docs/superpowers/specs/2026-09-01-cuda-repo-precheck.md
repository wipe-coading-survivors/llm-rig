# Спека: Пре-чек — NVIDIA fedora44 dnf-репо для CUDA toolkit (Этап 24, шаг 0)

- Дата: 01.09.2026
- Статус: направление пре-чека — утверждено пользователем (01.09.2026);
  текст спеки — ожидает ревью пользователя
- Источник: `TODO.md`, «Этап 24: CUDA toolkit: NVIDIA fedora44 dnf-репо
  (13.2.2 → 13.3.1)»
- Связь: предусловие основной спеки `2026-09-01-cuda-repo-design.md`
  (пишется **после** отчёта пре-чека; её решения опираются на факты
  настоящего пре-чека)

## Контекст и проблема

Решение брейншторма 01.09.2026 (подход A, утверждён пользователем):
источник CUDA toolkit — официальный dnf-репо NVIDIA для fedora44
(`developer.download.nvidia.com/compute/cuda/repos/fedora44/x86_64`),
точные NEVRA-пины; `.run`-redist-канал для toolkit убирается
(цель `nvidia-redist-cuda` + образ 4.4 ГБ), CUDA 13.2.2 → 13.3.1
(репо содержит только 13.3). Драйвер 610.43.03 (userspace + kmod из
`.run`), LACT, kernel-цепь — не меняются. `GCC_VER ?= 15` на этапе
сохраняется; смена дефолта — отдельное решение по факту п.8.

Верифицированные факты брейншторма (01.09.2026, read-only):

- содержимое репо: CUDA **13.3.0/13.3.1** (13.2 нет); драйверы
  **610.43.02 / 610.57.04** (нашей 610.43.03 нет); мета-пакеты
  `cuda-minimal-build-13-3` (cccl + cuda-compiler + cudart-devel +
  culibos-devel + profiler-api), `cuda-libraries-13-3` (14 runtime-пакетов),
  `cuda-libraries-devel-13-3` (соответствующие -devel); GPG —
  `73CD9B30.pub`, `gpgcheck=1`, repo-файл `cuda-fedora44.repo`;
- размеры текущих образов: `nvidia-cuda-devel:13.2` **8.72 ГБ**,
  `nvidia-cuda-libs:13.2` **5.3 ГБ**, `llama-cpp-cuda:13.2` **5.46 ГБ**
  (runtime-libs — весь `targets/x86_64-linux/lib` из `.run`);
- F44: дефолтный gcc = **16** (16.2.1-2.fc44, updates), gcc15 =
  15.3.1-1.fc44 (отдельный пакет);
- все ссылки на `/opt/cuda` — в пределах цепи: 5 containerfiles
  (cuda-devel, cuda-libs, nccl-devel, nccl-libs, llama-cpp-cuda) +
  `Makefile` (`NVCC`) + 2 пина graph-теста + 1 debug-скрипт.

Неверифицированные факты, от которых ветвится основная спека:

1. dnf5 (F44) × NVIDIA-репо: работает ли .repo-файл, доставленный
   `curl`'ом из URL (gpgcheck=1, удалённый gpgkey) — makecache +
   транзакция;
2. установка по точному NEVRA через dnf5: синтаксис; режим отказа при
   несуществующем NEVRA (fail-loud?);
3. `--setopt=install_weak_deps=False` на dnf5: валиден? что
   подтягивают weakdeps (состав + размер) — замечание пользователя
   о возможном раздуве размеров;
4. размещение файлов dnf-пакетов CUDA: `/usr/lib64` или
   `/usr/local/cuda-13.3/lib64` (libcudart, libnvJitLink, nvcc и др.);
   symlink `/usr/local/cuda`; собственные `/etc/ld.so.conf.d`-входы
   пакетов — определяет ldconfig-стратегию основной спеки;
5. размер целевых наборов (devel: `cuda-minimal-build-13-3` +
   -devel пяти math-библиотек + `libnvjitlink-devel`; runtime: cudart,
   cublas, cufft, curand, cusolver, cusparse, nvjitlink, nvfatbin) —
   с weakdeps off;
6. достаточность runtime-набора на реальном GPU: hello-cuda
   (nvcc 13.3.1) работает в контейнере только с dnf runtime-набором +
   driver userspace (libcuda*/libnvidia* из `nvidia-xorg:610.43.03`,
   как в проде);
7. NCCL v2.31.2-1 собирается с `CUDA_HOME=/usr/local/cuda-13.3`,
   g++-15 (базовый эквивалент нашей стадии `nvidia-nccl-devel`);
8. NCCL собирается с дефолтным g++16 (F44) — факт для решения о
   перевороте дефолта `GCC_VER` (замечание пользователя 01.09.2026);
9. llama.cpp master (текущий HEAD): cmake-configure определяет CUDA
   toolkit + nvcc + NCCL по путям `/usr/local/cuda` (только configure;
   полная сборка — live-окно основной спеки);
10. состояние репо на дату пре-чека: полный список целевых NEVRA
    (наличие/размер/дата), содержимое `cuda-fedora44.repo`, GPG key ID.

## Цель

Верифицировать пункты 1–10. Артефакты:

- отчёт `docs/superpowers/reports/2026-09-01-cuda-repo-precheck.md`:
  по каждому пункту — команда, обрезанный сырой вывод, вывод;
  заполненная таблица решений; риски для основной спеки; перечень
  throwaway-артефактов (образы, стедж) для cleanup;
- отметка чекбокса пре-чека в `TODO.md` (Этап 24);
- основная спека `2026-09-01-cuda-repo-design.md` — **после** отчёта,
  отдельным коммитом, до плана реализации (writing-plans).

## Не цели

- Изменения сборки репозитория (Makefile / containerfiles / scripts /
  resources) — дело основной спеки; тестовые образы/контейнеры —
  одноразовые (throwaway), в сборку не входят.
- Полная сборка llama.cpp и прогон llama-server — live-окно основной
  спеки (п.9 — только configure).
- Драйвер/kmod, LACT, kernel-цепь.
- Решение о перевороте дефолта `GCC_VER` — пре-чек даёт только факт
  (п.8); решение — в основной спеке (решение пользователя).
- Prod-живое окно по протоколу «снимок → restore»: п.6 —
  ненагружающая проба (один маленький ядро-запуск в throwaway-
  контейнере, без изменения состояния GPU/OC/драйвера); влияние на
  идущую генерацию фиксируется в отчёте (мгновенно).

## Ограничения

- CRE — по правилу `no-cre-hardcode` во всех командах/скриптах
  пре-чека.
- Throwaway-стедж на хосте: `/tmp/cuda-precheck` (из toolbx:
  `/run/host/tmp/cuda-precheck`); throwaway-образы — теги
  `cuda-precheck-*:tmp`.
- GPU-проба (п.6): контейнер — `--privileged` + GPU-девайсы
  (паттерн прод-юнита `resources/llama/llama-cpp.service`:
  `--device /dev/nvidia0..4 --privileged`), один маленький
  CUDA-запуск.
- В репо изменяются только `TODO.md` и
  `docs/superpowers/reports/2026-09-01-cuda-repo-precheck.md`.

## Проверки (группы — будущие задачи плана)

### Группа A: dnf5 × репо, механика установки (без GPU)

Throwaway-образ(ы) на `nvidia-base:44` + .repo-файл (curl из URL):

1. **Репо + GPG**: `dnf makecache` + установка небольшого пакета
   (например, `cuda-nvml-devel-13-3`): импорт ключа по remote gpgkey,
   транзакция успешна.
2. **NEVRA-пин**: `dnf install -y cuda-nvcc-13-3-13.3.73-1.x86_64.rpm`
   — установка; затем несуществующий NEVRA
   (`cuda-nvcc-13-3-0.0.0-1.x86_64.rpm`) — зафиксировать режим отказа
   (сообщение, exit code).
3. **weakdeps**: установка devel-набора с `--setopt=install_weak_deps=False`
   и без (два throwaway-образа); зафиксировать дельту: какие пакеты
   дополнительно подтянуты и на какой размер.
4. **Размещение**: `rpm -ql` ключевых пакетов (cuda-nvcc, cuda-cudart,
   cuda-cudart-devel, libcublas, libcublas-devel, libnvjitlink, cccl,
   cuda-culibos-devel): каталоги (`/usr/lib64`, `/usr/local/cuda-13.3/…`);
   `ls -la /usr/local/cuda*`; `ls /etc/ld.so.conf.d/`;
   `ldconfig -p | grep -E 'libcudart|libcublas|libcufft|libcurand|
   libcusolver|libcusparse|libnvJitLink|libnvfatbin'` — что резолвится
   и из каких каталогов.
5. **Размеры**: установленный размер devel- и runtime-наборов
   (`rpm -qa` + du по каталогам; дельту weakdeps — из п.3).

### Группа B: достаточность runtime-набора на GPU (безопасно)

6. **hello-cuda**: hello.cu (маленькое ядро, известный результат)
   компилируется в devel-образе (nvcc 13.3.1) → бинарник запускается
   в runtime-образе (dnf runtime-набор + libcuda*/libnvidia* из
   `nvidia-xorg:610.43.03`, как в прод-цепи) с GPU-девайсами →
   корректный результат; `ldd` бинарника: всё резолвится. Вывод:
   достаточен ли набор из 8 пакетов; если нет — какие пакеты добавить.

### Группа C: пробы сборки на 13.3.1 (без GPU)

7. **NCCL × g++15**: клон NCCL `v2.31.2-1` (тег из `Makefile`) в
   devel-образе: `make src.build CUDA_HOME=/usr/local/cuda-13.3
   CXX=g++-15 NVCC_GENCODE=…` (команда нашей
   `nvidia-nccl-devel.containerfile`, адаптированная под путь) →
   сборка завершена, `libnccl.so*` на месте.
8. **NCCL × g++16 (дефолт)**: то же без переопределения CXX
   (дефолтный g++ F44) → собирается? при неудаче — точная ошибка.
9. **llama.cpp configure**: клон llama.cpp (HEAD `master`, как в
   `Makefile`) в образе с NCCL из п.7 (размещён по
   `CUDA_HOME/{lib64,include,bin}`, как в прод-цепи):
   `cmake -B build -DCMAKE_CUDA_ARCHITECTURES=86
   -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc -DGGML_CUDA=ON
   -DGGML_CUDA_FORCE_MMQ=ON -DGGML_CUDA_NCCL=ON -DNCCL_ROOT=/usr/local/cuda
   -GNinja` (флаги нашего `llama-cpp-cuda.containerfile`, адаптированные
   под путь) → configure успешен, верифицировать версию toolkit из
   вывода cmake. Полная сборка — нет.

### Группа D: состояние репо (дёшево, без сборки)

10. **NEVRA-набор + метаданные**: полный список целевых NEVRA (из
    листинга репо) с размерами/датами; содержимое
    `cuda-fedora44.repo`; GPG key ID; дата пре-чека. (Устанавливаемость
    ключевых NEVRA подтверждается пп.1–5; п.10 фиксирует полный
    список для основной спеки.)

## Таблица решений (заполняется отчётом)

| Пункт | Исход А | Исход Б |
|---|---|---|
| dnf5 × репо (1) | работает (makecache + install OK) → основная спека: curl .repo + gpgcheck в containerfile | не работает (GPG/метаданные) → иной способ доставки репо (tracked-файл/ключ заранее) — основная спека корректируется |
| NEVRA (2) | точный NEVRA ставится, при отсутствии — fail-loud → пины NEVRA в containerfile | иной способ пиннинга (glob / `=`-версии) |
| weakdeps (3) | дельта зафиксирована → `install_weak_deps=False` в основной спеке | weakdeps несут нужное → набор корректируется по факту |
| размещение (4) | runtime-libs в `/usr/lib64` (системный путь) → ldconfig-стратегия: conf только для `/usr/local/cuda-13.3/lib64` (если потребуется) | libs только в `/usr/local/cuda-13.3/lib64` → conf обязателен; копирование NCCL — по факту |
| runtime-набор (6) | hello-cuda OK → набор из 8 пакетов в основной спеке | нехватка lib → добавить пакеты (список в отчёте) |
| NCCL g++15 (7) | собирается → базовая конфигурация сохраняется | ошибка сборки → причина (CUDA 13.3 × g++15) — риск в основной спеке |
| NCCL g++16 (8) | собирается → в отчёте рекомендация переворота дефолта `GCC_VER` на 16 (решение — пользователя, в основной спеке) | ошибка → оставить 15 (факт в отчёте) |
| llama configure (9) | configure OK, определён CUDA 13.3.1 → в основной спеке `NVCC`/`NCCL_ROOT` = `/usr/local/cuda` | ошибка детекции → корректировка путей (явные CMake-переменные) |

## Критерии готовности

- все 10 пунктов — с фактом (команда + обрезанный вывод + вывод);
  «неверифицировано» не осталось;
- таблица решений заполнена (каждая строка — конкретный исход);
- отчёт закоммичен (посекционно, паттерн LACT-пре-чека);
- `TODO.md` Этап 24: чекбокс пре-чека отмечен;
- throwaway-артефакты перечислены в отчёте; cleanup — задача плана;
- после отчёта: основная спека (по фактам) → ревью пользователем →
  план реализации (writing-plans) → исполнение (SDD) → live-окно.
