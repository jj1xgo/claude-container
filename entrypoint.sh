#!/bin/bash
# エグレス制限（deny-by-default 許可リスト）。失敗時は起動しない（fail-closed）。
# 無効化する場合は利用側プロジェクトの .claude-container.d/env に CLAUDE_CONTAINER_NO_FIREWALL=1 を書く。
if [ "${CLAUDE_CONTAINER_NO_FIREWALL:-}" = "1" ]; then
  echo "WARNING: egress firewall disabled (CLAUDE_CONTAINER_NO_FIREWALL=1); container has unrestricted network access" >&2
else
  if ! sudo /usr/local/bin/init-firewall.sh; then
    echo "ERROR: firewall setup failed; refusing to start (set CLAUDE_CONTAINER_NO_FIREWALL=1 to opt out)" >&2
    exit 1
  fi
  # CDN-backed allowed domains (e.g. behind CloudFront) can rotate their IPs on
  # TTLs as short as ~13s, well within a long session. init-firewall.sh's
  # startup resolution is a one-shot snapshot, so refresh it in the background
  # to keep up. `&` backgrounds this in a subshell; `exec claude` below only
  # replaces this script's own process image, so the subshell survives as its
  # child. Output goes to /tmp (not the bind-mounted ~/.claude) since it's
  # session-local noise, and is kept off the shared tty (compose.yml sets
  # tty: true for claude's interactive UI) to avoid corrupting the display.
  # (The container's actual PID1 is tini, set via Dockerfile.claude's
  # ENTRYPOINT — this script and the claude process it execs into both run as
  # tini's child, so signals podman forwards on exit land on a live process.)
  (
    while true; do
      sleep 15
      sudo /usr/local/bin/init-firewall.sh --refresh-domains
    done
  ) >>/tmp/claude-firewall-refresh.log 2>&1 &
fi

for f in \
  /home/node/.claude/plugins/installed_plugins.json \
  /home/node/.claude/plugins/known_marketplaces.json; do
  [ -f "$f" ] && sed -i "s|/home/[^/]*/\.claude|/home/node/.claude|g" "$f"
done

# MCP監査ゲート（stdio型サーバーの検知＋TTY確認、claude-container-ops#21）。
# .mcp.json（project-scoped、Claude Code標準機能により自動ロードされる）のうち
# command フィールドを持つ stdio 型サーバーは、npx 等のネットワーク取得を経ずに
# リポジトリ同梱コードとして実行できるため、ファイアウォール・再ビルドという
# 既存の人間ゲートの対象外になる。セッション開始と同時に人間・モデルどちらの
# 判断も挟まず実行され、export 済みトークン等を読めてしまうため、ここで TTY
# 確認を挟む（http/sse 型は接続先をファイアウォールが審査するため対象外）。
# 環境変数による opt-out は意図的に設けない: .claude-container.d/env は全キー
# 無条件で export されるため、悪意あるリポジトリ自身が opt-out 変数を書けて
# しまいゲートとして無意味になる（CLAUDE_CONTAINER_NO_FIREWALL と同じ迂回経路）。
MCP_CONFIG=/workspace/.mcp.json
if [ -f "$MCP_CONFIG" ]; then
  if ! stdio_servers=$(jq -r '
    (.mcpServers // {}) | to_entries[] | select(.value.command != null) |
    "\(.key)\t\(.value.command)\t\((.value.args // []) | join(" "))"
  ' "$MCP_CONFIG" 2>/dev/null); then
    echo "ERROR: failed to parse $MCP_CONFIG as JSON; refusing to start" >&2
    exit 1
  fi
  if [ -n "$stdio_servers" ]; then
    # TOFU承認記録との照合（claude-container#28）。ホスト側 claude-container が
    # 事前に対話承認済みなら、その正規化ハッシュが :ro マウントされている
    # （/etc/claude-container/mcp-approved-hash、compose.yml参照）。正規化jqフィルタは
    # ホスト側 check_mcp_approval() と同一でなければならない（変更時は両ファイルを同期）。
    approved_hash_file=/etc/claude-container/mcp-approved-hash
    current_hash=$(jq -S -c '[(.mcpServers // {}) | to_entries[] | select(.value.command != null)]' "$MCP_CONFIG" 2>/dev/null | sha256sum | cut -c1-64)
    recorded_hash=""
    if [ -f "$approved_hash_file" ]; then
      recorded_hash=$(cat "$approved_hash_file" 2>/dev/null || true)
    fi
    if [ -n "$recorded_hash" ] && [ "$recorded_hash" = "$current_hash" ]; then
      echo "INFO: MCP audit: stdio servers pre-approved (hash match); OK" >&2
    else
      echo "WARNING: $MCP_CONFIG declares stdio-type MCP server(s). Their code runs immediately at session start (no per-tool-call confirmation) and can read all exported secrets:" >&2
      if [ -n "$recorded_hash" ]; then
        echo "  (note: definition changed since the last host-side approval)" >&2
      fi
      while IFS=$'\t' read -r mcp_name mcp_cmd mcp_args; do
        echo "  - $mcp_name: $mcp_cmd $mcp_args" >&2
      done <<<"$stdio_servers"
      printf 'Allow these MCP servers to start? [y/N] ' >&2
      if ! read -r mcp_confirm </dev/tty; then
        echo "ERROR: no interactive TTY available to confirm MCP stdio servers; refusing to start" >&2
        exit 1
      fi
      case "$mcp_confirm" in
        y | Y | yes | YES | Yes) ;;
        *)
          echo "ERROR: MCP stdio server confirmation declined; refusing to start" >&2
          exit 1
          ;;
      esac
    fi
  else
    echo "INFO: MCP audit: $MCP_CONFIG contains no stdio servers; OK" >&2
  fi
