#!/bin/bash
for f in \
  /home/node/.claude/plugins/installed_plugins.json \
  /home/node/.claude/plugins/known_marketplaces.json; do
  [ -f "$f" ] && sed -i "s|/home/[^/]*/\.claude|/home/node/.claude|g" "$f"
done
exec claude --dangerously-skip-permissions
