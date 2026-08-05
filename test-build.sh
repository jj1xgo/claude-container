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

# --- 層1: validate-build-input.sh のベクタ表・契約異常系テスト（claude-container#34） ---
# ハーネス本体は1箇所にだけ書き、--validator-only と通常実行の両方から呼ぶ
# （複製すると中核設計2で排除したドリフトを検査側に再導入する）。
# 関数定義は早期ディスパッチより前に置く — bash は関数定義文を実行して初めて
# 関数を登録するため、定義をこれより後ろに置くと呼び出しが command not found に
# なり、しかも rc=0 で終わる（第7版の独立検証で実測確認済み）。
#
# ベクタ表フォーマット: kind|class|input|expected
#   class: accept(rc0、outfile が expected と完全一致) /
#          exclude(rc0、outfile が空) / reject(rc1、outfile が番兵のまま不変)
#   input/expected は printf '%b' で展開するエスケープ表記
#   （\t \r \n \000 \357\273\277=BOM \343\200\200=U+3000）を含みうる。
#   件数: packages 34（有効9・除外7・無効18）／requirements 35（有効11・除外4・無効20）
#   ／総計69／reject 38（計画「ベクタ表」節と1行＝1ベクタで対応、件数はここから機械導出）。
VBI_VECTORS=(
  # packages 有効(9)
  'packages|accept|htop\n|htop\n'
  'packages|accept|python3-pip\n|python3-pip\n'
  'packages|accept|libc6\n|libc6\n'
  'packages|accept|ab\n|ab\n'
  'packages|accept|g++\n|g++\n'
  'packages|accept|htop \n|htop\n'
  'packages|accept|htop\t\n|htop\n'
  'packages|accept|htop\r\n|htop\n'
  'packages|accept|htop|htop'
  # packages 除外(7)
  'packages|exclude|# comment\n|'
  'packages|exclude|  # foo\n|'
  'packages|exclude|\t# foo\n|'
  'packages|exclude|\n|'
  'packages|exclude|\r\n|'
  'packages|exclude| \r\n|'
  'packages|exclude|\t\r\n|'
  # packages 無効(18・reject)
  'packages|reject|-o\n|'
  'packages|reject|htop -o Foo=bar\n|'
  'packages|reject|htop --reinstall\n|'
  'packages|reject|Htop\n|'
  'packages|reject|../etc\n|'
  'packages|reject|htop=1.2\n|'
  'packages|reject|htop # note\n|'
  'packages|reject|tini-\n|'
  'packages|reject|sudo-\n|'
  'packages|reject|htop.\n|'
  'packages|reject|r\n|'
  'packages|reject|lib_a\n|'
  'packages|reject|htop:amd64\n|'
  'packages|reject|\343\200\200htop\n|'
  'packages|reject|\357\273\277htop\n|'
  'packages|reject|ht\rop\n|'
  'packages|reject|htop\r\r\n|'
  'packages|reject|ht\000op\n|'
  # requirements 有効(11)
  'requirements|accept|requests\n|requests\n'
  'requirements|accept|requests[socks]>=2.0,<3\n|requests[socks]>=2.0,<3\n'
  'requirements|accept|ruff==0.4.*\n|ruff==0.4.*\n'
  'requirements|accept|pkg===1.0\n|pkg===1.0\n'
  'requirements|accept|r\n|r\n'
  'requirements|accept|requests  # comment\n|requests\n'
  'requirements|accept|requests#garbage\n|requests\n'
  'requirements|accept|requests\r\n|requests\n'
  'requirements|accept|requests\r#comment\n|requests\n'
  'requirements|accept|pkg==1.0\r#x\n|pkg==1.0\n'
  'requirements|accept|requests|requests'
  # requirements 除外(4)
  'requirements|exclude|# comment\n|'
  'requirements|exclude|  # foo\n|'
  'requirements|exclude|\n|'
  'requirements|exclude|\r\n|'
  # requirements 無効(20・reject)
  'requirements|reject|requests\r\r\n|'
  'requirements|reject|req\ruests\n|'
  'requirements|reject|\rrequests\n|'
  'requirements|reject|\357\273\277requests\n|'
  'requirements|reject|req\000uests\n|'
  'requirements|reject|-e git+https://example.com/x.git#egg=x\n|'
  'requirements|reject|--index-url https://example.com/simple\n|'
  'requirements|reject|git+https://example.com/x.git#egg=x\n|'
  'requirements|reject|pkg @ https://example.com/x.whl\n|'
  'requirements|reject|./local\n|'
  'requirements|reject|-r other.txt\n|'
  'requirements|reject|pkg; python_version<"3.9"\n|'
  'requirements|reject|pkg --config-settings x==y\n|'
  'requirements|reject|pkg --global-option x==y\n|'
  'requirements|reject|pkg\t--config-settings\tx==y\n|'
  'requirements|reject|pkg ~= 1.4\n|'
  'requirements|reject|pkg[,a]\n|'
  'requirements|reject|pkg[a,]\n|'
  'requirements|reject|pkg[a,,b]\n|'
  'requirements|reject|pkg[]\n|'
)

