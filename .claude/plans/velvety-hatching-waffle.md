# issue #19: filed-issues確認のセカンダリトークン・フォールバック再試行

## Context

`session-start.sh` のfiled-issues確認ブロックは `.claude/filed-issues.txt` の各エントリを
プライマリトークン（自動exportされた `GH_TOKEN`、claude-container限定スコープ）のみで
`gh issue view` するため、セカンダリトークンでしか読めないprivateリポジトリ
（現に `jj1xgo/dotclaude-ops#14` が該当）のエントリが無言スキップされる（issue #19）。

対応方針は #19 コメント済み（Fable諮問・実機裏取り済み）: プロジェクト台帳への可視性
フィールド追加案は不採用とし、**プライマリ失敗時にセカンダリで1回だけ再試行**する。
fail-soft設計（timeout 10・`2>/dev/null`・空なら continue）と「セカンダリは自動exportせず
コマンド単位のenv前置のみ」の原則を維持する。

## 実装（全タスク Sonnet 担当）

### 1. `.claude/hooks/session-start.sh`（本体）

(a) `FILED_ISSUES_FILE=`（L178）付近に定数＋設計コメントを追加:

```bash
# セカンダリトークン（issue #19）: プライマリで読めない private リポジトリ（セカンダリPATの
# スコープ内）のエントリを1回だけ再試行する。compose.yml は未設定時 /dev/null をマウントする
# ため存在チェックでなく非空チェック（-s）で判定する。トークンは自動exportの原則を破らず、
# コマンド単位の env 前置でのみ使う（値は ps のコマンドラインに現れない）。
SECONDARY_TOKEN_FILE="/home/node/.config/claude-container/gh-token-secondary"
```

(b) プライマリ取得（L188）と `[ -z "$info" ] && continue`（L189）の間に再試行を挿入:

```bash
    if [ -z "$info" ] && [ -s "$SECONDARY_TOKEN_FILE" ]; then
      info=$(GH_TOKEN=$(cat "$SECONDARY_TOKEN_FILE" 2>/dev/null) timeout 10 gh issue view "$num" --repo "$repo" --json state,title,url,comments 2>/dev/null)
    fi
```

設計判断:
- **`[ -s ]` 判定**: 未設定時は `/dev/null`（サイズ0）がマウントされるため。コンテナ外実行では
  ファイル不在 → 偽 → 再試行スキップで両環境対応
- **毎回 `cat`（ループ外キャッシュしない）**: シェル変数にトークン値を保持せず、README記載の
  正規パターン（`GH_TOKEN=$(cat ...) gh ...`）そのままの形にする。再試行は例外パス限定・最大10回
- **`cat` 失敗時**: `GH_TOKEN=` 空前置 → gh未認証で失敗 → `info` 空 → 既存の `continue`（fail-soft維持）

### 2. `CLAUDE.md`（1行追記）

「タスク管理の流れ」節の「他リポジトリへ起票したら」bulletに補足:
セカンダリ限定privateリポジトリ宛エントリもhookがセカンダリで再試行して自動確認する旨（issue #19）。

README.md は変更不要（hook内部動作は利用者向け範囲外。セカンダリの利用規約にも準拠）。

### 3. テスト戦略: 専用テスト新設せず、実機検証のみ

- ghスタブ方式はトークンパスがハードコードのため本番コードへのテスト用フック混入が必要になり、
  秘密情報を扱う行に読み先差し替えフックを足すのはセキュリティ後退。得られるのは模倣動作の確認のみ
  （教訓「模倣コピーの自己チェックはトートロジー」）
- 実機の好条件が現存: `filed-issues.txt` に `jj1xgo/dotclaude-ops#14`（プライマリ不可・セカンダリ可）が
  実在し、本体経路の実行だけで「プライマリ失敗→セカンダリ成功」を検証できる

## 検証

1. `./lint.sh`（bash -n + shellcheck、対象は自動収集）
2. 実機実行 `bash .claude/hooks/session-start.sh`:
   - `jj1xgo/dotclaude-ops#14` の行が出力に**新たに**現れること（フォールバック成功）
   - `jj1xgo/findsummits#27`・`jj1xgo/sotlas-frontend#16` が従来どおり出力されること（プライマリ経路非退行）
3. トークン非露出確認: 出力に `github_pat` が0件（`grep -c`、生値は出力しない）

## 後処理

- コミット（`fixes #19` は使わない — クローズは `gh issue close` を正とする運用）
- issue #19 へ対応完了コメント（実装内容・検証結果、リビルド不要 — hookはbind mount内で
  イメージ焼き込みでない旨を明記）→ 自リポジトリ起票のためクローズ
- 計画ファイルは承認後コミット、完了時に `git rm`
