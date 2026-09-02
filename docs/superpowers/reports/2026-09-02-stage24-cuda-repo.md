# Live-окно Этапа 24 — CUDA 13.3 (NVIDIA dnf-репо): отчёт

- Дата: 02.09.2026; ветка `stage24-cuda-repo` (head `bf71d47`);
  CRE=podman-remote (toolbx, хост FCOS); машина: 2×Xeon 2080v4, 256 GB.
- Спека: `docs/superpowers/specs/2026-09-01-cuda-repo-design.md`
  (раздел «Live-окно»); пре-чек:
  `docs/superpowers/reports/2026-09-01-cuda-repo-precheck.md`.

## 1. Пересборка цепи

Один вызов `make llama-cpp-cuda-debug` (порядок — по зависимостям,
совпадает с цепью спеки: base → xorg → cuda-{devel,libs} →
nccl-{devel,libs} → llama → debug).

| Образ | Размер | Примечание |
|---|---|---|
| `nvidia-base:44` | 315 MB | REPO_BASE_URL пусто (в operator-`local.mk` зеркала нет) → стандартные fedora/updates — fallback R2, зеркало не в цепочке |
| `nvidia-xorg:610.43.03` | 2.18 GB | без изменений дизайна |
| `nvidia-cuda-devel:13.3` | 5.32 GB | dnf-установка по именам серии `13-3` |
| `nvidia-cuda-libs:13.3` | 2.63 GB | ровно 2.63 GB, как предсказал пре-чек §3 |
| `nvidia-nccl-devel-cuda-13.3:v2.31.2-1` | 6.28 GB | сборка NCCL на gcc15 (`gcc15-c++ 15.3.1`) — путь по пре-чеку §3.5 |
| `nvidia-nccl-libs-cuda-13.3:v2.31.2-1` | 2.69 GB | |
| `llama-cpp-cuda:13.3` | 2.79 GB | против 5.46 GB у `:13.2` (−2.67 GB: нет .run-redist-балласта) |
| `llama-cpp-cuda-debug:13.3` | 6.38 GB | против 9.85 GB у `:13.2` |

Аудит-файлы `/usr/local/cuda-installed.txt` (R6):
- devel — 31 NEVRA серии `13-3`; ключевые (свежайшие релизы, по F10):
  `cuda-nvcc-13-3-13.3.73-1`, `cuda-cudart(-devel)-13-3-13.3.29-1`,
  `cuda-driver-devel-13-3-13.3.29-1`, `cuda-sanitizer-13-3-13.3.75-1`,
  `libnvvm-13-3-13.3.73-1`;
- libs — 9 NEVRA: 8 runtime-пакетов + `cuda-toolkit-13-3-config-common`
  (noarch) — известный deferred-наблюдатель final review (фильтр
  `rpm -qa | grep -13-3-` его видит; на сборку не влияет).

## 2. Приёмка (спека §3)

- `nvcc --version` (devel-образ): `release 13.3, V13.3.73` — OK.
- `/usr/local/cuda/bin/compute-sanitizer --version` (debug-образ) — OK.
- `ldconfig -p` (runtime-образ): 12 sonames из 8 runtime-пакетов
  (cublas+Lt, cudart, cufft+cufftw, curand, cusolver+Mg, cusparse,
  nvJitLink, nvfatbin, nvblas) под package-shipped layout
  `/usr/local/cuda/targets/x86_64-linux/lib/` — OK.
- Смоук `/app/llama-server --version` (без GPU): `version: 0.3.0-dev,
  built with GNU 15.3.1` — бинарь и динамика на месте (CUDA-init ошибка
  без устройств — ожидаема).
- Тест-сьют репозитория: 13/13 зелёных (перепрогон в финальном
  состоянии).

## 3. Деплой и рестарт прод-контейнера

- Снимок до рестарта: `podman inspect llama-cpp` + старый sysconfig
  (временный, `/tmp/opencode/live24/`).
- `make systemd`: юниты без изменений; `/etc/sysconfig/llama-cpp`
  → `LLAMA_IMAGE=llama-cpp-cuda:13.3`; daemon-reload + enable.
- Перед рестартом оператор закомментировал в host-`/etc/llama/llama.ini`
  параметры `cache-type-[kv]-draft = q8_0` (не давали серверу
  нормально работать) — сервер стартовал с этой версией, файл
  координатором не тронут.
- Рестарт: `systemctl restart llama-cpp` в 09:01:26 MSK, rc=0.
  Запущен с задержкой после завершения хода координатора (сессию
  держит тот же сервер — рестарт посреди генерации убил бы ход).
- Контейнер `llama-cpp` Up на `localhost/llama-cpp-cuda:13.3`;
  `/health` → `{"status":"ok"}`.
- Короткая генерация (`/v1/chat/completions`, model=default,
  max_tokens=8): 200 OK; prefill 59 tok @ 52.5 t/s, генерация
  8 tok @ 21.2 t/s; draft/MTP активен (`draft_n=4`).

## 4. Cleanup (спека, шаг 4)

Удалены (7 образов, ровно список спеки):
`nvidia-redist-cuda:13.2`, `nvidia-cuda-devel:13.2`,
`nvidia-cuda-libs:13.2`, `nvidia-nccl-devel-cuda-13.2:v2.31.2-1`,
`nvidia-nccl-libs-cuda-13.2:v2.31.2-1`, `llama-cpp-cuda:13.2`,
`llama-cpp-cuda-debug:13.2`.

Оставлены (операторские производные, вне списка спеки):
`llama-cpp-cuda:13.2-old`, `nvidia-redist-cuda:13.2-bkp`,
`llama-cpp-cuda-glm5next:13.2`, `llama-nvidia-nccl-devel:13.2`.

После cleanup откат на `:13.2` невозможен без пересборки —
восстановление идёт по новой цепи (13.3).

## 5. Наблюдения (не блокирующие)

- buildah-предупреждение при сборке debug-образа:
  `build args were not consumed: [LLAMA_IMAGE]` — мульти-стадж
  аномалия (аргумент потреблён в промежуточном этапе `FROM ${LLAMA_IMAGE}
  AS builder`); containerfile в этапе не менялся — предупреждение
  пре-существующее, на образ не влияет.
- API-ключи: `/etc/llama/llama-cpp-keys.txt` — файл с комментариями
  (`#`) и пустыми строками; `--api-key-file` сервера их принимает.
  Для ручного curl нужна реальная ключевая строка (не `head -1`).
- Задержанный фоновый рестарт через `nohup ... &` на этот раз
  выжил, но по таймауту tool-вызова opencode nohup-процесс может
  быть убит — для скрипта безопасного рестарта (TODO Этап 25)
  задан `setsid` + алгоритм (ожидание инференса → рестарт →
  curl-проверка к модели).

## 6. Итог

Live-окно завершено: цепь на 13.3, прод-сервер работает на
`llama-cpp-cuda:13.3`, санитайзер на месте, старые `:13.2` образы
убраны. Критерии готовности спеки закрыты — остаётся
finishing-a-development-branch (merge в `main`).
