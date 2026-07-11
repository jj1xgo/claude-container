# hook判定ロジック修正: #17（block-pr-approve誤ブロック）+ #18（filed-issues応答検知の機械判定化）

## Context

- **issue #17**（bug + claude-tooling）: `.claude/hooks/block-pr-approve.sh` が Bash コマンド文字列全体への単純 grep のため、ヒアドキュメント本文中に承認コマンドを引用しただけの無関係な操作（`gh issue comment` 等）まで誤ブロックする。実害が現在進行形（issue 起票自体も伏せ字回避を強いられた）。
- **issue #18**（dotclaude-ops からの受付）: `.claude/hooks/session-start.sh` の filed-issues 応答検知が「last-comment が相手側署名か」の判定を LLM の自然言語解釈に委ねており、署名フォーマットの紛らわしさで誤判定した実例が dotclaude-ops で発生。グローバル署名ルールは既に「常に `— モデル名 (リポジトリ名)`」形式へ統一済みのため、読み手（hook）側の機械判定化のみで対応可能。
- 設計は Fable（計画セッション）が Plan サブエージェントの実測検証（mawk 1.3.4 / jq 1.7 で全エッジケース実行済み）を経て確定。

## 設計上の重要な発見（判定(2)の hardening を含める根拠）

現行の判定(2)（`gh api` + `pulls/N/reviews` + `event=APPROVE`）は、引用符除去後の `stripped` を検査するため、**引用付き `-f "event=APPROVE"` や `--input - <<EOF`（JSON 本文の `"event": "APPROVE"`）による真正の承認が最初から素通りしている**（既存 false negative、実測確認済み）。#17 の修正と同時にこれを閉じる（内容検査を raw `$cmd` に対して行い、APPROVE パターンを `event["']?\s*[:=]\s*["']?APPROVE` に拡張）。

## タスク（実行モデル: 全て Sonnet。設計判断は本計画で確定済みのため上位モデル委譲は不要）

### 1. `.claude/hooks/block-pr-approve.sh` 修正（#17）

