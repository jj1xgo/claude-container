# .claude/ カスタマイズ目録（このプロジェクト固有）

このプロジェクト（claude-container: findsummits 向け Claude Code サンドボックス環境の管理リポジトリ）の
`.claude/` に配置した Claude Code カスタマイズの一覧です。

グローバル共通設定との役割分担は `~/.claude/README.md` を参照してください。

---

## 役割分担サマリー（プロジェクト視点）

| 要素 | グローバル `~/.claude/` | このプロジェクト `.claude/` |
|---|---|---|
| [**CLAUDE.md**](#claudemd-の位置) | 全プロジェクト共通ガイドライン | リポジトリルートに配置 |
| **settings.json** | 基盤設定一式 | `skipDangerousModePermissionPrompt: true` + SessionStart / PostToolUse hook 登録 |
| **settings.local.json** | 存在しない | 存在しない（プロジェクト固有 permissions 未定義） |
| **commands/** | 汎用 skill（handover / log-incident / claude-md-panel / update-best-practices） | 存在しない（ドメイン固有 skill なし） |
| **rules/** | 存在しない | 存在しない |
| **hooks/** | 汎用保護（Write/Edit 検証・注入防止） | [`session-start.sh`](#hooks)（SessionStart hook。handover・lessons.md 自動注入、インシデント検知、best_practices 更新推奨）+ [`lint-posttool.sh`](#hooks)（PostToolUse hook。bash スクリプト編集時の shellcheck 自動実行） |
| [**incidents/**](#incidents) | 存在しない | 存在しない（発生時に運用開始。手順は `/log-incident` 参照） |
| [**handovers/**](#handovers) | 存在しない | セッション引き継ぎノート（このプロジェクト配下・git 管理外） |
| [**lessons.md**](#lessonsmd) | 存在しない | 学びの記録（`.claude/` 直下・git 管理外） |
| [**best_practices.md**](#best_practicesmdbest_practices_watermark) | 存在しない | `/update-best-practices` が lessons.md から再合成する原則集（`.claude/` 直下・git 管理対象） |
| [**plan-\*.md・todo.md**](#plan-mdtodomd) | 存在しない | plan承認後の運用ファイル（`.claude/` 直下・git 管理対象） |

---

## プロジェクト要素インベントリ

### commands/・rules/

いずれも未作成。findsummits にある `spec-panel` のようなドメイン固有 skill、`architecture.md` のような
アーキテクチャルールは、本プロジェクトでは現時点で導入していない。
必要になった時点で追加する（このプロジェクトはツール自体のリポジトリであり、findsummits のような
ドメイン固有の仕様レビューや lint 対象コードを持たないため）。

### hooks/

`session-start.sh` と `lint-posttool.sh` を導入済み（いずれも findsummits の同名 hook を移植）。

`session-start.sh` は SessionStart イベント
（`startup|resume|clear|compact`）で実行され、以下を行う:

- 最新 handover 1件・`.claude/lessons.md` の未蒸留分（`.claude/best_practices_watermark` 以降のエントリ）
  をセッション開始時に自動注入（従来 CLAUDE.md の文言のみに依存していた「セッション開始時のルーティン」
  を補強）。蒸留済み分は CLAUDE.md 側の `@.claude/best_practices.md` インポートで自動注入されるため、
  lessons.md 全文はここでは注入せず必要時に都度 Read する
- 未解決インシデント（`.claude/incidents/`）・handover 記載のインシデントを検知し、環境確認チェックリスト
  実行を促す
- `.claude/lessons.md` の増加件数を `.claude/best_practices_watermark` と比較し、閾値（10件）超過で
  `/update-best-practices` の実行を推奨

`lint-posttool.sh` は PostToolUse イベント（`Write|Edit`）で実行され、編集されたファイルが
`$CLAUDE_PROJECT_DIR` 配下の bash スクリプト（shebang 判定。`lint.sh` と同じ基準）であれば
shellcheck をかけ、違反を additionalContext で返送する（findsummits の同名 hook の縮小移植）。
jq / shellcheck 不在時は警告を返してスキップする fail-soft 設計。`.claude/incidents/`・
`.claude/handovers/` 配下は対象外。

PreToolUse hook は未定義。

### settings.json

```json
{
  "skipDangerousModePermissionPrompt": true,
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/lint-posttool.sh\"", "timeout": 30 }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [
          { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh\"" }
        ]
      }
    ]
  }
}
```

permissions.allow は未定義。

### incidents/

環境異常（指示なき自走・想定外コマンド混入・ツール挙動不安定等）を記録するファイル群。
発生時に `/log-incident` コマンドで自動生成される。`.gitignore` 対象（git 管理外）。

### handovers/

セッション終了時に `/handover` コマンドで自動生成される引き継ぎノートのファイル群。
日時タイムスタンプ付きファイル。`.gitignore` 対象（git 管理外）。

### lessons.md

修正・フィードバックの学びを記録するファイル。`.gitignore` 対象（git 管理外・コミット不要）。

### best_practices.md・best_practices_watermark

`/update-best-practices`（グローバル skill、Fable 実行・利用不可時は Opus）が `lessons.md` を再分析して合成する高レベル原則集。
運用定義はリポジトリルート [CLAUDE.md](../CLAUDE.md)「Best Practices（教訓蒸留）運用ルール」節を参照。
`best_practices_watermark` は前回合成時点の lessons.md 件数を記録し、`hooks/session-start.sh` が増加量の
閾値判定に使う。いずれも git 管理対象（`lessons.md` と異なり除外しない）。

### plan-\*.md・todo.md

Plan Mode で承認された計画（`.claude/plan-<slug>.md`）と、Plan Mode を伴わない軽微な実装タスクの管理リスト
（`.claude/todo.md`）。ともに `.claude/` 直下に置かれている。

| ファイル | 役割 |
|---|---|
| `plan-<slug>.md` | Plan Mode で承認された計画の保存先。`/plan` コマンドがシステムの都合で `~/.claude/plans/<slug>.md`（ホーム配下・グローバル）に自動生成するため、`ExitPlanMode` 承認後に同じ `<slug>` を使って `mv` で `.claude/plan-<slug>.md` へ移動する。作業完了時は `git rm` で削除しコミット、中断・持ち越し時は残す（リポジトリルート [CLAUDE.md](../CLAUDE.md)「計画ファイル・handover の扱い」参照） |
| `todo.md` | Plan Mode を伴わない軽微な実装タスクの管理リスト。完了した項目は消す（履歴は git で追える） |

いずれも git 管理対象。

---

## CLAUDE.md の位置

このプロジェクトの CLAUDE.md はリポジトリルート（[CLAUDE.md](../CLAUDE.md)）に配置されています。
`.claude/` 直下には置いていません。