# 層1本体: ベクタ表全69件＋件数アサーション4件を実行する。
run_validator_layer1() {
  local vbi="${SCRIPT_DIR}/validate-build-input.sh"
  local t infile outfile expfile
  t=$(mktemp -d) || { log "  [FAIL] layer1: mktemp -d failed"; FAIL=$((FAIL + 1)); return; }
  infile="$t/in"; outfile="$t/out"; expfile="$t/expected"

  local entry kind class input expected actual_rc
  local pkg_count=0 req_count=0 reject_count=0 total_count=0

  for entry in "${VBI_VECTORS[@]}"; do
    IFS='|' read -r kind class input expected <<< "$entry"
    total_count=$((total_count + 1))
    [ "$kind" = "packages" ] && pkg_count=$((pkg_count + 1))
    [ "$kind" = "requirements" ] && req_count=$((req_count + 1))
    [ "$class" = "reject" ] && reject_count=$((reject_count + 1))

    printf 'SENTINEL' > "$outfile"
    printf '%b' "$input" > "$infile"
    actual_rc=0
    LC_ALL=C sh "$vbi" "$kind" "$infile" "$outfile" >/dev/null 2>&1 || actual_rc=$?

    case "$class" in
      accept)
        printf '%b' "$expected" > "$expfile"
        if [ "$actual_rc" -eq 0 ] && cmp -s "$expfile" "$outfile"; then
          PASS=$((PASS + 1))
        else
          FAIL=$((FAIL + 1))
          log "  [FAIL] layer1 accept kind=$kind input=[$input] rc=$actual_rc"
        fi
        ;;
      exclude)
        if [ "$actual_rc" -eq 0 ] && [ ! -s "$outfile" ]; then
          PASS=$((PASS + 1))
        else
          FAIL=$((FAIL + 1))
          log "  [FAIL] layer1 exclude kind=$kind input=[$input] rc=$actual_rc"
        fi
        ;;
      reject)
        printf 'SENTINEL' > "$expfile"
        if [ "$actual_rc" -eq 1 ] && cmp -s "$expfile" "$outfile"; then
          PASS=$((PASS + 1))
        else
          FAIL=$((FAIL + 1))
          log "  [FAIL] layer1 reject kind=$kind input=[$input] rc=$actual_rc"
        fi
        ;;
    esac
  done

  # 件数アサーション4件（抽出漏れ・区切り記号依存を機械的に検出する。数は
  # 計画「ベクタ表」節の表から機械導出した値で、転記しない）。
  if [ "$pkg_count" -eq 34 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); log "  [FAIL] layer1 packages件数=$pkg_count (期待34)"; fi
  if [ "$req_count" -eq 35 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); log "  [FAIL] layer1 requirements件数=$req_count (期待35)"; fi
  if [ "$total_count" -eq 69 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); log "  [FAIL] layer1 総数=$total_count (期待69)"; fi
  if [ "$reject_count" -eq 38 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); log "  [FAIL] layer1 reject件数=$reject_count (期待38)"; fi

  rm -rf "$t"
}

