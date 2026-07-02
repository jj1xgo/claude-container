# Todo

## best_practices 蓄積・注入の仕組み整備（2026-07-02）

findsummits の best_practices.md 自動注入の仕組みを移植。

- [x] CLAUDE.md に `@.claude/best_practices.md` インポート行を追加
- [x] handover の学び5件を lessons.md へ転記
- [x] Fable に session-start.sh 改修を設計させる（lessons.md 全文注入 → watermark 以降の未蒸留分のみ注入）
- [x] `session-start.sh` を Fable 設計案どおり改修
- [x] CLAUDE.md の説明文を実態（未蒸留分のみ注入）に合わせて更新
- [x] `bash -n` 構文チェック
- [x] 実機で session-start.sh を実行し注入内容を目視確認（watermark 未作成時の全件出力・watermark>0の境界条件の両方をテスト）
- [ ] コミット

---

## Dockerfile.claude 軽量化 & bash history 修正

**詳細計画**: `/workspace/.claude/mgmt/plan.md` 参照

### Step 1: `packages.txt` 新規作成
- [x] プロジェクト固有パッケージのみ記載（gcc, make, libpng-dev, python3, python3-pip）
- [x] Claude Code 必須パッケージは Dockerfile にハードコード（git, gh, jq, fzf, unzip, procps, tzdata）
- [x] node:24 に含まれる gcc・python3 を packages.txt から除去（重複排除）

### Step 2: `requirements.txt` 新規作成
- [x] numpy のみ記載

### Step 3: `Dockerfile.claude` の修正
- [x] `FROM node:20` → `FROM node:24`（当初 node:24-slim を採用したが node:24 に変更）
  - node:24 には ca-certificates・gcc・git・python3 が含まれるため HTTPS 切り替えの先行インストール不要
- [x] `ARG TZ=UTC` + `ENV TZ=${TZ}` を apt-get より前に配置（tzdata 非対話インストール対応）
- [x] HTTPS apt sources 切り替えを最初の apt-get 前に追加（HTTP では大容量パッケージのダウンロードが失敗する環境があるため）
- [x] Claude Code 必須パッケージをハードコード
- [x] project-specific パッケージを `packages.txt` 読み込みに変更
- [x] `requirements.txt` 読み込みに変更
- [x] `SNIPPET` ブロック（`/commandhistory` 関連）を削除
- [x] bash history を `/workspace/.claude/bash_history` に永続化

### Step 4: `compose.yml` の修正
- [x] `build.args` に `TZ: ${TZ:-UTC}` を追加

### Step 5: `CLAUDE.md` の更新
- [x] Architecture セクションを `node:24`・`packages.txt`・`requirements.txt` の説明に更新
- [x] Persistence セクションの bash history 説明を修正済みに更新

### Step 6: 動作確認（ホスト側で実行）

**静的チェック：**
- [x] `bash -n claude-container` — PASS
- [x] `podman compose config` — PASS

**ビルド：**
- [x] `podman build --no-cache` — PASS（イメージサイズ: 1.64GB）

**Claude Code ツール：**
- [x] `claude --version` — PASS (2.1.119)
- [x] `gh --version` — PASS (2.23.0)
- [x] `jq --version` — PASS (1.6)

**findsummits 依存：**
- [x] `gcc --version` — PASS (12.2.0)
- [x] `make --version` — PASS (4.3)
- [x] `python3 + numpy` — PASS (numpy 2.4.4)

**TZ：**
- [x] `date` — PASS (UTC確認済み)

**手動確認：**
- [x] bash history 永続化 — PASS（--userns=keep-id が必要）

### ステータス

- 作成日: 2026-04-25
- ステータス: 全 Step 完了（packages.txt 重複除去後の再テストも PASS）

### 今後の課題（このPlanのスコープ外）

- [x] findsummits 側の `.gitignore` に `.claude/bash_history` を追加するよう README に注記追加
- [x] README に `--clean` オプションの説明を追加（イメージ・ネットワーク `claude-container_default`・dangling イメージを削除して終了）

---

## compose.yml マウント変更（2026-04-25）— 完了（断念）

グローバル `~/.claude/` が汚染される問題への対処として compose.yml のマウント構成変更を試みたが、両案とも断念し課題クローズ。

### 案A（試行・失敗・リバート済み）
- `~/.claude` → `${CONTEXT}/.claude` に変更 + `~/.claude/CLAUDE.md` を `:ro` でオーバーレイマウント
- **失敗原因**: `~/.claude/` を差し替えたことでセッション情報にアクセスできなくなり、Claude Code がログインできなかった
- compose.yml は元の状態に戻した

### 案B（断念）
- グローバル `~/.claude/CLAUDE.md` の内容を `/workspace/CLAUDE.md` に統合して1ファイルにする方式
- **断念理由**: 二重管理の問題があり断念

### 結論
- compose.yml は元の `~/.claude` マウントのまま運用
- グローバル `~/.claude/` 汚染問題は許容することとして課題クローズ

---

## 保留

findsummits側からのフィードバック対応（2026-07-02）で、ユーザー判断により今回のスコープ外とした項目。

- **GitHub書き込み認証（GH_TOKEN等）の配線設計**: findsummits側からクロスプロジェクト連絡チャネル（GitHub Issues案）実現のため要望あり。現状このコンテナにはgh認証・SSH鍵・credential helperが一切配線されていない。セキュリティ上の設計判断（トークンの置き場所・スコープ・.claude-container経由でのファイル露出リスク等）が必要なため、着手前にPlan Modeでの合意が必要
- **findsummits側 `.claude-container.d/allowed-domains.txt` へのPyPIドメイン追加**: findsummits側の設定漏れ（`pypi.org`だけでなく`files.pythonhosted.org`も必要）。claude-container側の対応ではなくfindsummits側で行う作業。README側は追記済み（利用側プロジェクトの設定節）
- **findsummits側venv復旧**: `make venv-rebuild`実行によりvenvが空になり、上記PyPI到達不可のためローカル復旧不可能な状態（findsummits側 `.claude/incidents/2026-07-02_2226_venv-rebuild-network-blocked.md` 参照）。findsummits側の作業
