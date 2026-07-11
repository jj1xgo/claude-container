# #16+#15: 認証・PAT・hook制限の横断ドキュメント整備と依存関係の周知

## Context

- **issue #16**（documentation + claude-tooling）: git ローカル操作 / gh CLI 操作の認証系統の違い、プライマリ/セカンダリPATの権限対応、hookによる追加制限（範囲拡張コメントで追加）が README.md・CLAUDE.md・`.claude/README.md` の3箇所に分散し、「何ができて何ができないか」の一覧がない。README.md に早見表セクションを新設する（issue本文の提案どおり）
- **issue #15**（documentation + external + claude-tooling）: グローバル `~/.claude/CLAUDE.md` の「dotclaude-ops への起票」義務が、claude-container の `GH_TOKEN_SECONDARY_FILE` 機構（README にのみ文書化）に依存しているのに参照が張られておらず、利用側プロジェクトにも未周知
- **役割分担（ユーザー確定済み）**: グローバル CLAUDE.md への参照追記は claude-container 側では実施しない — dotclaude への変更はグローバルルール上 `jj1xgo/dotclaude-ops` への起票が正規経路のため、**依頼 issue を起票して dotclaude-ops 側に対応してもらう**。利用側プロジェクト（findsummits・sotlas-frontend、実在確認済み）へはセカンダリトークンで確認依頼 issue を起票し委譲する
- 設計は Fable（計画セッション）が Plan サブエージェントの調査（対象ファイル全読・挿入位置実測）を経て確定

## タスク（実行モデル: 全て Sonnet。ただしタスク3の claude-md-panel レビューのみ Agent ツールで `model: fable` を明示指定 — スキルのFable優先設計のため）

### 1. README.md 日本語版: 新節の追加＋既存2箇所の修正

**新節**: `### 何ができて何ができないか（git / gh / PAT / hook 早見表）` を「コンテナ間の永続化」（L151）と「セキュリティモデル」（L153）の間に挿入。構成は導入文＋3表＋補足:

- **導入文**: コンテナ内の git と gh CLI は認証系統が完全に独立している旨（`git push` の失敗は権限不足でなく credential helper の意図的な未配線、`gh` は `GH_TOKEN` 直接使用で git 設定と無関係）
- **表1（操作系統別の認証経路と可否）**: 行= git ローカル操作（commit/log/diff/branch/merge等。commit のみ `GITCONFIG_FILE` 必要）／git リモート操作（push/pull/fetch＝**全リポジトリ一律不可**、ホスト側で実施）／gh CLI＋プライマリ（自動export、PAT範囲内で可）／gh CLI＋セカンダリ（`GH_TOKEN=$(cat /home/node/.config/claude-container/gh-token-secondary) gh ...` の明示指定）。列= 操作・認証経路・コンテナ内での可否
- **表2（プライマリ/セカンダリPAT対応表）**: 行= 想定用途／自動export／一般的に許可してよいパーミッション（プライマリ: `Issues: RW`＋必要に応じ `Pull requests: RW`・`Contents: Read`、セカンダリ: `Issues: RW` のみ）／持たせるべきでないパーミッション（`Contents: write`＝push・マージ・Release直結。セカンダリは `Pull requests: write` も不要）／設定手順・スコープ確認（「利用側プロジェクトの設定」節参照で重複記載しない）。**トークン実名（claude-container-self等）とセカンダリの対象リポジトリは書かない**（README は汎用フォーク利用者向け、実名・列挙回避は CLAUDE.md の既存設計判断）
- **表3（hookによる追加制限）＋前置き**: 前置きで適用範囲を明示 —「本リポジトリ自身を `/workspace` として動かす場合に `.claude/` 同梱 hook が適用。フォークにも同梱されるが、利用側プロジェクトには自動では適用されない」。行= PreToolUse hook `block-pr-approve.sh`（ブロック: `gh pr review --approve`/`-a`/短オプションクラスタ内の`a`、`gh api …/pulls/N/reviews`＋`event=APPROVE`〔引用符・ヒアドキュメント本文経由含む〕。通過: `--comment`・`--request-changes` 等）／`permissions.deny`（現状未使用）
- **表3の後の補足3点**: (1) hook と deny の使い分け基準（deny は静的パターンで丸ごと禁止できる場合、本件は文脈依存判定が必要なため hook）(2) 既知の誤検知（`block-pr-approve.sh` ヘッダコメント L26-33 と一致させる: 残存FP=gh api実コマンド＋heredoc両パターン引用・複数行ダブルクォート、残存FN=引用内`<<X`難読化〔脅威モデル外〕）(3) 参照（リスク詳細→セキュリティモデル節、実装→`.claude/README.md`、回帰テスト→`.claude/tests/test-block-pr-approve.sh`）