fi

# GitHub トークン配線（v4〜、claude-container#24）。SECRETS_DIR は exposure 軸で設計する:
# 「常時使える（export される）権限は最小に、広い権限は明示操作の壁の向こうに」。
#   - SECRETS_DIR/export/<NAME> ... コンテナ内で環境変数として export される（issues 限定PAT等）
#   - SECRETS_DIR/<NAME>（直下）  ... export されない。ファイルとしてのみ読める（メインPAT等）
# v3 以前とは直下/export の意味が逆転している（旧: 直下=export、noexport/=非export）。
# 後方互換エイリアスは持たない（claude-container 側の fail-closed ガードが旧レイアウト
# 残存を検出する）。GH_TOKEN の ambient export は撤廃済み — gh は既定で未認証になる。
SECRETS_MOUNT=/home/node/.config/claude-container/secrets

# SECRETS_DIR/export/ 配下の各ファイルを「ファイル名＝環境変数名」として export する。
# 未設定時は compose.yml の /dev/null フォールバックによりマウント先がキャラクタ
# デバイスになるため、[ -d ] で確実に偽判定できる。
EXPORT_MOUNT="$SECRETS_MOUNT/export"
if [ -d "$EXPORT_MOUNT" ]; then
  for secret_file in "$EXPORT_MOUNT"/*; do
    # 空ディレクトリ時はグロブがリテラル文字列のまま残るため [ -f ] で弾く
    # （サブディレクトリ・壊れた symlink も同時に除外できる）。
    [ -f "$secret_file" ] || continue
    secret_name=$(basename "$secret_file")
    if ! [[ "$secret_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      echo "WARNING: secrets/export: '$secret_name' is not a valid environment variable name; skipping" >&2
      continue
    fi
    # ${!name+x} は set 判定（値でなく「存在するか」）。set-but-empty な compose
    # 変数（例: CLAUDE_CONTAINER_NO_FIREWALL）や bash の readonly シェル変数
    # （UID 等）も捕捉できるため、非空判定（${!name:-}）より安全側に倒せる。
    if [ -n "${!secret_name+x}" ]; then
      echo "WARNING: secrets/export: '$secret_name' is already set in the environment; skipping" >&2
      continue
    fi
    secret_value=$(tr -d '\n\r' <"$secret_file")
    export "$secret_name=$secret_value"
  done
fi

# メインPAT（Contents RW 等を含む広い権限）の配線。SECRETS_DIR 直下に置かれ export
# されないため、GH_TOKEN 等の環境変数としては値が現れない。entrypoint はパスだけを
# GITHUB_MAIN_PAT_FILE として export し、利用者（gh CLI 呼び出し・git-askpass.sh）が
# 都度明示的にファイルを読む。配置は export 走査ループの後（SECRETS_DIR/export/ 配下に
# 同名ファイルを置かれても本体設定に乗っ取られないようにするため）。
if [ -f "$SECRETS_MOUNT/GITHUB_MAIN_PAT" ]; then
  export GITHUB_MAIN_PAT_FILE="$SECRETS_MOUNT/GITHUB_MAIN_PAT"

  # git push の opt-in 配線（README「git push を使う場合」節参照）。トークン自体は
  # export しない（git-askpass.sh が上記ファイルから都度読む）ため、GITHUB_MAIN_PAT
  # という環境変数は Claude 本体やその子プロセスの環境には現れない。
  export GIT_ASKPASS=/usr/local/bin/git-askpass.sh
  # GITCONFIG_FILE 経由で持ち込まれた credential.helper（例: store）が askpass で
  # 得たトークンを ~/.git-credentials へ平文保存してしまうのを防ぐ（issue #25）。
  # GIT_CONFIG_* 環境変数は全 config ファイル（system/XDG/global 含む）より後に
  # 適用され、空文字列は helper リストのリセットという公式仕様（git help
  # gitcredentials）。マウントされた ~/.gitconfig は read-only のため
  # `git config --global` での上書きはできず、この手段が唯一の書き換え方法。
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0=credential.helper
  export GIT_CONFIG_VALUE_0=""
fi

exec claude --dangerously-skip-permissions