1. **ヒアドキュメント本文除去**: jq あり分岐内で、`cmd` から awk でヒアドキュメント本文行のみを除去した `cmd_hd` を生成（開始行は保持しコマンドライン引数を消さない）。**順序が決定的**: awk（heredoc 除去）→ sed（引用符除去）の順で `stripped_hd` を作る。逆順だと `<<'EOF'`（最頻出形式）の区切り語が引用除去で消え無効化される。
   - awk 仕様（mawk/POSIX 検証済み）: `<<`/`<<-`＋`'"\` 任意クォート＋`[A-Za-z_][A-Za-z0-9_.-]*` の区切り語を FIFO キューで管理、`<<-` はタブ剥がし照合、ヒアストリング `<<<` は事前 `gsub` でマスク、終端は行完全一致
   - fail-safe: `cmd_hd` が空（awk 失敗・awk 不在）なら `cmd_hd=$cmd` にフォールバック（現行挙動＝FP側＝安全方向）。jq 不在分岐は現行どおり生 JSON を使う
2. **判定(1)**: `gh pr review` 検出・承認フラグ検出とも `$stripped_hd` に統一（現行は外側が raw `$cmd` のため `git commit -am "... gh pr review ..."` も誤 deny される実在 FP があり、これも同時解消）
3. **判定(2)（hardening 版）**: `gh api` の実行コマンド検出は `$stripped_hd`、内容検査 2 つ（`pulls/[0-9]+/reviews`・拡張 APPROVE パターン）は raw `$cmd` に対して行う。`stripped` 変数は不要になるため削除
4. **ヘッダーコメント更新**: 残存 FP（真正 `gh api` の heredoc 本文への両パターン引用、複数行ダブルクォート文字列内の承認文字列）・残存 FN（引用文字列内 `<<X` を使った意図的難読化＝既存の脅威モデル外）・判定(2)が raw `$cmd` を見る理由を文書化

### 2. `.claude/hooks/session-start.sh` 修正（#18）

1. filed-issues ブロック冒頭（L170 付近）に `SELF_REPO="claude-container"` を定義（L134 に自リポジトリ名直書きの前例あり。`$ROOT` は `/workspace` のため basename 導出不可、git remote 導出は失敗モードを増やすだけ）
2. L182-185 の jq 式を拡張（検証済みの式を使用）:
   - 署名判定は **120 文字切り詰め前**の `$lc` に対して実施。正規表現 `^[—–-]+\s*[^(]*\((?<repo>[^()]+)\)\s*$`（行頭ダッシュ必須で括弧終わりの通常文を誤判定しない）
   - `response:` フィールドを出力に追加: 署名一致かつ repo≠SELF_REPO → `yes（<repo> から応答あり）` / repo=SELF_REPO → `no（最終コメントは自リポジトリ投稿）` / 不一致 → `unknown（署名パターン不一致・要確認）`（fail-soft）/ コメント 0 件 → `no（コメントなし＝応答なし）`
   - 付随改善: 空行除去を `map(select(length>0))` → `map(select(test("\\S")))`（空白のみ行を署名行と誤認しない）
3. L337 の指示文を機械判定前提に更新（`response: yes` は対応方針提示、`unknown` は `gh issue view` で本文確認、`no` は対応不要）

### 3. 回帰テストスクリプト新設: `.claude/tests/test-block-pr-approve.sh`

hook はセキュリティ機構（issue #10 の「2枚目の壁」）であり #10 再検証が繰り返し必要になるため、コミット対象として常設する。`jq -n --arg c "$case" '{tool_input:{command:$c}}' | bash .claude/hooks/block-pr-approve.sh` の出力有無で deny/pass を判定する 15 ケース（DENY 期待: 真正承認 `--approve`/`-a`/`--approve --body`、`gh api -f event=APPROVE`、引用付き `-f "event=APPROVE"`、`--input - <<EOF` JSON 承認、benign heredoc 後の承認、ヒアストリング併用承認、残存 FP ケース、jq 不在 fail-safe / pass 期待: #17 原再現、`gh pr comment` heredoc 引用、`git commit -am` 引用 FP、`--comment`、`--request-changes`）。
**注意（実測済みの罠）**: トリガー文字列をテスト実行コマンド行に平文で書くと稼働中の hook 自体に deny される。テストケースは必ずファイル内に置き、実行は `bash .claude/tests/test-block-pr-approve.sh` のみとする。lint.sh は shebang からの動的検出のため対象リスト同期は不要。

### 4. issue 対応

1. **#18 の受領ラベル付与**: `received` + `enhancement` + `claude-tooling`（共通ラベル定義により義務。修正対象は自リポジトリ内のため `external` は付けない）
2. **#17**: 対応完了コメント（修正内容・判定(2) hardening・残存 FP/FN の文書化・**リビルド不要**〔hooks は `/workspace` 上のランタイムファイルでイメージ非焼き込み〕を明記）→ 検証完了後に自分でクローズ（起票側＝本リポジトリのセッションのため役割分担ルール上クローズ可）
3. **#18**: 対応完了コメント（機械判定の仕様・fail-soft 方向・リビルド不要を明記）。**クローズせず Open のまま**（起票側 dotclaude-ops の確認に委ねる）
4. 署名は統一形式 `— Sonnet 5 (claude-container)`

## 検証

1. `bash .claude/tests/test-block-pr-approve.sh` — 全 15 ケース green（#10 の「真正承認は引き続きブロック」再検証を含む）
2. session-start.sh: (a) jq 式単体を mock JSON 8 ケース（外部署名/自署名/署名なし/コメント 0/trailing 空白/旧形式/括弧終わり通常文/ダッシュ変種）で確認 (b) 実 issue（`#13`→yes(dotclaude-ops)、`#4`→yes(sotlas-frontend)、`#16`→unknown、`#17`→no）で確認 (c) `bash .claude/hooks/session-start.sh` 全体実行で `response:` 行の構造・終端マーカー到達・他セクション無影響を目視。現コンテナ token は `jj1xgo/dotclaude` を読めず FILED_OUTPUT が空になるため、(c) では一時的にアクセス可能な issue のダミーエントリを filed-issues.txt へ足して確認し、確認後に戻す（コミットしない）
3. `./lint.sh` — 警告ゼロ（新設テストスクリプトも動的検出で対象に含まれる）

## 完了時

計画ファイルを `git rm` で削除（グローバルルール）。lessons.md へ今回の学び（判定(2)の既存 FN 発見等）を記録。