**既存修正**:
- L86 直後（プライマリ/セカンダリ使い分けブロック末尾）にポインタ1行: 「操作系統ごとの可否・パーミッションの全体像は「何ができて何ができないか」節の早見表を参照」
- L167 の auto-merge 項を更新: 「〜自律実行しない運用が必要（詳細はプロジェクト CLAUDE.md 参照）」→ 同梱 PreToolUse hook が機構的にブロック済み（2枚目の壁、適用範囲と限界は新節参照）である現状へ同期

### 2. README.md 英語版: 対訳の同期

- 新節 `### What Works and What Doesn't (git / gh / PAT / hook quick reference)` を「Persistence Across Container Runs」（L348）と「Security Model」（L350）の間に挿入（日本語版と同一構成）
- L283 直後にポインタ1行、L364（auto-merge bypass項）を日本語 L167 と同内容に更新
- 全節日英対訳の1対1対応を維持

### 3. CLAUDE.md への参照追記（軽微）

- セキュリティモデル節の「auto-merge 経由の境界迂回に注意」項（PreToolUse hook 言及箇所）の末尾に「（利用者向けの可否早見表は README.md「何ができて何ができないか」節）」を追記
- 編集完了後に claude-md-panel レビューを1回実行（**Agent ツールで `model: fable` を明示指定** — Skill インライン実行はセッションモデルを継承するため）。指摘は一次情報で裏取りしてから反映

### 4. 検証 → コミット（ユーザー確認後）→ #16 クローズ

検証チェックリスト（ドキュメント↔実装の突き合わせ）:

| 記述 | 突き合わせ先 |
|---|---|
| git push/pull/fetch 一律失敗（credential helper 未配線） | `compose.yml`・`entrypoint.sh` に credential 配線が無いこと（grep）、既存 L113 と矛盾しないこと |
| プライマリ自動 export | `entrypoint.sh` L40-44 |
| セカンダリのマウントパス・非 export | `compose.yml` L47、`entrypoint.sh` にセカンダリ処理が無いこと |
| hook のブロック/通過対象・FP/FN | `block-pr-approve.sh` ヘッダ・判定部と整合、`.claude/tests/test-block-pr-approve.sh` 実行 green |
| permissions.deny 未使用 | `.claude/settings.json` に deny キーが無いこと |

日英同期: JA/EN の見出し数・順序の1対1対応、新設3表の行数一致（`grep -c '^|'` を区間比較）。`./lint.sh` は md 対象外だが実行して shell 側巻き込みなし（変更なし）を確認。

コミット後、#16 へ対応完了コメント（**リビルド不要**〔ドキュメントのみ〕明記、署名 `— Sonnet 5 (claude-container)`）→ `gh issue close 16`（起票側=本セッション系のためクローズ可）

### 5. dotclaude-ops への依頼 issue 起票（#15 その1）

**事前ステップ（必須）**: セカンダリトークンで起票先を確定する。`.claude/filed-issues.txt` の既存エントリは `jj1xgo/dotclaude#1`・`#2` だが、前回 handover は `dotclaude-ops#2` と記録しており名称不整合がある。`GH_TOKEN=$(cat /home/node/.config/claude-container/gh-token-secondary) gh issue view 2 --repo jj1xgo/dotclaude-ops` を試し（private のため 200/404 がスコープ判定として有効）、404 なら `jj1xgo/dotclaude` 側を確認。「運用方針の検討」追跡 issue の所在を確定してから起票する

