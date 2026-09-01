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

## 2. dnf5 × репо, механика установки (пп.1–5)

- Образы: `cuda-precheck-devel:tmp` (weakdeps off) и
  `cuda-precheck-devel-weak:tmp` (weakdeps on) — на `nvidia-base:44`,
  `podman-remote build`. Логи и выходы проб (стедж): `build-devel.log`,
  `build-devel-weak.log`, `probe-repo.txt`, `probe-repo-supplement.txt`,
  `probe-placement.txt`, `probe-sizes.txt`, `weakdeps-qa-delta.txt`;
  логи неудачных попыток сборки — `build-devel-attempt1-getpods-down.log`,
  `build-devel-attempt2-redirector-slow-mirror.log`.

### 2.1. Среда: отклонение от брифа (документировано)

Базовое Fedora-зеркало, зашитое в `nvidia-base:44` (`mirror.getpods.ru`,
`/etc/dnf/vars/repobaseurl`), было недоступно со сборочного хоста в окно
пре-чека: HTTP — `Curl error (28)` (hang, «less than 1000 bytes/sec»),
HTTPS — rc=60 (сертификат). В первой попытке (attempt1-лог) это дало два
факта dnf5-механики:

- `dnf makecache` при неуспешной загрузке метаданных части репо **завершается
  с кодом 0** (в логе — `Curl error (28)`, `Usable URL not found`, а затем
  «Metadata cache created.») — `set -e` containerfile это не ловит; ошибка
  проявляется только в транзакции («Нет соответствия для аргумента»,
  «ничто не предоставляет gcc-c++, необходимый для cuda-nvcc-13-3-13.3.73-1»).
- `download.fedoraproject.org` — редиректор: во второй попытке (attempt2-лог)
  он маршрутизировал скачивание пакетов на `mirror.cov.ukservers.com`
  (тоже `Curl error (28)`, «No more mirrors to try») — транзакция падала на
  одном пакете после загрузки 2.5 GiB.

Поэтому в обоих containerfile **только базовые репо** (`fedora`, `updates`)
перенаправлены на прямое официальное зеркало `mirror.yandex.ru` (новый
лейаут F44: `releases/44/Everything/x86_64/os` и
`updates/44/Everything/x86_64`) через `dnf config-manager setopt`
(персистится в `/etc/dnf/repos.override.d/99-config_manager.repo` —
факт: на dnf5 `config-manager setopt` пишет override-файл, а не сам
`.repo`); `gpgcheck=0` сохранён, как в исходном `local.repo`.
Обработка NVIDIA-репо (curl `cuda-fedora44.repo` + `dnf makecache`) —
буквально по брифу, без изменений; это и есть предмет пре-чека.
`mirror.yandex.ru` — ~33 МБ/с со сборочного хоста (замер `curl`).

Дополнительные факты dnf5-механики (из логов/проб):

- Именование пакетов репо: в имени — мажорная версия (`cuda-nvcc-13-3`,
  версия `13.3.73`); `rpm -ql cuda-nvcc` → «пакет cuda-nvcc не установлен»
  (проба из брифа дала пустой вывод; исправленная — в `probe-placement.txt`,
  помечена `[corrected]`).
- Вывод транзакции dnf5 (локаль `ru_RU.UTF-8` в образе) **не содержит списка
  «Installed: …»** — только строка «Установка: N пакетов» и progress-строки
  `[i/N] Установка <nevra-обрезано-до-20-знаков>` (перезаписываются `\r`).
  `grep -E "^(Installed|Downloading|Importing)"` из брифа — 0 совпадений;
  weakdeps-дельта взята по `rpm -qa`-diff (основной метод), лог-метод —
  не годится для точного списка (зафиксировано: `weakdeps-delta.txt` пуст).

