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
exec claude --dangerously-skip-permissions
