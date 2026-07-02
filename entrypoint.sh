#!/bin/bash
# エグレス制限（deny-by-default 許可リスト）。失敗時は起動しない（fail-closed）。
# 無効化する場合は利用側プロジェクトの .claude-container に CLAUDE_CONTAINER_NO_FIREWALL=1 を書く。
if [ "${CLAUDE_CONTAINER_NO_FIREWALL:-}" = "1" ]; then
  echo "WARNING: egress firewall disabled (CLAUDE_CONTAINER_NO_FIREWALL=1); container has unrestricted network access" >&2
else
  if ! sudo /usr/local/bin/init-firewall.sh; then
    echo "ERROR: firewall setup failed; refusing to start (set CLAUDE_CONTAINER_NO_FIREWALL=1 to opt out)" >&2
    exit 1
  fi
fi

for f in \
  /home/node/.claude/plugins/installed_plugins.json \
  /home/node/.claude/plugins/known_marketplaces.json; do
  [ -f "$f" ] && sed -i "s|/home/[^/]*/\.claude|/home/node/.claude|g" "$f"
done
exec claude --dangerously-skip-permissions