# 終了コード契約の異常系・outfile 保全ケース（E1〜E8・P1、計画「4つ組では踏めない
# ケース」節のケースID付き表と1対1対応。1行＝1ケース＝PASS 1件）。
run_validator_contract() {
  local vbi="${SCRIPT_DIR}/validate-build-input.sh"
  local t infile outfile expfile actual_rc
  t=$(mktemp -d) || { log "  [FAIL] contract: mktemp -d failed"; FAIL=$((FAIL + 1)); return; }
  infile="$t/in"; outfile="$t/out"; expfile="$t/expected"

  # E1: 未知の kind → rc2・既存 outfile の番兵不変
  printf 'SENTINEL' > "$outfile"
  printf 'htop\n' > "$infile"
  actual_rc=0
  sh "$vbi" domains "$infile" "$outfile" >/dev/null 2>&1 || actual_rc=$?
  printf 'SENTINEL' > "$expfile"
  if [ "$actual_rc" -eq 2 ] && cmp -s "$expfile" "$outfile"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); log "  [FAIL] contract E1 rc=$actual_rc"; fi

  # E2: 引数不足 → rc2（outfile 引数が無いため状態確認は適用しない）
  actual_rc=0
  sh "$vbi" packages >/dev/null 2>&1 || actual_rc=$?
  if [ "$actual_rc" -eq 2 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); log "  [FAIL] contract E2 rc=$actual_rc"; fi

  # E3: 引数過多 → rc2・既存 outfile の番兵不変（E2 と違い有効な outfile が実在する）
  printf 'SENTINEL' > "$outfile"
  printf 'htop\n' > "$infile"
  actual_rc=0
  sh "$vbi" packages "$infile" "$outfile" extra >/dev/null 2>&1 || actual_rc=$?
  printf 'SENTINEL' > "$expfile"
  if [ "$actual_rc" -eq 2 ] && cmp -s "$expfile" "$outfile"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); log "  [FAIL] contract E3 rc=$actual_rc"; fi

  # E4: infile が存在しない → rc2・番兵不変
  printf 'SENTINEL' > "$outfile"
  rm -f "$t/nonexistent"
  actual_rc=0
  sh "$vbi" packages "$t/nonexistent" "$outfile" >/dev/null 2>&1 || actual_rc=$?
  printf 'SENTINEL' > "$expfile"
  if [ "$actual_rc" -eq 2 ] && cmp -s "$expfile" "$outfile"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); log "  [FAIL] contract E4 rc=$actual_rc"; fi

  # E5: infile が読めない（chmod 000）→ rc2・番兵不変
  printf 'SENTINEL' > "$outfile"
  printf 'htop\n' > "$infile"
  chmod 000 "$infile"
  actual_rc=0
  sh "$vbi" packages "$infile" "$outfile" >/dev/null 2>&1 || actual_rc=$?
  chmod 644 "$infile"
  printf 'SENTINEL' > "$expfile"
  if [ "$actual_rc" -eq 2 ] && cmp -s "$expfile" "$outfile"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); log "  [FAIL] contract E5 rc=$actual_rc"; fi

  # E6: infile と outfile が同一パス → rc2・infile 不変（in-place 置換なし）
  printf 'htop \n' > "$t/same"
  actual_rc=0
  sh "$vbi" packages "$t/same" "$t/same" >/dev/null 2>&1 || actual_rc=$?
  printf 'htop \n' > "$expfile"
  if [ "$actual_rc" -eq 2 ] && cmp -s "$expfile" "$t/same"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); log "  [FAIL] contract E6 rc=$actual_rc"; fi

  # E7: outfile のディレクトリへ一時ファイルを作れない → rc2（outfile は未作成）
  printf 'htop\n' > "$infile"
  actual_rc=0
  sh "$vbi" packages "$infile" "/nonexistent-dir-vbi-e7/packages.norm" >/dev/null 2>&1 || actual_rc=$?
  if [ "$actual_rc" -eq 2 ] && [ ! -e "/nonexistent-dir-vbi-e7/packages.norm" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); log "  [FAIL] contract E7 rc=$actual_rc"; fi

  # E8: 作業用一時ディレクトリを作れない（TMPDIR 経由で誘発）→ rc2・番兵不変
  printf 'SENTINEL' > "$outfile"
  printf 'htop\n' > "$infile"
  actual_rc=0
  TMPDIR="/nonexistent-tmpdir-vbi-e8" sh "$vbi" packages "$infile" "$outfile" >/dev/null 2>&1 || actual_rc=$?
  printf 'SENTINEL' > "$expfile"
  if [ "$actual_rc" -eq 2 ] && cmp -s "$expfile" "$outfile"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); log "  [FAIL] contract E8 rc=$actual_rc"; fi

  # P1: outfile がシンボリックリンク＋正当な入力 → rc0・リンク先ファイルが不変
  # （置き換わるのはリンクの名前だけ。mv -f の帰結として意図した挙動）
  printf 'TARGET-ORIGINAL' > "$t/target.dat"
  ln -sf "$t/target.dat" "$t/link.norm"
  printf 'htop\n' > "$infile"
  actual_rc=0
  sh "$vbi" packages "$infile" "$t/link.norm" >/dev/null 2>&1 || actual_rc=$?
  printf 'TARGET-ORIGINAL' > "$expfile"
  if [ "$actual_rc" -eq 0 ] && cmp -s "$expfile" "$t/target.dat"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); log "  [FAIL] contract P1 rc=$actual_rc"; fi

  rm -rf "$t"
}

