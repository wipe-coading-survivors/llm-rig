# Пре-чек: CUDA toolkit через NVIDIA fedora44 dnf-репо (Этап 24)

- Дата: 01.09.2026
- Статус: завершён (таблица решений, риски, cleanup — Task 6)
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

## 3. hello-cuda на GPU (п.6)

Образ runtime `cuda-precheck-libs:tmp` (2.63 GB): `FROM nvidia-xorg:610.43.03 as
drv` + `FROM nvidia-base:44` + `COPY hello /hello` + dnf install 8 NEVRA
runtime-набора + копирование driver userspace из drv-стадии (тот же набор путей,
что `nvidia-cuda-devel.containerfile`: `/opt/nvidia/`, `usr/lib64/libcuda*`,
`usr/lib64/libnvidia*`, `10_local.conf`). Логи и выходы проб (стедж):
`compile-hello.log` (неудача по брифу), `compile-hello-corrected.log` (успех),
`build-libs.log`, `run-hello-gpu.log`, `ldd-hello.log`, `verify-libs.txt`.

### 3.1. Среда: три отклонения (документированы)

- **hello.cu: запуск ядра как обычный вызов функции** (ошибка брифа). Строка
  брифа `add(n / 256, 256, a, b, c, n);` отклоняется nvcc 13.3.1 (4 ошибки:
  «too many arguments in function call» — `__global__ add` принимает 4
  аргумента, а передано 6). Исправлено на стандартный запуск ядра
  `add<<<n / 256, 256>>>(a, b, c, n);` (4 блока × 256 потоков = 1024 элементов;
  4 аргумента ядра `a,b,c,n`); все остальные строки — дословно из брифа. Без
  исправления бинарник не собирается → проба на GPU невозможна.
- **nvcc не в PATH devel-образа**: в `cuda-precheck-devel:tmp` nvcc —
  `/usr/local/cuda/bin/nvcc` (через альтернативы → `/usr/local/cuda-13.3`), но
  ни в PATH, ни в ENV/profile.d не добавлен. Компиляция выполнена с
  `export PATH=/usr/local/cuda/bin:$PATH`; вызов nvcc — дословно
  (`-ccbin g++-15 -arch=sm_86 -o /s/hello /s/hello.cu`).
- **Базовое Fedora-зеркало** — отклонение §2.1, перенесено: зашитое в
  `nvidia-base:44` `mirror.getpods.ru` было мертво со сборочного хоста в этом же
  окне пре-чека (факт §2.1). Фикс применён **проактивно** на том же основании
  (тот же базовый образ `nvidia-base:44`, тот же сборочный хост, то же окно), не
  повторяя «тупик» мёртвого зеркала заново: только базовые репо (`fedora`,
  `updates`) перенаправлены на `mirror.yandex.ru` через
  `dnf config-manager setopt`; NVIDIA-репо (curl `cuda-fedora44.repo`) —
  дословно по брифу. Итог: в `build-libs.log` **ноль ошибок базовых репо**.

### 3.2. Компиляция (devel-образ): OK

nvcc 13.3.1 (V13.3.73), `-ccbin g++-15 -arch=sm_86` (host g++15 — как в
прод-цепи), bind-mount стеджа. `COMPILE_OK`; бинарник `ELF 64-bit LSB
executable, x86-64, dynamically linked, 1070064 B, with debug_info, not
stripped` (`file`).

### 3.3. Установка 8 NEVRA (runtime-образ): OK, ровно версии из §1

Транзакция (`build-libs.log`): «Установка: 11 пакетов» = 8 NEVRA runtime-набора
+ 3 noarch `cuda-toolkit-*-config-common`, все из `cuda-fedora44-x86_64`:

```
cuda-cudart-13-3-13.3.29-1.x86_64
libcublas-13-3-13.6.0.2-1.x86_64
libcufft-13-3-12.3.0.29-1.x86_64
libcurand-13-3-10.4.3.29-1.x86_64
libcusolver-13-3-12.2.6.9-1.x86_64
libcusparse-13-3-12.8.2.51-1.x86_64
libnvfatbin-13-3-13.3.29-1.x86_64
libnvjitlink-13-3-13.3.33-1.x86_64
+ cuda-toolkit-13-3-config-common / cuda-toolkit-13-config-common /
  cuda-toolkit-config-common (noarch, 13.3.29-1)
```

Все 8 — точно по §1 (сверка `rpm -q`, `verify-libs.txt`). GPG-ключ
`0x73CD9B30` импортирован (отпечаток
`129994480EC63D2789BC98E490DFED2F73CD9B30` — совпадает с §1). Скачивание
1.0 GiB, среднее 12.0 MiB/s (01m27s); «Завершено!». `dnf clean all` — 101 MiB
кэша убрано.

