#!/bin/bash
# コンテナイメージのビルド・動作確認スクリプト
# 結果は .claude/test-results/YYYY-MM-DD_HHMMSS.log に保存される
# --clean オプションでテスト用イメージと dangling イメージを削除

IMAGE="localhost/claude-test"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/.claude/test-results"
LOG_FILE="${LOG_DIR}/$(date +%Y-%m-%d_%H%M%S).log"
PASS=0
FAIL=0

if [[ "${1:-}" == "--clean" ]]; then
  echo "Removing test image: ${IMAGE}"
  podman rmi "${IMAGE}" 2>/dev/null && echo "Done." || echo "Image not found, skipping."
  echo "Pruning dangling images..."
  podman image prune -f
  exit 0
fi

mkdir -p "$LOG_DIR"

log() {
  echo "$@" | tee -a "$LOG_FILE"
}

check() {
  local desc="$1"; shift
  local output status
  output=$("$@" 2>&1) && status=0 || status=$?
  if [ "$status" -eq 0 ]; then
    printf "  %-52s[PASS]\n" "$desc" | tee -a "$LOG_FILE"
    PASS=$((PASS + 1))
  else
    printf "  %-52s[FAIL]\n" "$desc" | tee -a "$LOG_FILE"
    FAIL=$((FAIL + 1))
  fi
  printf "%s\n" "$output" >> "$LOG_FILE"
}

log "========================================"
log "  Build & Smoke Test  $(date)"
log "  Log: $LOG_FILE"
log "========================================"
log ""

log "## 静的チェック"
check "bash -n claude-container" bash -n "${SCRIPT_DIR}/claude-container"
check "podman compose config" env \
  CLAUDE_CONTAINER_DIR="$SCRIPT_DIR" BUILD_CONTEXT_DIR="$SCRIPT_DIR/.build-context/test" CONTEXT="$SCRIPT_DIR" \
  podman compose -f "${SCRIPT_DIR}/compose.yml" config
log ""

