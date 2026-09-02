# Мемо: REPO_BASE_URL — из Makefile в local.mk

- Дата: 01.09.2026
- Тип: мелкий фикс (правило `planning`: для мелкого фикса мемо и есть
  короткий документ), затронуты существующий код (Makefile, `scripts/`)

## Контекст

- Пре-чек этапа 24 (отчёт
  `docs/superpowers/reports/2026-09-01-cuda-repo-precheck.md`, риск 4):
  зашитый в дефолт `nvidia-base` `mirror.getpods.ru` в окно пре-чека был
  недоступен с build host. Зеркало — инфраструктура машины (собственное),
  а не публичный дефолт репозитория; 01.09.2026 владелец починил зеркало
  (верификация: `local.repo` + repomd'ы `fedora`/`updates` → 200).
- Дефолт `REPO_BASE_URL ?= http://mirror.getpods.ru` в Makefile
  (строка 71) зашивает machine-local значение в код репозитория.

## Решение

- Дефолт `REPO_BASE_URL` убрать из Makefile: значение — в `local.mk`
  (gitignored, machine-local, тот же класс, что `LLAMA_HOST` /
  `LLM_NFS_SERVER`); `local.mk` уже подключается (`-include local.mk`,
  Makefile:5) и переопределял дефолт — теперь он единственный источник.
- Семантика переменной — **опционал** (проверка уже есть в
  `nvidia-base.containerfile`): задано — `nvidia-base` качает
  `local.repo` с зеркала; не задано — образ использует стандартные
  репо base-образа (fedora-minimal). Containerfile без изменений.
- `local.mk.example` — задокументировать переменную (опционал +
  значение-дефолт), заголовок уточнён.
- `scripts/test-makefile-graph.sh` — test передаёт `REPO_BASE_URL`
  явно (pass-through-проверка `--build-arg`), значение — test-URL,
  как соседние `drv_url`/`koji_url`; раньше ожидание
  `http://mirror.getpods.ru` проходило только при наличии
  operator-`local.mk` (машина-зависимо).
- `KOJI_BASE_URL` (публичный kojipkgs.fedoraproject.org) остаётся
  в Makefile — не machine-local.

## Затронутые файлы

- `Makefile` (−1 строка дефолта)
- `local.mk.example` (+`REPO_BASE_URL`, заголовок)
- `scripts/test-makefile-graph.sh` (test-URL + явная передача)

## Результаты верификации

- `bash scripts/test-makefile-graph.sh` — pass=304 fail=0
  (включая `nvidia-base REPO_BASE_URL` с явной передачей test-URL).
- `bash scripts/test-no-sensitive.sh` — pass=2 fail=0 (без local.mk);
  с симуляцией operator-`local.mk` реальными значениями
  (REPO_BASE_URL + приватные IP хостов) — pass=4 fail=0: значение
  `http://mirror.getpods.ru` не встречается в tracked-файлах
  (пример несёт плейсхолдер `http://mirror.example.com` — инвариант
  теста «значения local.mk не в tracked» сохранён).
- Containerfile не менялся: пустой `REPO_BASE_URL` → стандартные репо
  base-образа (существующий опционал), заданный → `local.repo` зеркала.