### 3.4. Запуск на GPU (ненагружающая проба): OK, exit 0

Один раз, маленький запуск (1024-элементный vector add, managed memory):

```
$ podman-remote run --rm --privileged --device /dev/nvidia0 cuda-precheck-libs:tmp /hello
sum got=1571328.0 expect=1571328.0
exit=0
```

`got == expect` → CUDA-ядро отработало на `/dev/nvidia0`; `--privileged` +
`--device /dev/nvidia0` — паттерн llama-cpp.service. Влияние на живую
генерацию (llama-server на других GPU/контекстах) — мигновено (один маленький
запуск).

### 3.5. ldd /hello (в контейнере): всё резолвится, «not found» нет

```
linux-vdso.so.1
libstdc++.so.6 => /lib64/libstdc++.so.6
libm.so.6 => /lib64/libm.so.6
libgcc_s.so.1 => /lib64/libgcc_s.so.1
libc.so.6 => /lib64/libc.so.6
/lib64/ld-linux-x86-64.so.2
```

**Ключевой нюанс: `libcudart.so.13` в ldd нет.** Причина (проверено
`readelf`/`strings` по тому же бинарнику в devel-образе): nvcc по умолчанию
линкует CUDA **рантайм статически** — `cudaMallocManaged`/`cudaDeviceSynchronize`
в `/hello` — определённые символы (`FUNC GLOBAL HIDDEN`, `libcudart_static_*`
встроены в бинарник), `DT_NEEDED` = только 5 стандартных C/C++-библиотек
(libstdc++, libm, libgcc_s, libc, ld-linux). Статический cudart при первом
обращении подгружает **драйвер** `libcuda.so.1` через `dlopen`. Т.е. GPU-путь
`/hello` зависит от driver userspace (`/usr/lib64/libcuda.so.1 ->
libcuda.so.610.43.03` — из drv-стадии nvidia-xorg), а не от `.so` из 8
runtime-пакетов.

Присутствие `.so` из 8 пакетов подтверждено (`ldconfig -p` + реальные файлы,
`verify-libs.txt`): все в `/usr/local/cuda-13.3/targets/x86_64-linux/lib/`
(`libcudart.so.13`, `libcublas(Lt).so.13`, `libcufft(w).so.12`,
`libcurand.so.10`, `libcusolver(Mg).so.12`, `libcusparse.so.12`,
`libnvJitLink.so.13`, `libnvfatbin.so.13`).

### 3.6. Вывод (п.6)

- **runtime-набор из 8 пакетов достаточен: добавить нечего** (нет ни одного
  «not found»). Все 8 ставятся dnf'ом по точным NEVRA (§1), все `.so`
  присутствуют и резолвятся (`ldconfig`); hello-cuda отработал на GPU (exit 0,
  `sum` совпадает), `ldd` — всё резолвится.
- **Ограничение пробы (для основной спеки):** этот hello линкует cudart
  **статически** (default nvcc) и math-библиотеки не использует, поэтому
  динамически нагружает только базовый C/C++-рантайм + драйвер (`libcuda.so.1`
  из nvidia-xorg); `.so` из 8 пакетов он не подгружает. Для динамически-линкуемого
  реального рантайма (llama.cpp) эти `.so` присутствуют и доступны в ld-кэше —
  пройдена проверка «установлено + присутствует + резолвится», но
   «динамическая подгрузка каждого `.so`» этим hello не покрыта (критерий брифа —
   «сборка + запуск на GPU + ldd без not found» — выполнен).

### 3.7. [доп. проба] динамическая линковка runtime-набора

Базовый hello (§3.2–3.6) линкует cudart статически и math-библиотеки не
использует, поэтому п.6 для динамически-линкуемого потребителя (llama.cpp) не
покрывался. Добавлена вторая проба `hello_dyn`: тот же vector-add + реальная
работа math-библиотек; собирается с `-cudart shared` (cudart — динамический) и
явными `-l` по math-библиотекам.

- **Компиляция (devel-образ):**
  `nvcc -cudart shared -ccbin g++-15 -arch=sm_86 -lcublas -lcufft -lcurand -lcusolver -lcusparse -o hello_dyn hello_dyn.cu`
  → OK (ELF 64-bit, dynamically linked, 34272 B). `DT_NEEDED` (CUDA) =
  libcudart.so.13, libcublas.so.13, libcufft.so.12, libcurand.so.10,
  libcusolver.so.12, libcusparse.so.12 (+ стандартные C/C++).
