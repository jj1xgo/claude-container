#!/bin/bash
# GIT_ASKPASS ヘルパー。github.com 宛の Username/Password プロンプトにのみ、
# ファイルから just-in-time で応答する。それ以外は fail-closed（exit 1）。
# ホスト判定はクォートで囲まれた URL 全体への正規表現アンカーで行い、
# 'https://github.com.evil.com' のような前方一致すり抜けを防ぐ。
set -euo pipefail

prompt="$1"
token_file=/home/node/.config/claude-container/secrets/noexport/GIT_PUSH_TOKEN
github_host_re="^https://(x-access-token@)?github\.com(/.*)?\$"

case "$prompt" in
  Username\ for\ *)
    url=$(printf '%s' "$prompt" | sed -n "s/^Username for '\\(.*\\)': *\$/\\1/p")
    [[ "$url" =~ $github_host_re ]] || exit 1
    printf '%s\n' "x-access-token"
    ;;
  Password\ for\ *)
    url=$(printf '%s' "$prompt" | sed -n "s/^Password for '\\(.*\\)': *\$/\\1/p")
    [[ "$url" =~ $github_host_re ]] || exit 1
    [ -f "$token_file" ] || exit 1
    printf '%s\n' "$(tr -d '\n\r' <"$token_file")"
    ;;
  *)
    exit 1
    ;;
esac
