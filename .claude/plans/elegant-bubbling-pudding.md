# CLAUDE.md と .claude/ を private ops リポジトリへ分離する

## Context

本リポジトリは公開フォーク（プロダクト＝サンドボックス環境）だが、メンテナ個人の運用ファイル
（`CLAUDE.md`・`.claude/` 配下の hooks・filed-issues・best_practices 等）が git 追跡され混入している。
dotclaude / dotclaude-ops と同じ「baseline / management」分離を、このリポジトリにも適用する:
公開リポジトリはプロダクトのみ、運用ファイルは private リポジトリ `jj1xgo/claude-container-ops` で管理する。

**成立根拠（調査済み）**:
- Claude Code は `./.claude/CLAUDE.md` をプロジェクトメモリとしてネイティブサポート（公式 docs「Set up a project CLAUDE.md」節）→ ルート CLAUDE.md は完全に削除できる
- `@` import の相対パスは「import を書いたファイルの所在ディレクトリ」基準（公式 docs）→ `.claude/CLAUDE.md` 内では `@best_practices.md` になる
- hook 3本はすべて `$CLAUDE_PROJECT_DIR` / `dirname "$0"` 基点で git 非依存 → nested repo 化しても動作無変更
- `lint-posttool.sh`（編集時 lint）はパス直接判定で影響なし。集約 `lint.sh` のみ `git ls-files -co` 依存で要拡張

## ユーザーと合意済みの決定事項

1. ルート CLAUDE.md は**削除**し、実体を `.claude/CLAUDE.md` へ（ネイティブ方式。1行ポインタ案Aは撤回）
2. `block-pr-approve.sh`＋テストは**公開側に残す**（`examples/hooks/` へ移設。公開 README のセキュリティモデル記述と実態を一致させ続ける）
3. lessons.md・handovers/・incidents/ は ops リポジトリで**追跡する**（コミットは区切りでまとめてで可）。settings.local.json・sessions/ 等のランタイム状態は引き続き管理外
4. ops リポジトリは **GitHub private repo `jj1xgo/claude-container-ops`**（作成・push はホスト側でユーザー操作）
5. 公開リポジトリの過去履歴は書き換えない（fork 関係があり、秘密情報も含まれないため）
6. issue #21 の dotclaude-ops への移管は本作業の完了後に行う

## 実装ステップ（全タスク Sonnet 実装。実装中委譲の3条件に該当するタスクなし）

### Step 0: 計画ファイルのコミット（承認直後）

- 本ファイルを外側リポジトリへコミット（現行運用どおり。Step 2 で追跡解除されるが履歴に残り、Step 3 以降は ops リポジトリで追跡される）

### Step 1: 公開側 — block-pr-approve 一式を `examples/hooks/` へ移設

- `git mv .claude/hooks/block-pr-approve.sh examples/hooks/block-pr-approve.sh`
- `git mv .claude/tests/test-block-pr-approve.sh examples/hooks/tests/test-block-pr-approve.sh`
  - テスト内 `HOOK="$ROOT/.claude/hooks/block-pr-approve.sh"`（L12）と ROOT 導出・ヘッダの実行手順コメント（「bash .claude/tests/...」）を新パスへ更新
- `examples/hooks/README.md` を新規作成: 現 `.claude/README.md` の block-pr-approve 説明（L73-82 相当）＋ settings.json への配線スニペット（PreToolUse ブロック）＋テスト実行手順を移す
- `.claude/settings.json` の PreToolUse hook パスを `$CLAUDE_PROJECT_DIR/examples/hooks/block-pr-approve.sh` へ変更
  - 注意: 現セッションの hook 設定はセッション開始時スナップショットのため、mv 直後から旧パス参照で PreToolUse が exit 127 のエラーノイズを出す（non-blocking、ツール実行は継続）。次セッション再起動で解消 — 実装セッション中は許容する
- 公開 `README.md` の更新:
  - 「hook による追加制限」節: パスを `examples/hooks/block-pr-approve.sh` へ。「フォークにもそのまま同梱される」の記述を「同梱されるが、適用には各プロジェクトの `.claude/settings.json` での配線が必要（配線例は `examples/hooks/README.md`）」の趣旨へ修正（settings.json が private 化され自動適用でなくなるため）
  - 「hook の実装詳細は `.claude/README.md`、回帰テストは `.claude/tests/...`」の参照を `examples/hooks/README.md`・`examples/hooks/tests/...` へ
- `Dockerfile.claude` L45 のコメント「see CLAUDE.md residual risks」→ 参照先を README のセキュリティモデル節へ変更（README 側にビルド時ネットワーク無制限の記述があるか確認し、なければコメントを自己完結の文言にする）
- `lint.sh` の対象検出を nested repo 対応に拡張（ある場合のみ・第三者クローンでは no-op）:
  ```bash
  if [ -d .claude/.git ]; then
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      head -n1 "$f" 2>/dev/null | grep -qE '^#!/bin/bash|^#!/usr/bin/env bash' && scripts+=("$f")
    done < <(git -C .claude ls-files -co --exclude-standard | sed 's|^|.claude/|')
  fi
  ```