- **По библиотекам (что делает каждый вызов):**
  - **cublas — функционально**: `cublasCreate` + `cublasSgemm` (C = A·B, A 2×3,
    B 3×2, column-major, alpha=1/beta=0) + `cublasDestroy` — сверено с известным
    ответом `C = {{58,64},{139,154}}`.
  - **cufft — функционально**: `cufftPlan1d` + `cufftExecC2C` (прямое БПФ-4
    импульса [1,0,0,0]) + `cufftDestroy` — сверено с [1,1,1,1].
  - **curand — функционально**: `curandCreateGenerator` +
    `curandSetPseudoRandomGeneratorSeed` + `curandGenerateUniform` (1024) +
    `curandDestroyGenerator` — все значения в [0,1).
  - **cusolver — create/destroy** (в этой версии заголовка нет
    `cusolverDnGetVersion`): `cusolverDnCreate` + `cusolverDnDestroy` — для
    попадания в DT_NEEDED.
  - **cusparse — create/destroy + версия**: `cusparseCreate` +
    `cusparseGetVersion` (12802) + `cusparseDestroy` — для DT_NEEDED + факт
    версии.
- **Запуск на GPU (один раз, `--rm --privileged --device /dev/nvidia0`):**

  ```
  vecadd   got=1571328.0 expect=1571328.0 OK
  cublas   C={58,139,64,154} expect={58,139,64,154} maxerr=0 OK
  cufft    out={1,0},{1,0},{1,0},{1,0} maxerr=0 OK
  curand   n=1024 range=[0.0017,0.9994] out_of_range=0 OK
  cusolver cusolverDnCreate/Destroy OK
  cusparse cusparseCreate/Destroy OK, version=12802
  TOTAL OK (failures=0)
  exit=0
  ```
- **ldd /hello_dyn (CUDA-строки; всё резолвится, «not found» нет):**

  ```
  libcublas.so.13    => /usr/local/cuda/targets/x86_64-linux/lib/libcublas.so.13
  libcufft.so.12     => /usr/local/cuda/targets/x86_64-linux/lib/libcufft.so.12
  libcurand.so.10    => /usr/local/cuda/targets/x86_64-linux/lib/libcurand.so.10
  libcusolver.so.12  => /usr/local/cuda/targets/x86_64-linux/lib/libcusolver.so.12
  libcusparse.so.12  => /usr/local/cuda/targets/x86_64-linux/lib/libcusparse.so.12
  libcudart.so.13    => /usr/local/cuda/targets/x86_64-linux/lib/libcudart.so.13
  libcublasLt.so.13  => /usr/local/cuda/targets/x86_64-linux/lib/libcublasLt.so.13    (транзитивно, через libcublas)
  libnvJitLink.so.13 => /usr/local/cuda/targets/x86_64-linux/lib/libnvJitLink.so.13   (транзитивно, через libcusolver)
  ```
  (`/usr/local/cuda` → `/usr/local/cuda-13.3`, как в §2.4.)
- **Какие из 8 `.so`-пакетов подгружаются динамически** (в ldd всего 8 `.so`:
  6 прямых `DT_NEEDED` + 2 транзитивных):

  | пакет | `.so` в ldd | как |
  |---|---|---|
  | cuda-cudart | libcudart.so.13 | прямая |
  | libcublas | libcublas.so.13, libcublasLt.so.13 | прямая + транзитивно |
  | libcufft | libcufft.so.12 | прямая |
  | libcurand | libcurand.so.10 | прямая |
  | libcusolver | libcusolver.so.12 | прямая |
  | libcusparse | libcusparse.so.12 | прямая |
  | libnvjitlink | libnvJitLink.so.13 | транзитивно (через libcusolver) |
  | libnvfatbin | — (не в дереве) | **не подгружается** |

  `libnvfatbin.so.13` — «листок»: ни один из 8 `.so` не имеет его в
  `DT_NEEDED` (проверено `readelf -d` по всем), поэтому этим бинарником не
  подгружается; сам `.so` при этом установлен и резолвится (§3.5).
- **Скорректированный вывод по п.6:** runtime-набор из 8 пакетов **достаточен**
  для реального (динамически-линкуемого) CUDA-программы; **добавлять нечего**.
  7 из 8 пакетов реально подгружаются (в ldd 8 `.so`: 6 прямых + 2 транзитивных)
  и резолвятся в `/usr/local/cuda-13.3/...`; ключевые вызовы (cublas Sgemm,
  cufft БПФ, curand) отработали на GPU с верным ответом (exit 0). Единственный
  не подгруженный этим бинарником `libnvfatbin.so.13` установлен и доступен в
  ld-кэше — динамический потребитель, которому он нужен, его найдёт.

## 4. Сборка NCCL v2.31.2-1 на 13.3.1 (пп.7–8)