# 層2: 配線の回帰条件（Dockerfile.claude が validate-build-input.sh を正しく
# 使っているか。「スクリプトが正しい」ことと「Dockerfile がそれを使っている」こと
# は別、claude-container#34）。
# アンカー規則（実測に基づく設計判断。実装コメントとして残す）:
#   - apt-get install・packages.txt を単独のアンカーにしない
#     （現行 Dockerfile で4論理行にヒットし判別力がゼロになる）
#   - 「論理行に /tmp/packages.txt が現れないこと」という否定条件は使えない
#     （T2 が検証呼び出しを同一 RUN 内に置くため、validator の引数として
#     /tmp/packages.txt が必ず現れる。この否定条件はどんな正しい実装に対しても偽になる）
#   - 判定は「install へ入力を供給する位置」に限定する: apt-get install の
#     引数を生成するコマンド置換のリダイレクト元・pip3 install -r の引数・
#     空判定 [ -s ... ] の被検査パスの3点が .norm を指し .txt を指さないことを見る
run_validator_layer2() {
  local dockerfile="${SCRIPT_DIR}/Dockerfile.claude"
  local t rc
  t=$(mktemp -d) || { log "  [FAIL] layer2: mktemp -d failed"; FAIL=$((FAIL + 1)); return; }

  # 論理行化。パイプの終了コードに委ねず中間ファイルで各段の rc を判定する
  # （実装制約9・10・12と同じ制約がハーネス側にも及ぶ）。
  # (1) CR 除去 (2) 行継続中でも先頭非空白が # の物理行はコメント除去
  # (3) 末尾 \ の行を次行へ連結。本リポジトリの整形規約に対応する簡易論理行化
  # であり、Dockerfile パーサ相当を主張しない（ヒアドキュメントは対象外）。
  rc=0
  sed -e 's/\r$//' "$dockerfile" > "$t/step1" || rc=$?
  if [ "$rc" -ne 0 ]; then log "  [FAIL] layer2: sed(CR除去) failed rc=$rc"; FAIL=$((FAIL + 1)); rm -rf "$t"; return; fi

  rc=0
  grep -v '^[[:space:]]*#' "$t/step1" > "$t/step2" || rc=$?
  if [ "$rc" -ge 2 ]; then log "  [FAIL] layer2: grep(コメント除去) failed rc=$rc"; FAIL=$((FAIL + 1)); rm -rf "$t"; return; fi

  awk '{ cur = $0
         if (sub(/\\[[:space:]]*$/, "", cur)) { acc = acc cur; next }
         print acc cur; acc = "" }
       END { if (acc != "") print acc }' "$t/step2" > "$t/logical"
  rc=$?
  if [ "$rc" -ne 0 ]; then log "  [FAIL] layer2: awk(論理行連結) failed rc=$rc"; FAIL=$((FAIL + 1)); rm -rf "$t"; return; fi

  local logical="$t/logical"
  local hits

  # 検査1: apt-get install の入力供給位置(コマンド置換のリダイレクト元)が
  # .norm を指し .txt を指さないこと
  hits=$(grep -cF '< /tmp/packages.norm)' "$logical")
  if [ "$hits" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); log "  [FAIL] layer2: packages install入力位置のヒット数=$hits (期待1)"; fi
  hits=$(grep -cF '< /tmp/packages.txt)' "$logical")
  if [ "$hits" -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); log "  [FAIL] layer2: packages installが.txtを指している(ヒット数=$hits)"; fi

  # 検査2: pip3 install -r の引数が .norm を指し .txt を指さないこと
  hits=$(grep -cF 'pip3 install -r /tmp/requirements.norm' "$logical")
  if [ "$hits" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); log "  [FAIL] layer2: requirements install引数のヒット数=$hits (期待1)"; fi
  hits=$(grep -cF 'pip3 install -r /tmp/requirements.txt' "$logical")
  if [ "$hits" -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); log "  [FAIL] layer2: requirements installが.txtを指している(ヒット数=$hits)"; fi

  # 検査3: requirements 空判定の被検査パスが .norm を指し .txt を指さないこと
  hits=$(grep -cF '[ -s /tmp/requirements.norm ]' "$logical")
  if [ "$hits" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); log "  [FAIL] layer2: requirements空判定のヒット数=$hits (期待1)"; fi
  hits=$(grep -cF '[ -s /tmp/requirements.txt ]' "$logical")
  if [ "$hits" -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); log "  [FAIL] layer2: requirements空判定が.txtを指している(ヒット数=$hits)"; fi

  # 検査4: validator 呼び出しが両 kind について存在し || exit 1 相当で握られていること
  hits=$(grep -F 'sh /tmp/validate-build-input.sh packages' "$logical" | grep -cF '|| exit 1;')
  if [ "$hits" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); log "  [FAIL] layer2: packages validator呼び出しのヒット数=$hits (期待1)"; fi
  hits=$(grep -F 'sh /tmp/validate-build-input.sh requirements' "$logical" | grep -cF '|| exit 1;')
  if [ "$hits" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); log "  [FAIL] layer2: requirements validator呼び出しのヒット数=$hits (期待1)"; fi

  # 検査5: COPY が validate-build-input.sh をイメージへ運んでいること
  hits=$(grep -cF 'COPY validate-build-input.sh /tmp/' "$logical")
  if [ "$hits" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); log "  [FAIL] layer2: COPYのヒット数=$hits (期待1)"; fi

  rm -rf "$t"
}

