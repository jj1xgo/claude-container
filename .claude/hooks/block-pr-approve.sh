#!/usr/bin/env bash
# block-pr-approve.sh — PreToolUse hook (Bash)
# gh の「PR 承認」操作（gh pr review --approve / -a、および生 API 経由の
# event=APPROVE）だけをブロックし、--comment / --request-changes 等その他の
# PR 操作・gh コマンドはすべて通す。
#
# 目的（issue #10）: コンテナ内トークン（Pull requests: write を持つが
# Contents: write は持たない）による自律承認が、auto-merge 経由でマージ境界を
# 迂回するリスクを機構的に防ぐ「2枚目の壁」。1枚目の壁はリポジトリの
# auto-merge 無効維持（CLAUDE.md セキュリティモデル節）。
#
# 脅威モデルは「Claude 自身のうっかり自律承認の抑止」。変数展開・コマンド置換
# 等による意図的な難読化までは防げない（公式もコマンド文字列パターンは fragile
# と明記）。誤検知は必ず安全方向（承認をブロックする側）へ倒す設計とする。
#
# 注意: このファイルのコメント行を「# shellcheck」で始めないこと
# （directive として解釈されパースエラーになる）。
set +e

reason='gh pr review --approve（PR 承認）の自律実行は禁止です（issue #10）。承認は auto-merge の引き金になりうるため、承認とマージは人間がホスト側で行います。レビュー補助が目的なら --comment / --request-changes を使ってください。'

emit_deny() {
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  else
    # jq 不在時も承認だけは確実に止める（fail-safe）。reason に " \ % を含めない前提。
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$1"
  fi
  exit 0
}

input=$(cat)

if command -v jq >/dev/null 2>&1; then
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
  [ -z "$cmd" ] && exit 0
  # クォートされた文字列（--body 等の値）を除去し、body テキスト中の
  # "-a" 等による誤検知を減らす。
  stripped=$(printf '%s' "$cmd" | sed -E 's/"[^"]*"//g; s/'"'"'[^'"'"']*'"'"'//g')
else
  # jq 不在は環境異常。承認判定は生 JSON 文字列に対して継続する（fail-safe）。
  cmd=$input
  stripped=$input
fi

# gh コマンドでなければ即通過（高速パス）
printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]])gh([[:space:]]|$)' || exit 0

# (1) gh pr review の承認フラグ（--approve / -a を含む短オプションクラスタ）
#     -c / -r / -b / -F 等 a を含まない短オプションは通す。
if printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]])gh[[:space:]]+pr[[:space:]]+review([[:space:]]|$)'; then
  if printf '%s' "$stripped" | grep -qE '(^|[[:space:]])(--approve([[:space:]]|$)|-[[:alpha:]]*a[[:alpha:]]*([[:space:]]|$))'; then
    emit_deny "$reason"
  fi
fi

# (2) 生 API 経由の承認（.../pulls/<N>/reviews に event=APPROVE を渡す形）
if printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]])gh[[:space:]]+api' \
   && printf '%s' "$stripped" | grep -qiE 'pulls/[0-9]+/reviews' \
   && printf '%s' "$stripped" | grep -qE 'event=APPROVE'; then
  emit_deny "$reason"
fi

exit 0