NCCL `v2.31.2-1` (тег `NCCL_REF` из `Makefile`, commit `7b83616`) клонирован
в стедж (`nccl15`/`nccl16`, `--depth 1`) и собран дважды в
`cuda-precheck-devel:tmp`; команда сборки — дословно из
`nvidia-nccl-devel.containerfile` (prod-значения `CUDA_ARCH=86`):
`make -j$(nproc) src.build CUDA_HOME=/usr/local/cuda-13.3
NVCC_GENCODE="-gencode=arch=compute_86,code=sm_86"` (`nproc=28`). Общие
факты обеих сборок: nvcc `V13.3.73` (release 13.3); `CXX` — `g++-15
(GCC) 15.3.1 20260722 (Red Hat 15.3.1-1)` в п.7 и дефолт F44 `g++ (GCC)
16.2.1 20260819 (Red Hat 16.2.1-2)` в п.8. Логи (стедж): `nccl15.log`
(успех), `nccl16.log` (ошибка).

- **g++15 (п.7): успех.** `CXX=g++-15` — базовый эквивалент прод-стадии
  (как в прод-цепи на 13.2). `exit=0`, время сборки **132 s (~2m12s)**.
  Артефакты на месте: `build/lib/libnccl.so` → `libnccl.so.2` →
  `libnccl.so.2.31.2` (57 976 256 B), `build/lib/libnccl_static.a`
  (125 034 122 B), `build/include/nccl.h` (44 549 B), `build/bin/ncclparam`.
  Конец `nccl15.log`:

  ```
  Linking    libnccl.so.2.31.2                   > /s/nccl15/build/lib/libnccl.so.2.31.2
  Archiving  libnccl_static.a                    > /s/nccl15/build/lib/libnccl_static.a
  Linking    ncclparam                           > /s/nccl15/build/bin/ncclparam
  -rw-r--r--. 1 root root      44549 сен  1 18:30 build/include/nccl.h
  lrwxrwxrwx. 1 root root         12 ... libnccl.so -> libnccl.so.2
  lrwxrwxrwx. 1 root root         17 ... libnccl.so.2 -> libnccl.so.2.31.2
  -rwxr-xr-x. 1 root root  57976256 ... libnccl.so.2.31.2
  ```

- **g++16 (п.8): ошибка (fail-loud на первом `.cu`).** Без `CXX`-override —
  дефолт F44 `g++ (GCC) 16.2.1 20260819 (Red Hat 16.2.1-2)`. `exit=2`
  (make `Error 2`); упала за **12 s**, не дошла до линковки
  (`build/lib/` пуст, `libnccl.so` **не** собрано). nvcc 13.3.1 отклоняет
  host-компилятор новее 15 — `#error` в `host_config.h` на самой первой
  компиляции `.cu` (дословно из `nccl16.log`):

  ```
  In file included from /usr/local/cuda-13.3/bin/../targets/x86_64-linux/include/cuda_runtime.h:82,
                   from <command-line>:
  /usr/local/cuda-13.3/bin/../targets/x86_64-linux/include/crt/host_config.h:137:2: error: #error -- unsupported GNU version! gcc versions later than 15 are not supported! The nvcc flag '-allow-unsupported-compiler' can be used to override this version check; however, using an unsupported host compiler may cause compilation failure or incorrect run time execution. Use at your own risk.
  make: *** [Makefile:45: src.build] Error 2
  ```

  Факт: **CUDA 13.3.1 поддерживает gcc не новее 15** (ровно как и 13.2);
  дефолтный g++16 Fedora 44 принимается nvcc только через
  `-allow-unsupported-compiler` (помечено «use at your own risk» — не для
  прод).

- **Вывод для GCC_VER: остаётся `15`** (не переворачивать на 16).
  `GCC_VER ?= 15` в `Makefile` — единственный рабочий вариант на 13.3.1:
  containerfile уже явным образом ставит `gcc${GCC_VER}{,-c++}` и шлёт
  `CXX=g++-${GCC_VER}`. Переворот на дефолтный 16 сломал бы сборку NCCL (и
  любой CUDA-кода) сразу на первом `.cu`. При миграции 13.2 → 13.3.1 пин
   g++15 **не меняется** — он и есть причина, по которой прод-цепь
   собирается.

## 5. llama.cpp cmake-configure на 13.3.1 (п.9)

llama.cpp master клонирован в стедж (`$S/llama`, `--depth 1`), cmake-configure
выполнен в образе `cuda-precheck-nccl:tmp` (база `cuda-precheck-devel:tmp` +
NCCL из Task 4, размещённый в `/usr/local/cuda-13.3/{lib64,include}` ровно как
в прод-цепи). Флаги — дословно из `llama-cpp-cuda.containerfile`, адаптированные
под `/usr/local/cuda` (вместо прод-значения `/opt/cuda`): `NVCC →
/usr/local/cuda/bin/nvcc`, `NCCL_ROOT → /usr/local/cuda`, `CUDA_ARCH=86`,
`C/CXX = gcc-15/g++-15`, `GGML_CUDA=ON GGML_CUDA_FORCE_MMQ=ON
GGML_CUDA_NCCL=ON`, `-GNinja`. Лог (стедж): `llama-configure.log`.