# 層1・層2の実行入口。--validator-only と通常実行の両方から呼ぶ（複製しない）。
run_validator_tests() {
  log "## 層1: validate-build-input.sh ベクタ表・契約異常系テスト（claude-container#34）"
  run_validator_layer1
  run_validator_contract
  log "## 層2: Dockerfile.claude 配線の回帰条件（claude-container#34）"
  run_validator_layer2
  log ""
}

if [[ "${1:-}" == "--validator-only" ]]; then
  run_validator_tests
  log "========================================"
  log "  結果: PASS=${PASS}  FAIL=${FAIL}"
  log "========================================"
  if [ "$FAIL" -eq 0 ]; then
    exit 0
  fi
  exit 1
fi

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
# entrypoint.sh・init-firewall.sh・git-askpass.sh・validate-build-input.sh・
# allowed-domains.txt・node-version.txt・codex-version.txt・allowed-ports.txt・
# github-meta.json を一時ディレクトリへ集約する（packages.txt/requirements.txt は
# 呼び出し側で個別にコピーする — プロジェクト上書きテストではソースが変わるため）。
# リポジトリルート直下には github-meta.json が存在しないため、直接 $SCRIPT_DIR
# をビルドコンテキストに渡すと COPY で失敗する（2026-07-02 の GitHub meta
# スナップショット化以降の既存の不整合、Issue #1 対応の動作確認時に検出・修正）。
stage_common_context() {
  local dest="$1"
  cp "${SCRIPT_DIR}/entrypoint.sh" "$dest/entrypoint.sh"
  cp "${SCRIPT_DIR}/init-firewall.sh" "$dest/init-firewall.sh"
  cp "${SCRIPT_DIR}/git-askpass.sh" "$dest/git-askpass.sh"
  cp "${SCRIPT_DIR}/validate-build-input.sh" "$dest/validate-build-input.sh"
  cp "${SCRIPT_DIR}/allowed-domains.txt" "$dest/allowed-domains.txt"
  : > "$dest/node-version.txt"
  : > "$dest/codex-version.txt"
  : > "$dest/allowed-ports.txt"

  local sibling
  if curl -fsS https://api.github.com/meta 2>/dev/null | tee "$dest/github-meta.json" | jq -e '.web and .api and .git' >/dev/null 2>&1; then
    return 0
  fi
  # shellcheck disable=SC2012 # パスは PROJECT_NAME（サニタイズ済み）+ 固定ファイル名のみで空白・改行を含まない
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
if stage_common_context "$BUILD_STAGE_DIR"; then
  cp "${SCRIPT_DIR}/packages.txt" "$BUILD_STAGE_DIR/packages.txt"
  cp "${SCRIPT_DIR}/requirements.txt" "$BUILD_STAGE_DIR/requirements.txt"
  check "podman build --no-cache" podman build --no-cache \
    -f "${SCRIPT_DIR}/Dockerfile.claude" -t "$IMAGE" "$BUILD_STAGE_DIR"
else
  check "podman build --no-cache (staging failed: see stderr above)" false
fi
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
if stage_common_context "$OVERRIDE_CONTEXT_DIR"; then
  cp "$OVERRIDE_PROJECT_DIR/.claude-container.d/packages.txt" "$OVERRIDE_CONTEXT_DIR/packages.txt"
  cp "${SCRIPT_DIR}/requirements.txt" "$OVERRIDE_CONTEXT_DIR/requirements.txt"
  check "podman build (override context)" podman build --no-cache \
    -f "${SCRIPT_DIR}/Dockerfile.claude" -t "$OVERRIDE_IMAGE" "$OVERRIDE_CONTEXT_DIR"
  check "htop が入っている"  podman run --rm "$OVERRIDE_IMAGE" which htop
else
  check "podman build (override context) (staging failed: see stderr above)" false
  check "htop が入っている" false
fi

podman rmi "$OVERRIDE_IMAGE" 2>/dev/null
rm -rf "$OVERRIDE_PROJECT_DIR" "$OVERRIDE_CONTEXT_DIR"
log ""

run_validator_tests

log "## packages.txt/requirements.txt ビルド時検証テスト（claude-container#34）"
# 失敗期待用ヘルパ。exit≠0 だけを assert しない — 検証段階より前のレイヤー
# （apt基盤・gh・Claudeインストール等、ネットワーク依存）の偶発失敗でも fail
# するため、stderr に検証エラーメッセージが含まれることまで assert して
# 「正しい理由で落ちた」ことを確認する。
check_fails() {
  local desc="$1"; local expect_pattern="$2"; shift 2
  local output status
  output=$("$@" 2>&1) && status=0 || status=$?
  if [ "$status" -ne 0 ] && printf '%s' "$output" | grep -qF "$expect_pattern"; then
    printf "  %-52s[PASS]\n" "$desc" | tee -a "$LOG_FILE"
    PASS=$((PASS + 1))
  else
    printf "  %-52s[FAIL]\n" "$desc" | tee -a "$LOG_FILE"
    FAIL=$((FAIL + 1))
  fi
  printf "%s\n" "$output" >> "$LOG_FILE"
}

# 陰性1: packages.txt に注入行 → ビルドが fail することを assert
NEG1_IMAGE="localhost/claude-test-neg1"
NEG1_PROJECT_DIR="$(mktemp -d)"
NEG1_CONTEXT_DIR="$(mktemp -d)"
mkdir -p "$NEG1_PROJECT_DIR/.claude-container.d"
printf 'tini-\n' > "$NEG1_PROJECT_DIR/.claude-container.d/packages.txt"
if stage_common_context "$NEG1_CONTEXT_DIR"; then
  cp "$NEG1_PROJECT_DIR/.claude-container.d/packages.txt" "$NEG1_CONTEXT_DIR/packages.txt"
  cp "${SCRIPT_DIR}/requirements.txt" "$NEG1_CONTEXT_DIR/requirements.txt"
  check_fails "陰性1: packages.txt注入行でビルドfail" "仕様外の行があります" \
    podman build -f "${SCRIPT_DIR}/Dockerfile.claude" -t "$NEG1_IMAGE" "$NEG1_CONTEXT_DIR"
else
  check "陰性1: packages.txt注入行でビルドfail (staging failed: see stderr above)" false
fi
podman rmi "$NEG1_IMAGE" 2>/dev/null
rm -rf "$NEG1_PROJECT_DIR" "$NEG1_CONTEXT_DIR"

# 陰性2: requirements.txt に --index-url ... → 同上
# （検証が pip3 の有無に依存しないため検証段階で止まる）
NEG2_IMAGE="localhost/claude-test-neg2"
NEG2_PROJECT_DIR="$(mktemp -d)"
NEG2_CONTEXT_DIR="$(mktemp -d)"
mkdir -p "$NEG2_PROJECT_DIR/.claude-container.d"
printf -- '--index-url https://evil.example/simple\n' > "$NEG2_PROJECT_DIR/.claude-container.d/requirements.txt"
if stage_common_context "$NEG2_CONTEXT_DIR"; then
  cp "${SCRIPT_DIR}/packages.txt" "$NEG2_CONTEXT_DIR/packages.txt"
  cp "$NEG2_PROJECT_DIR/.claude-container.d/requirements.txt" "$NEG2_CONTEXT_DIR/requirements.txt"
  check_fails "陰性2: requirements.txt注入行でビルドfail" "仕様外の行があります" \
    podman build -f "${SCRIPT_DIR}/Dockerfile.claude" -t "$NEG2_IMAGE" "$NEG2_CONTEXT_DIR"
else
  check "陰性2: requirements.txt注入行でビルドfail (staging failed: see stderr above)" false
fi
podman rmi "$NEG2_IMAGE" 2>/dev/null
rm -rf "$NEG2_PROJECT_DIR" "$NEG2_CONTEXT_DIR"

# 陽性1: packages.txt に python3-pip、requirements.txt に requests#garbage を置き、
# ビルドが成功することを assert（正規化済み requirements が pip に実際に受理される
# ことを検証する唯一の実行主体。陰性2件は検証段階で止まり pip に到達しない）。
# --no-cache は付けない（付けると検証レイヤに到達する前の全レイヤを毎回再ビルド
# する。python3-pip を置く以上 COPY packages.txt でキャッシュミスとなり実走する）。
POS1_IMAGE="localhost/claude-test-pos1"
POS1_PROJECT_DIR="$(mktemp -d)"
POS1_CONTEXT_DIR="$(mktemp -d)"
mkdir -p "$POS1_PROJECT_DIR/.claude-container.d"
printf 'python3-pip\n' > "$POS1_PROJECT_DIR/.claude-container.d/packages.txt"
printf 'requests#garbage\n' > "$POS1_PROJECT_DIR/.claude-container.d/requirements.txt"
if stage_common_context "$POS1_CONTEXT_DIR"; then
  cp "$POS1_PROJECT_DIR/.claude-container.d/packages.txt" "$POS1_CONTEXT_DIR/packages.txt"
  cp "$POS1_PROJECT_DIR/.claude-container.d/requirements.txt" "$POS1_CONTEXT_DIR/requirements.txt"
  check "陽性1: 正規化済みrequirementsでビルド成功" podman build \
    -f "${SCRIPT_DIR}/Dockerfile.claude" -t "$POS1_IMAGE" "$POS1_CONTEXT_DIR"
  # ビルド成功だけを assert しない — 「pip が正しく走った」と「pip 段が丸ごと
  # スキップされた」を区別できないと、空判定が元ファイル側を見る回帰が素通りする。
  check "陽性1: requestsがpipで実際にインストールされている" \
    podman run --rm "$POS1_IMAGE" python3 -c 'import requests'
else
  check "陽性1: 正規化済みrequirementsでビルド成功 (staging failed: see stderr above)" false
  check "陽性1: requestsがpipで実際にインストールされている" false
fi
podman rmi "$POS1_IMAGE" 2>/dev/null
rm -rf "$POS1_PROJECT_DIR" "$POS1_CONTEXT_DIR"
log ""

log "## .claude-container.d/env の非混入確認（ランタイム設定はビルド時に焼き込まない）"
# 模倣コピーではなく claude-container 本体の stage_build_context() を実際に実行させて
# 検証する。podman をダミー化し「イメージ未ビルド」を常に返させることでビルド分岐に
# 入らせ、実際のステージング結果（.build-context/<project>/）に env が無いことを見る。
# こうすることで、本体のステージングループが将来ワイルドカード化されるリグレッションを
# 実地で検出できる（コピー処理を模倣するだけのテストは本体が壊れても検知できない）。
ENV_TESTROOT="$(mktemp -d)"
mkdir -p "$ENV_TESTROOT/bin"
cat > "$ENV_TESTROOT/bin/podman" <<'DUMMY'
#!/bin/bash
case "$1" in
  image) [[ "$2" == "exists" ]] && exit 1 ;;