**issue 文面骨子**（タイトル: グローバル CLAUDE.md の dotclaude-ops 起票義務に、claude-container の GH_TOKEN_SECONDARY_FILE 設定が前提である旨の参照追記を依頼）:
- 背景: 起票義務がクロスリポジトリ書き込み手段（claude-container README にのみ文書化）に依存、参照欠落、利用側が機構を認識していなかった実例（`jj1xgo/claude-container#15`）
- 依頼: 当該ルール箇所への短い参照追記の検討。追記文面の具体案を添える（claude-container 環境からの起票には対象プロジェクトの `.claude-container.d/env` に `GH_TOKEN_SECONDARY_FILE` 設定が前提、手順は claude-container README 参照、未設定時は文面提示→ホスト側手動起票へフォールバック）。プロジェクト固有詳細（トークン名・マウントパス）はグローバルへ書かない境界も注記
- 関連参照: 運用方針検討の追跡 issue（事前ステップで確定した番号）、`jj1xgo/claude-container#15`
- 署名: `— Sonnet 5 (claude-container)`

**fail-closed**: セカンダリでも書けない（403/404）場合は文面をユーザーに提示しホスト側手動起票へ切替。手動起票の番号確定まで #15 は Open 維持

### 6. 利用側プロジェクトへの確認依頼 issue 起票（#15 その2、2件）

対象: `jj1xgo/findsummits`・`jj1xgo/sotlas-frontend`（実在確認済み、両方 public のため事前スコープ判定不可 — `gh issue create` を直接試行し、失敗時はユーザー提示に切替）。文面骨子（共通、リポジトリ名差替え）:
- タイトル: `.claude-container.d/env` の `GH_TOKEN_SECONDARY_FILE` 設定確認のお願い（クロスリポジトリ issue 起票の前提）
- 確認方法: コンテナ内から `[ -s /home/node/.config/claude-container/gh-token-secondary ] && echo configured || echo not-configured`（未設定時は `/dev/null` マウントで空）
- 未設定なら: 設定はホスト側作業のためユーザーへ依頼。手順は claude-container README「利用側プロジェクトの設定」節参照（転記しない）
- 結果を issue へコメント報告 → 報告確認後に claude-container 側からクローズ
- 署名: `— Sonnet 5 (claude-container)`

### 7. filed-issues.txt 追記＋コミット → #15 クローズ

- タスク5・6で起票した全 issue（最大3件）を `.claude/filed-issues.txt` へ `owner/repo#番号` 形式で追記し、同ターンでコミット（session-start hook の自動追跡対象化）
- #15 へ対応完了コメント（実施内容: #16 正本ドキュメント・依頼/周知 issue 3件の起票。後続は filed-issues.txt で追跡し、報告確認後に各 issue をクローズ・台帳から削除する旨。リビルド不要）→ `gh issue close 15`
- **クローズ根拠**: 残作業は全て他リポジトリにアクション主体が移り claude-container 側に実施主体が残らない。外部 issue は filed-issues.txt 経由で毎セッション自動確認されるため Open 維持は二重追跡になる。**例外**: タスク5が fail-closed でユーザー手動起票になった場合は番号確定・filed-issues.txt 追記まで Open 維持

## 検証（全体）

1. タスク4のチェックリスト＋日英同期確認＋`./lint.sh`
2. `bash .claude/tests/test-block-pr-approve.sh` green（表3の記述根拠の実機確認を兼ねる）
3. 起票後、`bash .claude/hooks/session-start.sh` を手動実行し filed-issues ブロックに新エントリ3件が `response:` 付きで出力されることを確認（#18 で機械判定化済みの機構に載ることの確認）

## 完了時

計画ファイルを `git rm` で削除。lessons.md へ学びを記録（あれば）。
