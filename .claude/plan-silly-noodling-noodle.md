# sotlas-frontend への移行手順 issue 起票

## Context

findsummits で確立した「課題管理を GitHub Issues へ移行する」運用を sotlas-frontend にも横展開する。ユーザーの許可のもと、findsummits#1 をテンプレートに sotlas-frontend 向けの移行手順ドラフトを作成し、Fable サブエージェントにレビューさせて指摘を一次情報と照合済み（詳細は会話履歴参照）。ここではその最終ドラフトを sotlas-frontend リポジトリへ実際に起票する作業のみを計画する。**実装（CLAUDE.md 書き換え・session-start.sh 追加・todo.md 廃止）は sotlas-frontend 側のセッションで別途 Plan Mode 承認のもと行う** — 本計画のスコープは issue 起票までで、これ以上先に進めない。

事前確認済み事項:
- sotlas-frontend の GitHub Issues 機能は有効化済み（`hasIssuesEnabled: true` を確認済み）
- コンテナ内 PAT に sotlas-frontend の Issues Read/Write スコープあり（ユーザー申告済み）
- 現在のラベルは GitHub デフォルト一式のみ（`on-hold` 未作成）

## 実行内容

### 1. ラベル作成

```
gh label create on-hold --repo JJ1XGO/sotlas-frontend --description "長期保留。本文に再検討トリガーを明記" --color ededed
```

### 2. 移行手順 issue の起票

`gh issue create --repo JJ1XGO/sotlas-frontend --label enhancement --title "課題管理を GitHub Issues へ移行する（claude-container/findsummits で確立した運用の横展開）"` を実行し、以下を本文（`--body-file`）とする。

```markdown
## 背景

claude-container / findsummits で確立した「課題管理を GitHub Issues へ移行する」運用を sotlas-frontend にも横展開する。findsummits#1（実施済み）をテンプレートにしている。

前提条件:
- ユーザーが sotlas-frontend の GitHub Issues 機能を有効化済み
- コンテナ内 PAT に sotlas-frontend の Issues Read/Write スコープ追加済み（ユーザー申告済み。本 issue 自体が実際の書き込み疎通テストを兼ねる）

## 移行手順（sotlas-frontend セッションで実施、Plan Mode で計画化すること）

1. **ラベル作成**: `on-hold`（保留。再検討トリガーを本文に明記するものだけに使う）
2. **todo.md の棚卸し・issue 化**（ファイル側を触る前に済ませる）:
   - 機能①（アクティベーションゾーン表示の日本サミット追従）: `enhancement` のみ。着手トリガーが無い通常バックログのため `on-hold` は付けない
   - 機能②（地図上の夜間帯表示）: `enhancement` のみ、同上
   - upstream issue #23 へ FA-free 方式を共有するか検討: 元の todo.md にある「投稿前に内容をユーザーへ説明する」の条件をそのまま本文に引き継ぐ
   - claude-container #3（Node22 ビルドフック）・#4（gh 公式 apt 化）対応待ち: それぞれ `on-hold` ＋本文に再検討トリガー「該当 claude-container issue がクローズされたらリビルドして動作確認」を明記し、リンクを保持
   - 環境整備チェックリスト（全項目完了済み）: issue 化しない。「ブラウザ確認はホスト側 npm run dev（コンテナはポート非公開）」の恒常ノートは CLAUDE.md「検証方法」節に既に転記済みのため対応不要
3. **CLAUDE.md「計画・タスク管理」節を書き換え**: 「軽微な実装タスクは .claude/todo.md に直接書く」をグローバル CLAUDE.md「GitHub Issues による課題管理（opt-in）」参照に置き換える
4. **CLAUDE.md「環境課題の連携」節の判定基準行を更新**: 「sotlas-frontend 自身の問題 → 従来どおり .claude/todo.md / .claude/plan-*.md」を「sotlas-frontend 自身の問題 → 本リポジトリ（jj1xgo/sotlas-frontend）の GitHub Issues」に更新する。それ以外（クローズ役割分担・署名ルール・claude-container issue 起票フロー自体）は変更しない
5. **session-start.sh に sotlas-frontend 自身の open issue 自動注入を追加**: 既存の claude-container issue 確認ブロックとは別に、対象リポジトリ jj1xgo/sotlas-frontend の open issue を注入するブロックを追加する（フェイルソフト設計を維持）
6. **todo.md の廃止**: git rm（履歴は git で追える）
7. **維持するもの**: handover・lessons・incidents・plan ファイルはファイル運用のまま。claude-container issue 確認の逆方向連携（session-start.sh 既存ブロック）も変更しない

## 検証

- `npm run lint` が通ること（ESLint は `src` 配下の js/vue のみ対象で `.claude/hooks/*.sh` は対象外のため、hook 編集後は別途 `bash -n` でシンタックスチェックする）
- session-start hook の手動実行で sotlas-frontend の open issue が注入されることを確認
- `gh issue list` で移行した課題とラベルを確認

## 注意

- クローズは `gh issue close` を正とする
- CLAUDE.md・hooks のみの変更のためリビルド不要
- 署名ルール: sotlas-frontend（ユーザー所有）への投稿は署名する。upstream（manuelkasper/sotlas-frontend）への投稿には署名しない（既存ルールのまま変更不要）
- sotlas-frontend は公開リポジトリのため、issue 本文にホスト固有パス・環境の内部詳細を書かないこと

— Sonnet 5
```

## Fable レビューでの指摘の反映結果（裏取り済み）

- CLAUDE.md「環境課題の連携」節の判定基準が todo.md 廃止後に dead reference になる指摘 → 手順4として追加
- Issues 無効時の起票不可矛盾 → 有効化済みのため解消、PAT の表現を「ユーザー申告済み」に訂正
- `on-hold` ラベルの誤用（機能①②に再検討トリガーが無い） → 機能①②は `enhancement` のみに変更、`on-hold` は claude-container #3/#4 待ちに限定
- 手順の順序（ファイル書き換え前に issue 化を済ませる） → 順序を組み替え
- lint が hooks の bash を検査しない → 検証項目に `bash -n` を追加
- ブラウザ確認ノート消失懸念 → 裏取りの結果、CLAUDE.md「検証方法」節に既に転記済みと確認できたため却下

## 検証

- `gh issue view <番号> --repo JJ1XGO/sotlas-frontend` で起票内容とラベルを確認
- `gh label list --repo JJ1XGO/sotlas-frontend` で `on-hold` 追加を確認
