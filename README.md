# llm-rig

Контейнеризованные компоненты хоста для быстрого развёртывания
LLM (NVIDIA): модули ядра, драйвер, OC/авто-свитч, llama.cpp,
мониторинг.

Сборка: `Makefile` + `*.containerfile` (инструмент контейнеров —
переменная `CRE`: `podman` или `podman-remote`). Кодовые правила —
`AGENTS.md`, процессные — `COORDINATOR.md`. Локальные значения —
`local.mk` (см. `local.mk.example`).

## Важные файлы и каталоги

- `TODO.md` — этапы (конвенция: брейншторм → спека → план)
- `docs/superpowers/{specs,plans,reports,memos}/` — процесс-доки
  (конвенция появится со следующего этапа)
- `local.mk` / `local.mk.example` — machine-local значения / шаблон

## Быстрый старт

```sh
cp local.mk.example local.mk   # заполнить: LLAMA_HOST, LLM_NFS_SERVER
make llama-cpp-cuda            # образ рантайма (нужны CRE + NVIDIA drv)
make systemd                   # юниты + sysconfig на хост (HOST_ROOT)
```

`local.mk` (untracked) — machine-local значения. Без него
`make systemd` не работает (fail-loud); сборка образов — работает.

## Тесты

```sh
for t in scripts/test-*.sh; do sh "$t" || break; done
```