- **llama.cpp: `b356fa2624643b6d5753162ae43efff8cdd4d8cb`** (HEAD master,
  2026-09-01 20:16:07 +0200, «kv-cells: look up the n-gram history in the
  sequence position index (#28040)»); working tree чистый
  (`git status --porcelain` пуст, `build/` — в `.gitignore`). cmake в выводе
  пометил `ggml commit: b356fa2-dirty` (короткий хэш совпадает с HEAD;
  суффикс `-dirty` добавлен cmake). `ggml version: 0.22.0`,
  `llama.cpp version: 0.3.0-dev`.

- **Configure: ошибка** — не на детекции CUDA/NCCL, а на **Generate step**.
  Фаза configure прошла (`-- Configuring done (4.5s)`), упал Generate (дословно
  из лога):
  ```
  CMake Error at ggml/src/ggml-cuda/CMakeLists.txt:182 (target_link_libraries):
    Target "ggml-cuda" links to:

      CUDA::cuda_driver

    but the target was not found.  Possible reasons include:

      * There is a typo in the target name.
      * A find_package call is missing for an IMPORTED target.
      * An ALIAS target is missing.

  -- Generating done (0.2s)
  CMake Generate step failed.  Build files cannot be regenerated correctly.
  ```
  Причина: в dnf-образе toolkit **нет `libcuda.so` (драйвер)**. Модуль CMake
  `FindCUDAToolkit` создаёт imported-таргет `CUDA::cuda_driver` только при
  обнаружении `libcuda.so`; `find / -name 'libcuda.so*'` — пусто. Toolkit
  шлёт стубы для cublas/cublasLt/cufft/cufftw/curand/cusolver/cusolverMg/
  cusparse/nvJitLink в `lib64/stubs/`, но **стуба `libcuda.so` нет**
  (проверено в `cuda-precheck-nccl:tmp`).

- **CUDA version по выводу cmake: `13.3.73`** (nvcc `V13.3.73`, release 13.3,
  = NEVRA toolkit 13.3.1). Дословно из лога:
  ```
  -- Found CUDAToolkit: /usr/local/cuda/targets/x86_64-linux/include;/usr/local/cuda/targets/x86_64-linux/include/cccl (found version "13.3.73")
  -- The CUDA compiler identification is NVIDIA 13.3.73 with host compiler GNU 15.3.1
  ```
  CUDA backend включён (`-- Including CUDA backend`), host-компилятор GNU 15.3.1
  принят nvcc.

- **NCCL: определён по NCCL_ROOT=/usr/local/cuda — да.** Дословно из лога:
  ```
  -- Found NCCL: /usr/local/cuda/lib64/libnccl.so
  ```
  (`/usr/local/cuda` → `/usr/local/cuda-13.3`; `libnccl.so.2.31.2` из Task 4
  скопирован в `lib64/`, заголовки `nccl.h`/`nccl_device.h`/`nccl_device/` — в
  `include/`.)

- **Вывод для NVCC/NCCL_ROOT в основной спеке:**
  - `NVCC=/usr/local/cuda/bin/nvcc` — **работает** (CUDA backend определён,
    nvcc 13.3.73, host g++15 принят).
  - `NCCL_ROOT=/usr/local/cuda` — **работает** (NCCL найден в
    `/usr/local/cuda/lib64/libnccl.so`).
  - **Но** dnf-toolkit devel-набор **один не достаточен** для cmake-configure
    llama.cpp: не хватает `libcuda.so` (драйвер) → `CUDA::cuda_driver` не
    создаётся → Generate step падает. В прод-цепи `libcuda.so` приходит из
    драйверских user-space-библиотек: `nvidia-cuda-devel.containerfile`
    копирует `libcuda*` из `nvidia-xorg`-образа в `/usr/lib64`.
  - **Фикс для основной спеки:** добавить в devel-образ пакет
    `cuda-driver-devel` (NEVRA `cuda-driver-devel-13-3-13.3.29-1.x86_64`,
    48 KB) — он даёт **стуб** `libcuda.so` в
    `/usr/local/cuda-13.3/targets/x86_64-linux/lib/stubs/libcuda.so`
    (проверено `dnf repoquery -l`). Это build-time-эквивалент прод-драйвера:
    для *сборки* достаточно стуба, реальный `libcuda.so.1` подхватывается из
    драйвера на хосте в рантайме.

- **Итог по п.9:** NVCC и NCCL_ROOT по `/usr/local/cuda` на 13.3.1 определены
  корректно (CUDA 13.3.73, NCCL найден по `NCCL_ROOT`), но **полный
  cmake-configure не проходит** на toolkit-only образе из-за отсутствующего
  `libcuda.so`; основной спеке нужен `cuda-driver-devel` (стуб драйвера) в
  devel-наборе, чтобы Generate step дошёл до генерации build-файлов.

### [доп. проба] cuda-driver-devel (libcuda.so stub)

Гипотеза из п.5 (добавить `cuda-driver-devel`) **проверена и подтверждена**.
Собран второй throwaway-образ `cuda-precheck-nccl2:tmp` (`40b88382905e`) —
дословно `cuda-precheck-nccl:tmp` (`529faf73b3ac`) плюс одна строка
`RUN dnf install -y --setopt=install_weak_deps=False
cuda-driver-devel-13-3-13.3.29-1 && dnf clean all` (weakdeps off, из
NVIDIA-репо). Установка тянет ровно 1 пакет (46 KiB загрузка / 139.5 KiB на
диске), без Recommends и без апгрейдов/удалений.

- **NEVRA:** `cuda-driver-devel-13-3-13.3.29-1.x86_64` (имя файла в инвентаре
  §1); в dnf5 отображается как `cuda-driver-devel-13-3-0:13.3.29-1.x86_64`
  (name = `cuda-driver-devel-13-3`, version = `13.3.29`, release = `1`, epoch 0
  — в имени файла опущен). Это тот же пакет, версия не расходится. Размер:
  48 KB (инвентарь) ≈ 46 KiB download / 139.5 KiB installed (dnf5). Даёт
  **стуб** `libcuda.so` в
  `/usr/local/cuda-13.3/targets/x86_64-linux/lib/stubs/libcuda.so` — единственный
  `libcuda.so` в образе (в `cuda-precheck-nccl:tmp` его не было).
- **Итог configure: УСПЕХ.** Тот же cmake (флаги дословно из брифа, тот же клон
  `b356fa26…`), новый образ — `exit 0`. Дословно из `llama-configure-cddev.log`:
  ```
  -- Found CUDAToolkit: /usr/local/cuda/targets/x86_64-linux/include;/usr/local/cuda/targets/x86_64-linux/include/cccl (found version "13.3.73")
  -- The CUDA compiler identification is NVIDIA 13.3.73 with host compiler GNU 15.3.1
  -- Found NCCL: /usr/local/cuda/lib64/libnccl.so
  -- Including CUDA backend
  -- Configuring done (4.4s)
  -- Generating done (0.2s)
  -- Build files have been written to: /s/llama/build
  ```
  CUDA version (`13.3.73`) и NCCL-детекция (`/usr/local/cuda/lib64/libnccl.so`)
  **идентичны** упавшему прогону; Generate step теперь доходит до генерации
  build-файлов. **Единственный дельта** между упавшим (`cuda-precheck-nccl:tmp`)
  и успешным (`cuda-precheck-nccl2:tmp`) прогоном — пакет-стуб `cuda-driver-devel`:
  появление `libcuda.so` позволяет `FindCUDAToolkit` создать imported-таргет
  `CUDA::cuda_driver`, на котором упал первый прогон.
- **Скорректированный вывод для основной спеки:** devel-набор = **7
  закреплённых NEVRA (§1) + `cuda-driver-devel-13-3-13.3.29-1`** — проверено: на
  этом наборе llama.cpp cmake-configure на 13.3.1 **проходит** (CUDA 13.3.73,
  NCCL по `NCCL_ROOT=/usr/local/cuda`). Факт ошибки Generate step из п.5 остаётся
  в силе для toolkit-only образа (без `cuda-driver-devel`).

## 6. Таблица решений (заполнена)

Заполнено по фактам §1–§5; структура строк — из пре-чек-спеки
(«Таблица решений»). Каждая строка: выбранный исход (А/Б) + факт-основание.

| Пункт | Выбранный исход | Факт-основание (по отчёту) |
|---|---|---|
| dnf5 × репо (1) | **А** — работает (makecache + install OK, GPG auto-import) | §2 п.1: `.repo` доставлен curl'ом из URL, `dnf makecache` (50.1 KiB), ключ `0x73CD9B30` импортирован автоматически из удалённого `gpgkey` (отпечаток совпадает с §1), транзакция 134 (devel) / 144 (weak) пакета «Заверчено!». ⚠ Факты §2.1 (makecache exit 0 при частичном сбое метаданных; отклонение базового зеркала) перенесены в §7 (риски 3 и 4). |
| NEVRA (2) | **А** — точный NEVRA ставится; несуществующий — fail-loud (exit=1) | §2 п.2: 7 NEVRA devel-набора установлены ровно указанных версий; bad NEVRA → «Нет соответствия для аргумента», exit=1. **Коррекция: пин — БЕЗ суффикса `.rpm`** (на dnf5 суффикс `.rpm` = путь к локальному файлу, не NEVRA репо → «No such file or directory», exit=1; пример из пре-чек-спеки `cuda-nvcc-13-3-13.3.73-1.x86_64.rpm` как пин работать не будет). |
| weakdeps (3) | **А** — дельта зафиксирована → `install_weak_deps=False` в основной спеке | §2 п.3: дельта = 10 пакетов / 12.0 MiB (314 vs 324 пакета), все — базовый тулчейн (7zip, bat, unzip, …), **ни одного CUDA-пакета** → weakdeps не несут нужного, отключаем. |
| размещение (4) | **Б** (ближайший к шаблону) — libs НЕ в `/usr/lib64` | §2 п.4: факт не совпадает дословно ни с А, ни с Б шаблона — всё под `/usr/local/cuda-13.3/targets/x86_64-linux/lib` (+ hard-link'd `lib64`, одни иноды), в `/usr/lib64` только `*.pc` devel. `/etc/ld.so.conf.d`-входы (`000_cuda.conf`, `987_cuda-13.conf`) — **SHIPPED BY THE PACKAGES**; `/usr/local/cuda` — через package alternatives (`/etc/alternatives/cuda`). **Собственный ldconfig conf не нужен** (поставлен пакетами). |
| runtime-набор (6) | **А** — набор из 8 пакетов достаточен, добавлять нечего | §3.6 + §3.7: 7/8 `.so` подгружаются динамически (ldd, 6 прямых `DT_NEEDED` + 2 транзитивных), Sgemm/cufft — точный ответ на GPU (exit 0), `libnvfatbin.so.13` — присутствующий лист (не в `DT_NEEDED` ни одного `.so`, но установлен и резолвится в ld-кэше). |
| NCCL g++15 (7) | **А** — собирается → базовая конфигурация сохраняется | §4: `CXX=g++-15` exit=0, время **132 s**, `libnccl.so.2.31.2` (57 976 256 B) + `libnccl_static.a` + `ncclparam` на месте. |
| NCCL g++16 (8) | **Б** — ошибка → оставить `GCC_VER=15` | §4: fail-loud на первом `.cu` — nvcc 13.3.1 `host_config.h` `#error -- unsupported GNU version! gcc versions later than 15 are not supported!`, exit=2 (12 s, до линковки не дошла) → **GCC_VER остаётся 15** (переворот на дефолтный 16 сломал бы NCCL/CUDA-код). |
| llama configure (9) | **А** — configure OK; `NVCC`/`NCCL_ROOT` = `/usr/local/cuda` | §5: CUDA 13.3.73 (nvcc V13.3.73, host g++15 принят), NCCL найден по `NCCL_ROOT=/usr/local/cuda` (`/usr/local/cuda/lib64/libnccl.so`). **НО** (§5 + доп. проба): devel-набор = 7 пин NEVRA + `cuda-driver-devel-13-3-13.3.29-1` (стуб `libcuda.so` → `CUDA::cuda_driver`); на toolkit-only образе (7 NEVRA) Generate step падает. |

## 7. Риски и факты для основной спеки

Что корректируется в дизайне (набор пакетов, ldconfig-стратегия, пути,
`GCC_VER`, способы пиннинга) — по заполненной таблице §6:

1. **Devel-набор = 7 NEVRA (§1) + `cuda-driver-devel-13-3-13.3.29-1`** (проверено
   в §5, доп. проба). 8-й пакет — обязательный, не опциональный: без стуба
   `libcuda.so` cmake `FindCUDAToolkit` не создаёт `CUDA::cuda_driver` → Generate
   step падает; со стубом configure проходит (exit 0). NEVRA — `13.3.29-1`, в dnf5
   отображается `cuda-driver-devel-13-3-0:13.3.29-1.x86_64`.
2. **NEVRA-пины — БЕЗ суффикса `.rpm`** (семантика dnf5, §2 п.2). Суффикс `.rpm`
   заставляет dnf5 трактовать аргумент как путь к локальному файлу, а не как NEVRA
   репо. Пины в containerfile основной спеки пишутся без `.rpm` (пример пиннинга из
   пре-чек-спеки как пин не работает).
3. **`dnf makecache` — exit 0 при частичном сбое загрузки метаданных** (§2.1). В логе
   `Curl error (28)` / `Usable URL not found` и «Metadata cache created.» — `set -e`
   containerfile это не ловит; ошибка проявляется только в транзакции
   («Нет соответствия для аргумента»). **`makecache`-exit 0 — не health-check**
   наличия метаданных.
4. **Забитое базовое Fedora-зеркало `mirror.getpods.ru` (`/etc/dnf/vars/repobaseurl`
   в `nvidia-base:44`) мертво со сборочного хоста** (§2.1): HTTP `Curl error (28)`
   (hang), HTTPS rc=60 (сертификат). Пре-чек перенаправлял только базовые репо
   (`fedora`, `updates`) на `mirror.yandex.ru` (работало, ~33 МБ/с, новый лейаут
   F44). **Риск: прод-стадия `nvidia-base` наследует мёртвое зеркало → любая
   прод-пересборка упрёт в тот же тупик.** Это отдельно от дизайна NVIDIA-репо —
   основная спека (или отдельный фикс) должна зафиксировать рабочее базовое
   зеркало.
5. **`GCC_VER` остаётся 15** (nvcc 13.3.1 отклоняет gcc16, §4). Дефолтный g++16 F44
   принимается nvcc только через `-allow-unsupported-compiler` (помечено «use at your
   own risk» — не для прод). Переворот дефолта на 16 сломал бы сборку NCCL и любого
   CUDA-кода сразу на первом `.cu`. Пин g++15 при миграции 13.2 → 13.3.1 **не
   меняется** — он и есть причина, по которой прод-цепь собирается.
6. **ldconfig — без собственного conf/ln в containerfiles** (§2 п.4). Пакетные
   `/etc/ld.so.conf.d`-входы (`000_cuda.conf` → `/usr/local/cuda/targets/x86_64-linux/lib`,
   `987_cuda-13.conf` → `/usr/local/cuda-13/targets/x86_64-linux/lib`) + альтернативный
   symlink `/usr/local/cuda` (через `/etc/alternatives/cuda`) — поставлены пакетами.
   Собственный ldconfig conf/ln в containerfile **не нужен** (проверить в основном
   дизайне, что containerfile их не дублируют и не ломают).
7. **Размеры для бюджета основной спеки** (§2 п.5, §3.3, контекст пре-чек-спеки):
   - devel-набор (weakdeps off): **3.60 GiB** installed (29 пакета);
   - runtime-набор: **~1.0 GiB download** / **~2.6 GiB** image c driver userspace
     из `nvidia-xorg:610.43.03` (`cuda-precheck-libs:tmp` = 2.63 GB);
   - vs старые redist-образы: `nvidia-cuda-devel:13.2` **8.72 ГБ**,
     `nvidia-cuda-libs:13.2` **5.3 ГБ**, `llama-cpp-cuda:13.2` **5.46 ГБ** —
     дnf-вариант существенно меньше.

## 8. Throwaway-инвентарь (удалён)

Cleanup выполнен в Task 6 (`CRE=podman-remote`). Все 5 throwaway-образов
`cuda-precheck-*:tmp` + стедж — удалены, подтверждено отсутствием.

**Образы** (размер до удаления; `nccl2` добавлен в доп. пробе §5):

| ID | Тег | Размер |
|---|---|---|
| `40b88382905e` | `cuda-precheck-nccl2:tmp` | 5.36 GB |
| `529faf73b3ac` | `cuda-precheck-nccl:tmp` | 5.34 GB |
| `f397ab43b7f3` | `cuda-precheck-libs:tmp` | 2.63 GB |
| `2b580f62fab9` | `cuda-precheck-devel-weak:tmp` | 4.98 GB |
| `ee8106ecc3ce` | `cuda-precheck-devel:tmp` | 4.97 GB |

Удаление: `$CRE rmi <тег>` по одному, каждый `exit=0`
(`cuda-precheck-devel:tmp` — `Untagged`, его слои — общая база для
`devel-weak`/`nccl`/`nccl2` — GC'нулись при удалении последних ссылок).
Проверка после: `$CRE images | grep cuda-precheck` → нет совпадений.

**Стедж на хосте:** `/run/host/tmp/cuda-precheck` (580 M, ~50 файлов: логи
сборок/проб, `*.containerfile`, `nevra-inventory.txt`, `repo-index.html`,
`cuda-fedora44.repo`, `nvidia-gpg.asc`, `hello.cu`/`hello`, `hello_dyn.cu`/
`hello_dyn`, клоны `llama/`, `nccl15/`, `nccl16/`). Удаление: `rm -rf
/run/host/tmp/cuda-precheck` (литеральный путь, допустимо без safe-rm по
rm-rf-guard), `exit=0`. Проверка после: каталог отсутствует, в
`/run/host/tmp` cuda-записей нет.