esac
exit 0
DUMMY
chmod +x "$ENV_TESTROOT/bin/podman"

ENV_PROJECT_DIR="$ENV_TESTROOT/proj"
mkdir -p "$ENV_PROJECT_DIR/.claude-container.d"
echo "[user]
	name = dummy" > "$ENV_TESTROOT/dummy-gitconfig"
echo "GITCONFIG_FILE=$ENV_TESTROOT/dummy-gitconfig" > "$ENV_PROJECT_DIR/.claude-container.d/env"

BEFORE_BUILD_CONTEXTS="$(ls -1 "${SCRIPT_DIR}/.build-context/" 2>/dev/null || true)"
PATH="$ENV_TESTROOT/bin:$PATH" "${SCRIPT_DIR}/claude-container" "$ENV_PROJECT_DIR" >/dev/null 2>&1
AFTER_BUILD_CONTEXTS="$(ls -1 "${SCRIPT_DIR}/.build-context/" 2>/dev/null || true)"
NEW_BUILD_CONTEXT="$(comm -13 <(echo "$BEFORE_BUILD_CONTEXTS" | sort) <(echo "$AFTER_BUILD_CONTEXTS" | sort) | head -1)"

if [[ -n "$NEW_BUILD_CONTEXT" ]]; then
  check ".claude-container.d/env がビルドコンテキストに含まれない" \
    bash -c "[[ ! -e '${SCRIPT_DIR}/.build-context/${NEW_BUILD_CONTEXT}/env' ]]"
  rm -rf "${SCRIPT_DIR}/.build-context/${NEW_BUILD_CONTEXT}"
else
  check ".claude-container.d/env がビルドコンテキストに含まれない" false
fi

rm -rf "$ENV_TESTROOT"
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