# claude-container の stage_build_context() 相当。Dockerfile.claude が要求する
# entrypoint.sh・init-firewall.sh・allowed-domains.txt・github-meta.json を
# 一時ディレクトリへ集約する（packages.txt/requirements.txt は呼び出し側で
# 個別にコピーする — プロジェクト上書きテストではソースが変わるため）。
# リポジトリルート直下には github-meta.json が存在しないため、直接 $SCRIPT_DIR
# をビルドコンテキストに渡すと COPY で失敗する（2026-07-02 の GitHub meta
# スナップショット化以降の既存の不整合、Issue #1 対応の動作確認時に検出・修正）。
stage_common_context() {
  local dest="$1"
  cp "${SCRIPT_DIR}/entrypoint.sh" "$dest/entrypoint.sh"
  cp "${SCRIPT_DIR}/init-firewall.sh" "$dest/init-firewall.sh"
  cp "${SCRIPT_DIR}/allowed-domains.txt" "$dest/allowed-domains.txt"

  local sibling
  if curl -fsS https://api.github.com/meta 2>/dev/null | tee "$dest/github-meta.json" | jq -e '.web and .api and .git' >/dev/null 2>&1; then
    return 0
  fi
  sibling=$(ls -t "${SCRIPT_DIR}"/.build-context/*/github-meta.json 2>/dev/null | head -1)
  if [[ -n "$sibling" ]]; then
    echo "WARNING: live GitHub meta fetch failed; reusing $sibling" >&2
    cp "$sibling" "$dest/github-meta.json"
  else
    echo "ERROR: github-meta.json を取得できず、既存スナップショットも見つかりません" >&2
    return 1
  fi
}

log "## ビルド"
BUILD_STAGE_DIR="$(mktemp -d)"
stage_common_context "$BUILD_STAGE_DIR"
cp "${SCRIPT_DIR}/packages.txt" "$BUILD_STAGE_DIR/packages.txt"
cp "${SCRIPT_DIR}/requirements.txt" "$BUILD_STAGE_DIR/requirements.txt"
check "podman build --no-cache" podman build --no-cache \
  -f "${SCRIPT_DIR}/Dockerfile.claude" -t "$IMAGE" "$BUILD_STAGE_DIR"
rm -rf "$BUILD_STAGE_DIR"
log ""

log "## イメージサイズ"
podman images "$IMAGE" --format \
  "  Repository: {{.Repository}}\n  Tag:        {{.Tag}}\n  Size:       {{.Size}}" \
  | tee -a "$LOG_FILE"
log ""

log "## Claude Code ツール"
check "claude --version" podman run --rm "$IMAGE" claude --version
check "gh --version"     podman run --rm "$IMAGE" gh --version
check "jq --version"     podman run --rm "$IMAGE" jq --version
log ""

log "## .claude-container.d によるパッケージ上書き"
OVERRIDE_IMAGE="localhost/claude-test-override"
OVERRIDE_PROJECT_DIR="$(mktemp -d)"
OVERRIDE_CONTEXT_DIR="$(mktemp -d)"
mkdir -p "$OVERRIDE_PROJECT_DIR/.claude-container.d"
echo "htop" > "$OVERRIDE_PROJECT_DIR/.claude-container.d/packages.txt"

# claude-container スクリプトが行うステージング（プロジェクト側 packages.txt を
# ビルドコンテキストへ集約する処理）を模して検証する
stage_common_context "$OVERRIDE_CONTEXT_DIR"
cp "$OVERRIDE_PROJECT_DIR/.claude-container.d/packages.txt" "$OVERRIDE_CONTEXT_DIR/packages.txt"
cp "${SCRIPT_DIR}/requirements.txt" "$OVERRIDE_CONTEXT_DIR/requirements.txt"

check "podman build (override context)" podman build --no-cache \
  -f "${SCRIPT_DIR}/Dockerfile.claude" -t "$OVERRIDE_IMAGE" "$OVERRIDE_CONTEXT_DIR"
check "htop が入っている"  podman run --rm "$OVERRIDE_IMAGE" which htop

podman rmi "$OVERRIDE_IMAGE" 2>/dev/null
rm -rf "$OVERRIDE_PROJECT_DIR" "$OVERRIDE_CONTEXT_DIR"
log ""

log "## .claude-container.d/env の非混入確認（ランタイム設定はビルド時に焼き込まない）"
ENV_PROJECT_DIR="$(mktemp -d)"
ENV_STAGE_DIR="$(mktemp -d)"
mkdir -p "$ENV_PROJECT_DIR/.claude-container.d"
echo "GH_TOKEN_FILE=~/.config/claude-container/dummy-gh-token" > "$ENV_PROJECT_DIR/.claude-container.d/env"

# claude-container の stage_build_context() を模して、packages.txt/requirements.txt/
# allowed-domains.txt のみをコピーする（env は対象外）。env がここに含まれていないこと
# を確認することで、ステージングループが誤ってワイルドカード化されるリグレッションを検出する。
for f in packages.txt requirements.txt allowed-domains.txt; do
  cp "${SCRIPT_DIR}/${f}" "$ENV_STAGE_DIR/${f}"
done

check ".claude-container.d/env がビルドコンテキストに含まれない" \
  bash -c "[[ ! -e '$ENV_STAGE_DIR/env' ]]"

rm -rf "$ENV_PROJECT_DIR" "$ENV_STAGE_DIR"
log ""

log "## TZ"
check "date (UTC確認)"   podman run --rm "$IMAGE" date
log ""

log "========================================"
log "  結果: PASS=${PASS}  FAIL=${FAIL}"
log "========================================"
log ""
log "## bash history 永続化確認（手動）"
log "  以下を順番に実行してください："
log "  1. mkdir -p /tmp/test-claude-history"
log "  2. podman run --rm -it --userns=keep-id -v /tmp/test-claude-history:/workspace/.claude ${IMAGE} bash"
log "  3. コンテナ内で任意のコマンドを実行（例: ls, echo hello）"
log "  4. exit でコンテナを終了"
log "  5. cat /tmp/test-claude-history/bash_history で履歴を確認"
