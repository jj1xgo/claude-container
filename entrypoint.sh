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

# GitHub Issues 書き込み用トークン（GH_TOKEN_FILE、compose.yml が読み取り専用マウント）。
# ファイルから読んでここで export する（compose.yml の environment: に直接書かない）ことで、
# トークンが `podman inspect`/`podman compose config` のコンテナ設定に残らないようにする。
# gh CLI は GH_TOKEN 環境変数を自動認識するため gh auth login は不要。
GH_TOKEN_MOUNT=/home/node/.config/claude-container/gh-token
if [ -s "$GH_TOKEN_MOUNT" ]; then
  GH_TOKEN="$(tr -d '\n\r' <"$GH_TOKEN_MOUNT")"
  export GH_TOKEN
fi

# 汎用シークレットディレクトリ（SECRETS_DIR、compose.yml が読み取り専用マウント）。
# 中の各ファイルを「ファイル名＝環境変数名」として export する。上記レガシー GH_TOKEN
# export の後に置くのは仕様: 競合時（レガシー設定済み + secrets/GH_TOKEN 併置）は
# レガシーが勝ち、secrets 側は下記の既存変数チェックで WARNING を出してスキップする。
# 未設定時は compose.yml の /dev/null フォールバックによりマウント先がキャラクタ
# デバイスになるため、[ -d ] で確実に偽判定できる。
#
# noexport/ サブディレクトリの規約（README「SECRETS_DIR」節参照）: 下のループは
# [ -f ] 判定でサブディレクトリを黙ってスキップするため、noexport/ 配下のファイルは
# ここで export されず「マウントされるがファイルとしてのみ読める秘密」になる。
# 意図的な仕様であり、noexport/ 用の追加処理は不要（各利用者がファイルを明示的に読む）。
SECRETS_MOUNT=/home/node/.config/claude-container/secrets
if [ -d "$SECRETS_MOUNT" ]; then
  for secret_file in "$SECRETS_MOUNT"/*; do
    # 空ディレクトリ時はグロブがリテラル文字列のまま残るため [ -f ] で弾く
    # （サブディレクトリ・壊れた symlink も同時に除外できる）。
    [ -f "$secret_file" ] || continue
    secret_name=$(basename "$secret_file")
    if ! [[ "$secret_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      echo "WARNING: secrets: '$secret_name' is not a valid environment variable name; skipping" >&2
      continue
    fi
    # ${!name+x} は set 判定（値でなく「存在するか」）。set-but-empty な compose
    # 変数（例: CLAUDE_CONTAINER_NO_FIREWALL）や bash の readonly シェル変数
    # （UID 等）も捕捉できるため、非空判定（${!name:-}）より安全側に倒せる。
    if [ -n "${!secret_name+x}" ]; then
      echo "WARNING: secrets: '$secret_name' is already set in the environment; skipping" >&2
      continue
    fi
    secret_value=$(tr -d '\n\r' <"$secret_file")
    export "$secret_name=$secret_value"
  done
fi

# git push の opt-in 配線（README「git push を使う場合」節参照）。
# SECRETS_DIR/noexport/GIT_PUSH_TOKEN が存在するときのみ GIT_ASKPASS を export する。
# トークン自体は export しない（git-askpass.sh がファイルから都度読む）ため、
# GIT_PUSH_TOKEN という環境変数は Claude 本体やその子プロセスの環境には現れない。
if [ -f "$SECRETS_MOUNT/noexport/GIT_PUSH_TOKEN" ]; then
  export GIT_ASKPASS=/usr/local/bin/git-askpass.sh
fi

exec claude --dangerously-skip-permissions