- `./lint.sh` 実行＋`bash examples/hooks/tests/test-block-pr-approve.sh` 全ケース通過を確認してコミット

### Step 2: 公開側 — CLAUDE.md と .claude/ の追跡解除

- `mv CLAUDE.md .claude/CLAUDE.md`（ディスク上の移動。内容編集は Step 3）
- `git rm --cached CLAUDE.md` ＋ `git rm -r --cached .claude`（残り追跡ファイル: README.md・best_practices.md・best_practices_watermark・filed-issues.txt・hooks/session-start.sh・hooks/lint-posttool.sh・settings.json・plans/ 等）
- `.gitignore` の L9-15（`.claude/settings.local.json` 〜 `.claude/test-results/` の細目7行）を `.claude/` 1行に置換
- `git status` で公開側がクリーン（.claude/ 由来の未追跡なし）になることを確認してコミット

### Step 3: ops リポジトリの初期化と内容更新

- `.claude/` 内で `git init`（ブランチ main）
- ops 側 `.gitignore` を新規作成:
  ```
  settings.local.json
  history.jsonl
  projects/
  sessions/
  test-results/
  .cc-writes/
  bash_history
  ```
- `.claude/CLAUDE.md` の内容更新:
  - `@.claude/best_practices.md` → `@best_practices.md`（相対パスは所在ファイル基準）
  - filed-issues.txt「同ターンでコミット」等、コミット先が変わる記述に「コミット先は ops リポジトリ。`/workspace` から操作する場合は `git -C .claude ...`」を明記（plan ファイル・best_practices/watermark のコミットも同様）
  - lessons.md・handovers・incidents の「git 管理外」記述を「ops リポジトリで追跡（コミットは区切りでまとめて。グローバル規約『git 管理外・コミット不要』の本プロジェクト限定の上書き）」へ
  - block-pr-approve の参照パスを `examples/hooks/` へ、lint.sh の説明に nested repo 拡張を反映
  - `/update-best-practices`（グローバルコマンド）の git 操作は cwd 前提の可能性があるため「実行時は ops リポジトリへコミットされることを確認する」旨の注意を追記
- `.claude/README.md` の更新: hooks 一覧から block-pr-approve を「`examples/hooks/` へ移設（公開側）・配線は settings.json」に変更、「CLAUDE.md の位置」節を `.claude/CLAUDE.md` 配置に更新、lessons/handovers/incidents の「git 管理外」記述を追跡ありに更新
- `session-start.sh` の指示文言（「.claude/filed-issues.txt から該当行を削除しコミットすること」等）に `git -C .claude` の形を明記
- 全対象（CLAUDE.md・README.md・best_practices.md・watermark・filed-issues.txt・hooks・lessons.md・handovers/・incidents/・plans/ 本ファイル含む）を initial commit。コミットメッセージに移管元（`claude-container@<sha>` からの分離）を明記
- `./lint.sh` を再実行（nested 拡張で session-start.sh 等が対象に入ることを確認）

### Step 4: ユーザーのホスト側操作（コンテナ内トークンの権限外のため）

提示するコマンド（ホスト側パスで）:
1. `gh repo create jj1xgo/claude-container-ops --private`（または Web UI）
2. `git -C ~/sota/claude-container/.claude remote add origin https://github.com/jj1xgo/claude-container-ops.git && git -C ~/sota/claude-container/.claude push -u origin main`
3. 公開側: `git -C ~/sota/claude-container push`
4. セッション再起動（次セッションでの検証のため）

## 検証

- **実装セッション内**:
  - `./lint.sh` 警告ゼロ（examples/hooks/ が外側 `git ls-files` 経由、.claude/ 配下が nested 拡張経由で対象に入ることを検出リストで確認）
  - `bash examples/hooks/tests/test-block-pr-approve.sh` 全ケース通過
  - 外側: `git status` クリーン、`git ls-files | grep -E '^CLAUDE\.md|^\.claude/'` が 0 件
  - ops 側: `git -C .claude status` クリーン
  - 第三者体験の模擬: `git clone /workspace <scratchpad>/clone-test` し、clone 内に CLAUDE.md・.claude/ が存在しないこと、`./lint.sh` がそのまま通ることを確認
- **次セッション開始時（再起動後）**:
  - `.claude/CLAUDE.md` がネイティブ読込されている（プロジェクト指示がコンテキストに注入されている）ことを確認 — 公式 docs の記述の実機裏取り
  - session-start hook が発火する（settings.json は従来どおり読まれる）
  - PreToolUse hook が新パスでエラーなく動く（適当な Bash 実行でエラー表示が出ないこと）

## 留意点・持ち越し

- `/update-best-practices` グローバルコマンドの git 操作が cwd（外側リポジトリ）前提だった場合、次回実行時に手直しが要る可能性 → 発生したら dotclaude-ops へ起票
- 公開履歴には過去の CLAUDE.md・.claude/ が残る（合意済み・対応しない）
- issue #21（hook 移植ドリフト検知）の dotclaude-ops 移管は本作業完了後に実施
- 完了時の本計画ファイル削除は `git -C .claude rm plans/elegant-bubbling-pudding.md`（ops リポジトリ側）
