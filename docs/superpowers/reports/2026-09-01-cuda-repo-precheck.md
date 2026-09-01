# Пре-чек: CUDA toolkit через NVIDIA fedora44 dnf-репо (Этап 24)

- Дата: 01.09.2026 (дополняется по ходу)
- Статус: в работе → завершён (обновить в Task 6)
- Спека: `docs/superpowers/specs/2026-09-01-cuda-repo-precheck.md`

## 1. Состояние репо

- Repo-файл `cuda-fedora44.repo` (скачан из каталога baseurl, 244 байта):

  ```
  [cuda-fedora44-x86_64]
  name=cuda-fedora44-x86_64
  baseurl=https://developer.download.nvidia.com/compute/cuda/repos/fedora44/x86_64
  enabled=1
  gpgcheck=1
  gpgkey=https://developer.download.nvidia.com/compute/cuda/repos/fedora44/x86_64/73CD9B30.pub
  ```

- GPG: key ID `129994480EC63D2789BC98E490DFED2F73CD9B30` (краткий ID 73CD9B30, файл 73CD9B30.pub), RSA-4096, создан 2025-11-24, uid «Kitmaker (Fedora 44) \<kitmaker@nvidia.com\>»
- CUDA-версии в репо: 13.3.0 / 13.3.1 (13.2 — отсутствует; пакетов `*-13-2-*` в индексе нет)
- Driver-пакеты в репо: 610.43.02 / 610.57.04 (не ставятся; нашей 610.43.03 в репо нет): `nvidia-driver-610.43.02-1.fc44.x86_64` (3.8MB, 2026-05-19 19:33), `nvidia-driver-610.57.04-1.fc44.x86_64` (4.1MB, 2026-07-29 15:32)
- NEVRA devel-набора (7, все кандидаты плана присутствуют; размеры/даты — по индексу репо):
  - `cuda-minimal-build-13-3-13.3.1-1.x86_64` — 8.0 KB, 2026-06-23 12:44
  - `libcublas-devel-13-3-13.6.0.2-1.x86_64` — 484 MB, 2026-06-23 12:45
  - `libcufft-devel-13-3-12.3.0.29-1.x86_64` — 178 MB, 2026-05-19 19:40
  - `libcurand-devel-13-3-10.4.3.29-1.x86_64` — 57 MB, 2026-05-19 19:40
  - `libcusolver-devel-13-3-12.2.6.9-1.x86_64` — 146 MB, 2026-06-23 12:46
  - `libcusparse-devel-13-3-12.8.2.51-1.x86_64` — 304 MB, 2026-06-23 12:47
  - `libnvjitlink-devel-13-3-13.3.33-1.x86_64` — 38 MB, 2026-05-19 19:42
- NEVRA runtime-набора (8, все кандидаты плана присутствуют; размеры/даты — по индексу репо):
  - `cuda-cudart-13-3-13.3.29-1.x86_64` — 248 KB, 2026-05-19 19:37
  - `libcublas-13-3-13.6.0.2-1.x86_64` — 392 MB, 2026-06-23 12:45
  - `libcufft-13-3-12.3.0.29-1.x86_64` — 177 MB, 2026-05-19 19:40
  - `libcurand-13-3-10.4.3.29-1.x86_64` — 57 MB, 2026-05-19 19:40
  - `libcusolver-13-3-12.2.6.9-1.x86_64` — 234 MB, 2026-06-23 12:46
  - `libcusparse-13-3-12.8.2.51-1.x86_64` — 148 MB, 2026-06-23 12:46
  - `libnvjitlink-13-3-13.3.33-1.x86_64` — 39 MB, 2026-05-19 19:42
  - `libnvfatbin-13-3-13.3.29-1.x86_64` — 552 KB, 2026-05-19 19:41
- Способ извлечения: regex из брифа к реальному формату индекса не подошёл
  (0 строк; индекс — не Apache autoindex, а HTML со спанами
  `file`/`size`/`date` и одинарными кавычками в href). Применён python3-regex
  под фактический формат (`<a href='…rpm'>` + `<span class='size'>` +
  `<span class='date'>`), фильтр имён — как в брифе. Полнота: в индексе 265
  `.rpm`, распарсено 265/265; фильтрованный инвентарь — 147 строк
  (`nevra-inventory.txt` в стедже).
- Сырые файлы (стедж `/run/host/tmp/cuda-precheck/`): `repo-index.html`
  (64817 байт), `cuda-fedora44.repo`, `nvidia-gpg.asc`, `nevra-inventory.txt`,
  `extract-nevra.py`.
