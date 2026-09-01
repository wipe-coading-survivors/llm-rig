# Мемо: fix wave — findings final-ревью этапа 24 (CUDA dnf-репо)

- Дата: 02.09.2026
- Тип: точечные фиксы по verdict «With fixes» final-ревью ветки
  `stage24-cuda-repo` (один коммит); мемо — по домашнему правилу
  (изменения `scripts/`/containerfiles вне плана).

## Что и почему

- (а) бамп `:13.2` → `:13.3` в debug-скриптах (`repro-llama-block3-run.sh`,
  `llama-run.sh`): cleanup live-окна `*:13.2` оставлял бы tracked-скрипты
  на несуществующие образы; спека видела только sanitizer-путь — omission.
- (б) `curl -f` в обоих CUDA-containerfiles (+ 16i-строки и спека):
  fail-loud 404 вместо кривого `.repo`.
- (в) статический 16i-чек кавычек `CUDA_*_SET` build-аргов: fake-CRE
  `echo "build $*"` не различает кавычки — без чека де-кавычка в Makefile
  упала бы только в реальном buildah.
- (г) устаревший комментарий в test-no-sensitive (example.com-плейсхолдер).

## Верификация

- Полный сьют (13 скриптов `scripts/test-*.sh`), 02.09.2026: 13/13
  зелёных, все `# pass=… fail=0`. test-makefile-graph: pass=330 fail=0
  (на b945eaa — pass=328; +2 = новые ассерции quoted SET build-arg).