- **Репо+GPG (п.1): OK.** `.repo` доставлен `curl`'ом из URL
  (containerfile по брифу); `dnf makecache` — метаданные cuda-репо
  50.1 KiB; `repolist`: `cuda-fedora44-x86_64` (enabled) + `fedora` +
  `updates`. Ключ импортирован автоматически из удалённого `gpgkey`
  (транзакция с `gpgcheck=1`, `-y`), оба лога сборки:

  ```
  Импортирование ключа OpenPGP 0x73CD9B30:
   UserID     : "Kitmaker (Fedora 44) <kitmaker@nvidia.com>"
   Отпечаток: 129994480EC63D2789BC98E490DFED2F73CD9B30
   Из       : https://developer.download.nvidia.com/compute/cuda/repos/fedora44/x86_64/73CD9B30.pub
  Ключ был успешно импортирован.
  ```

  Отпечаток — совпадает с §1. Транзакция: 134 пакета (devel) / 144 (weak),
  «Завершено!». В логе предупреждение о `gpgcheck=0` базовых репо
  (политика унаследована из `nvidia-base`): «пропущены проверки OpenPGP
  для 103 пакетов из репозиториев: fedora, updates» (weak: 113) —
  пакеты cuda-репо проверены.

- **NEVRA-пин (п.2): установка по точному NEVRA — OK; несуществующий
  NEVRA — fail-loud, exit=1.** Все 7 NEVRA devel-набора установились ровно
  указанных версий (список — дословно из §1; полный список установленных —
  `probe-repo.txt`, 29 пакетов grep-набора брифа):

  ```
  cuda-minimal-build-13-3-13.3.1-1.x86_64
  libcublas-devel-13-3-13.6.0.2-1.x86_64
  libcufft-devel-13-3-12.3.0.29-1.x86_64
  libcurand-devel-13-3-10.4.3.29-1.x86_64
  libcusolver-devel-13-3-12.2.6.9-1.x86_64
  libcusparse-devel-13-3-12.8.2.51-1.x86_64
  libnvjitlink-devel-13-3-13.3.33-1.x86_64
  ```

  + транзитно `cccl-13-3-13.3.3.4.1`,
  `cuda-compiler-13-3-13.3.1-1`, `cuda-nvcc-13-3-13.3.73-1`,
  `cuda-crt-13-3-13.3.73-1`, `cuda-cudart(-devel)-13-3-13.3.29-1`,
  `cuda-culibos-devel-13-3-13.3.33-1`, `cuda-cuobjdump-13-3-13.3.73-1`,
  `cuda-cuxxfilt-13-3-13.3.29-1`, `cuda-nvprune-13-3-13.3.29-1`,
  `cuda-profiler-api-13-3-13.3.27-1`, `cuda-tileiras-13-3-13.3.36-1`,
  `cuda-ctadvisor-13-3-13.3.33-1`, 3 noarch `cuda-toolkit-*-config-common`
  и runtime-версии пяти math-библиотек + `libnvjitlink` (devel-пакеты
  требуют runtime). Режимы отказа:

  ```
  $ dnf install -y cuda-nvcc-13-3-0.0.0-1.x86_64.rpm   # буквальная команда брифа
  Не удалось получить доступ к RPM "cuda-nvcc-13-3-0.0.0-1.x86_64.rpm": No such file or directory
  exit=1
  $ dnf install -y cuda-nvcc-13-3-0.0.0-1.x86_64       # [доп. проба] без .rpm
  Не удалось разрешить транзакцию:
  Нет соответствия для аргумента: cuda-nvcc-13-3-0.0.0-1.x86_64
  exit=1
  ```

  **Важно для основной спеки:** суффикс `.rpm` заставляет dnf5 трактовать
  аргумент как путь к локальному файлу, а не как NEVRA репо — пример из
  спеки (`cuda-nvcc-13-3-13.3.73-1.x86_64.rpm`) как пин работать не будет.
  Без суффикса: точный NEVRA резолвится в репо (для уже установленного —
  «Пакет … уже установлен. Нечего делать.», exit=0), несуществующий —
  явная ошибка, exit=1.

