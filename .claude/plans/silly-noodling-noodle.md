# クロスリポジトリ issue の応答追跡と投稿元署名

## Context

全プロジェクトが同一 GitHub アカウント（JJ1XGO）で issue を操作するため、2つの問題がある。

1. **起票した issue への応答に気づけない**: 自分の活動には GitHub 通知が発生しないため、別リポジトリへ起票した issue に応答が付いても検知する仕組みがない
2. **投稿元が識別できない**: 署名が「モデル名のみ」（例: `— Sonnet 5`）のため、どのリポジトリのセッションから書かれたか判別できない

解決は2本柱で、相互に補強し合う: (A) クロスリポジトリ投稿の署名に投稿元リポジトリ名を付記する。(B) 各プロジェクトの session-start hook が既に注入している相手リポジトリの open issue 一覧に「最終コメントの署名行」を追加注入する。(A)+(B) により「最終コメントの署名が相手側 → 応答あり → 対応する」という判定がセッション開始時に機械的に成立する。

前提確認済み: `gh issue list --json` は `comments` フィールドをサポート（ホスト gh で実測）。コンテナ内の Debian 版 gh は未確認のため、hook はフォールバック付きで実装する。

## Part A: 署名ルール拡張（投稿元リポジトリ明記）

**形式**: 作業中リポジトリ**以外**への投稿は `— <モデル名> (<投稿元リポジトリ名>)`（例: `— Sonnet 5 (findsummits)`）。作業中リポジトリ自身への投稿は従来どおりモデル名のみ（投稿元が自明のため）。

| ファイル | 変更 |
|---|---|
| `~/.claude/CLAUDE.md`（グローバル、git 管理外） | **編集前に `cp` でバックアップ**（既存慣行 `.bak-YYYYMMDD-HHMM`）。「GitHub Issues による課題管理（opt-in）」節の署名ルールに投稿元付記の規定を追加 |
| findsummits `CLAUDE.md` | 「環境課題の連携」ルール3の署名例を新形式に追従 |
| sotlas-frontend `CLAUDE.md` | 同上（「ユーザー所有リポジトリ限定・upstream には署名しない」の但し書きは不変） |
| claude-container `CLAUDE.md` | 変更不要（署名ルールはグローバル参照のみで固有記述なし、確認済み） |

## Part B: session-start hook 拡張（最終コメント署名の注入）

**共通パターン**: 既存の issue 一覧取得を `--json number,title,updatedAt,comments` ＋ `--jq` に拡張し、各 issue の行に「最終コメントの最終非空行（＝署名行、120字で切詰め）」を追加出力する。**リグレッション対策**: 拡張クエリが失敗したら（コンテナ内の古い gh が `comments` 未対応の場合）現行のクエリへフォールバックし、両方失敗した場合のみ従来の失敗メッセージを出す。注入する指示文を「last-comment の署名が相手リポジトリ側の issue は応答あり。最初の返答時に対応方針をユーザーへ提示すること」に拡張する。

| ファイル | 変更 |
|---|---|
| claude-container `.claude/hooks/session-start.sh` | ① `RECEIVED_ISSUES` クエリ（Pass 1、L73-75）を共通パターンで拡張 ② **新設**: `.claude/filed-issues.txt` を読み、各エントリを `gh issue view --json state,title,comments` で確認して「外部リポジトリへ起票した issue」ブロックを注入（Pass 1 で取得・Pass 2 で出力・非空ならアクション件数ダイジェストに1件追加。上限10件・timeout・フェイルソフト）。終端マーカーは最後のまま維持 |
| claude-container `.claude/filed-issues.txt`（新規・git 管理対象） | 1行1エントリ `owner/repo#番号` 形式。初期内容: `JJ1XGO/findsummits#1`・`JJ1XGO/sotlas-frontend#1`（本日起票分） |
| claude-container `CLAUDE.md` | 「タスク管理の流れ（GitHub Issues）」節に追記: 他リポジトリへ起票したら `.claude/filed-issues.txt` に追記して同ターンでコミット、クローズ確認後に行を削除 |
| findsummits `.claude/hooks/session-start.sh` | `CC_ISSUES` ブロック（claude-container 宛、L89-91）と `FS_ISSUES` ブロック（自リポジトリ、L111-114）を共通パターンで拡張 |
| sotlas-frontend `.claude/hooks/session-start.sh` | `CC_ISSUES` ブロックを共通パターンで拡張。自リポジトリ用ブロックの新設は**行わない**（移行 issue sotlas-frontend#1 の手順5のスコープ。今回の変更と競合しない） |

**filed-issues.txt を findsummits/sotlas に導入しない理由**: 両者の起票先は claude-container 固定で、既存ブロックが相手の open issue を全件注入するため追跡ファイルは冗長。起票先が可変なのは claude-container のみ。

## ドキュメント追従

- claude-container `.claude/README.md`: hooks 説明に filed-issues ブロックを追記、サマリー表・インベントリに `filed-issues.txt` を追加
- findsummits / sotlas-frontend `.claude/README.md`: hook 説明の該当行に最終コメント注入の言及を追加（各1〜2行）

## 実行モデル

全タスク現行セッションで直接対応（既存パターン踏襲の機械的編集のため上位モデル委譲は不要。本セッションは既に Fable）。

## 検証

1. 各リポジトリで `bash .claude/hooks/session-start.sh` を手動実行し、(a) issue 行に last-comment 署名行が付くこと (b) claude-container は終端マーカー・ダイジェスト件数の整合 (c) filed-issues ブロックに findsummits#1・sotlas#1 が出ること を確認
2. フェイルソフト経路: `PATH` から gh を外して実行し、従来どおり一行メッセージで劣化することを確認
3. lint: claude-container は `./lint.sh`、findsummits / sotlas-frontend は編集時の PostToolUse hook（shellcheck）＋ `bash -n`
4. コンテナ内 gh の `comments` フィールド対応は次回コンテナセッションで実挙動確認（未対応でもフォールバックで現行機能を維持）
5. 署名新形式は次回のクロスリポジトリ投稿から適用

## コミット（push はしない）

- claude-container: hook＋filed-issues.txt＋CLAUDE.md＋README で1コミット
- findsummits / sotlas-frontend: 各 hook＋CLAUDE.md＋README で1コミット
- グローバル CLAUDE.md は git 管理外（バックアップファイルのみ）

## 備考

- 本計画ファイルは `~/.claude/plans/` に生成されている（`plansDirectory` はセッション起動時にのみ読まれるため今セッションでは未反映と推定）。承認後、CLAUDE.md のフォールバック手順どおり `.claude/plans/` へ `mv` する。設定の実効性判定は次回新規セッションで確定する
