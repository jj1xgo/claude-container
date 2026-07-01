# .claude/ カスタマイズ目録（このプロジェクト固有）

このプロジェクト（claude-container: findsummits 向け Claude Code サンドボックス環境の管理リポジトリ）の
`.claude/` に配置した Claude Code カスタマイズの一覧です。

グローバル共通設定との役割分担は `~/.claude/README.md` を参照してください。

---

## 役割分担サマリー（プロジェクト視点）

| 要素 | グローバル `~/.claude/` | このプロジェクト `.claude/` |
|---|---|---|
| [**CLAUDE.md**](#claudemd-の位置) | 全プロジェクト共通ガイドライン | リポジトリルートに配置 |
| **settings.json** | 基盤設定一式 | `skipDangerousModePermissionPrompt: true` のみ |
| **settings.local.json** | 存在しない | 存在しない（プロジェクト固有 permissions・hooks 未定義） |
| **commands/** | 汎用 skill（handover / log-incident / claude-md-panel / update-best-practices） | 存在しない（ドメイン固有 skill なし） |
| **rules/** | 存在しない | 存在しない |
| **hooks/** | 汎用保護（Write/Edit 検証・注入防止） | 存在しない（PreToolUse/PostToolUse hook 未定義） |
| [**incidents/**](#incidents) | 存在しない | 存在しない（発生時に運用開始。手順は `/log-incident` 参照） |
| [**handovers/**](#handovers) | 存在しない | セッション引き継ぎノート（このプロジェクト配下・git 管理外） |
| [**lessons.md**](#lessonsmd) | 存在しない | 学びの記録（`.claude/` 直下・git 管理外） |
| [**plan-\*.md・todo.md**](#plan-mdtodomd) | 存在しない | plan承認後の運用ファイル（`.claude/` 直下・git 管理対象） |

---

## プロジェクト要素インベントリ

### commands/・rules/・hooks/

いずれも未作成。findsummits にある `spec-panel` のようなドメイン固有 skill、`architecture.md` のようなアーキテクチャルール、
SessionStart/PreToolUse/PostToolUse hook は、本プロジェクトでは現時点で導入していない。
必要になった時点で追加する（このプロジェクトはツール自体のリポジトリであり、findsummits のような
ドメイン固有の仕様レビューや lint 対象コードを持たないため）。

### settings.json

```json
{
  "skipDangerousModePermissionPrompt": true
}
```

permissions.allow・hooks は未定義。

### incidents/

環境異常（指示なき自走・想定外コマンド混入・ツール挙動不安定等）を記録するファイル群。
発生時に `/log-incident` コマンドで自動生成される。`.gitignore` 対象（git 管理外）。

### handovers/

セッション終了時に `/handover` コマンドで自動生成される引き継ぎノートのファイル群。
日時タイムスタンプ付きファイル。`.gitignore` 対象（git 管理外）。

### lessons.md

修正・フィードバックの学びを記録するファイル。`.gitignore` 対象（git 管理外・コミット不要）。

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
