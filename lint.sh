#!/bin/bash
# 集約 lint target: bash -n + shellcheck + podman compose config をまとめて実行する。
# 対象の bash スクリプトは git ls-files（追跡済み + 未追跡。gitignore 対象は除く）+
# shebang 判定で動的に決定する
# （ハードコードのファイルリストを持たない — 追加/削除時のリスト同期漏れを構造的に防ぐ）。
set -uo pipefail

cd "$(dirname "$0")" || exit 1

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "ERROR: shellcheck が見つかりません。sudo apt-get install shellcheck でインストールしてください。" >&2
  exit 1
fi

status=0

scripts=()
while IFS= read -r f; do
  [ -f "$f" ] || continue
  head -n1 "$f" 2>/dev/null | grep -qE '^#!/bin/bash|^#!/usr/bin/env bash' && scripts+=("$f")
done < <(git ls-files -co --exclude-standard)

# .claude/ は private ops リポジトリとして nested git 管理される場合がある
# （メンテナのローカル環境限定。第三者のクローンには存在せず何もしない）。
if [ -d .claude/.git ]; then
  while IFS= read -r f; do
    [ -f ".claude/$f" ] || continue
    head -n1 ".claude/$f" 2>/dev/null | grep -qE '^#!/bin/bash|^#!/usr/bin/env bash' && scripts+=(".claude/$f")
  done < <(git -C .claude ls-files -co --exclude-standard)
fi

if [ "${#scripts[@]}" -eq 0 ]; then
  echo "ERROR: 対象の bash スクリプトが1つも見つかりません（git ls-files + shebang 判定）。" >&2
  exit 1
fi

echo "対象スクリプト (${#scripts[@]}):"
printf '  %s\n' "${scripts[@]}"

for f in "${scripts[@]}"; do
  bash -n "$f" || status=1
done

shellcheck "${scripts[@]}" || status=1

if command -v podman >/dev/null 2>&1; then
  podman compose -f compose.yml config >/dev/null || status=1
else
  echo "WARNING: podman が見つからないため compose config 検証をスキップしました（コンテナ内開発時は想定内）。" >&2
fi

if [ "$status" -eq 0 ]; then
  echo "lint OK"
else
  echo "lint NG: 上記の違反を解消してください。" >&2
fi
exit "$status"