- **weakdeps (п.3): валиден; дельта = 10 пакетов / 12,537,885 B (12.0 MiB).**
  `--setopt=install_weak_deps=False` на dnf5 принят без ошибок. Дельта —
  `rpm -qa`-diff (основной метод, `weakdeps-qa-delta.txt`; 314 vs 324
  пакета; лог-метод — 0 строк, см. выше). Все 10 пакетов — additions,
  **ни одного из CUDA-пакетов** (weakdeps базового тулчейна):

  ```
  7zip-26.02-1.fc44.x86_64                    3508124
  bat-0.26.1-4.fc44.x86_64                    5543723
  less-color-704-4.fc44.x86_64                     2453
  libgit2-1.9.7-1.fc44.x86_64                  1466624
  libssh2-1.11.1-9.fc44.x86_64                  346685
  llhttp-9.3.1-1.fc44.x86_64                     98962
  oniguruma-6.9.10-4.fc44.x86_64                789435
  perl-NDBM_File-1.18-525.fc44.x86_64            29045
  python3-html2text-2025.4.15-6.fc44.noarch     296327
  unzip-6.0-69.fc44.x86_64                      456507
  ```

- **Размещение (п.4): все файлы — в `/usr/local/cuda-13.3/`**
  (`bin/`, `include/`, `lib64/`, `nvvm/`, `src/`,
  `targets/x86_64-linux/{lib,include}`); в `/usr/lib64` — только `*.pc`
  devel-пакетов (`/usr/lib64/pkgconfig/`), в `/opt` — ничего.
  nvcc → `/usr/local/cuda-13.3/bin/nvcc` (V13.3.73; доступен как
  `/usr/local/cuda/bin/nvcc`); libcudart/libnvJitLink и остальные —
  `/usr/local/cuda-13.3/targets/x86_64-linux/lib/`, hard-linked с
  `/usr/local/cuda-13.3/lib64/` (одни иноды; `du` не двойсчитает).
  `/usr/local/cuda` symlink: **есть**, но не прямой —
  `/usr/local/cuda → /etc/alternatives/cuda → /usr/local/cuda-13.3`
  (аналогично `cuda-13 → /etc/alternatives/cuda-13`).
  `/etc/ld.so.conf.d/` (файлы от пакетов): `000_cuda.conf` →
  `/usr/local/cuda/targets/x86_64-linux/lib`; `987_cuda-13.conf` →
  `/usr/local/cuda-13/targets/x86_64-linux/lib`. `ldconfig -p`:
  `libcudart.so.13`, `libcublas.so.13`/`libcublasLt.so.13`,
  `libcufft.so.12`/`libcufftw.so.12`, `libcurand.so.10`,
  `libcusolver.so.12`/`libcusolverMg.so.12`, `libcusparse.so.12`,
  `libnvJitLink.so.13` — резолвятся из
  `/usr/local/cuda/targets/x86_64-linux/lib/` (т.е. через
  `000_cuda.conf`); `libnvfatbin` — отсутствует в devel-образе
  (не входит в devel-набор).

- **Размеры (п.5): devel-набор (weakdeps off) = 29 пакета /
  3,862,954,628 B (3.60 GiB) installed** (`probe-sizes.txt`, сумма
  `%{SIZE}`; без двойного счёта — у каждого файла один владелец:
  runtime-`.so` за runtime-пакетами, static-`.a` за devel).
  `du -sh /usr/local/cuda-13.3` = 3.7G, `/usr/lib64` = 150M.
  +weakdeps = 3,875,492,513 B (3.61 GiB; +12.0 MiB / +0.3%).
  Скачивание в devel-сборке: 135 загрузок (134 пакета + GPG-ключ
  `73CD9B30.pub`, 1.6 KiB), 2.6 GiB за 01m05s (среднее 40.4 MiB/s).
  Размеры образов: `cuda-precheck-devel:tmp` = 4.97 GB,
  `cuda-precheck-devel-weak:tmp` = 4.98 GB.
