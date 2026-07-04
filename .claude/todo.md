# Todo

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

### ドメイン名ベースのエグレスフィルタ（プロキシ方式）— 見送り（2026-07-04）

claude-container と同様のサンドボックス環境を Web 調査した結果への追加検討。現行の `init-firewall.sh` は CDN 許可ドメインの IP ローテーションに 15 秒間隔の `--refresh-domains` 差分更新で追従しているが、ローテーション直後から反映までの数十秒は新規接続が失敗しうる（README/CLAUDE.md 記載の既知の残存リスク）。この解消策として `nginx stream` の `ssl_preread`（TLS 非終端で SNI のみ検査、証明書検証を損なわない）による代替を Fable（上位モデル）に評価してもらった。

**判断: 実装は見送り、現状維持**

- 技術的には `ssl_preread` 方式が唯一妥当（mitmproxy 的な TLS 終端は攻撃面増大のため不採用）
- 解消されるのは「許容済みの可用性ギャップ」のみで、ドメインフロンティングや DNS トンネリングには無関係 = セキュリティ利得は限定的
- 対価: 常駐プロキシという新しい単一障害点、nginx 依存追加、ECH 普及時に方式ごと無効化される技術負債、HTTP/SSH 等の例外設計の複雑化
- git over SSH（22番、SNI なし）はプロキシを通せないため全面置換は不可、併用前提でも GitHub IP スナップショット方式は残る
- 個人〜小規模メンテ体制で「動いていて理解しやすい15秒ループ」を常駐ミドルウェアに置き換える保守コストが見合わないと判断

**再検討トリガー**: ローテーション起因の接続失敗が**月5回以上**作業を中断するようになった場合、またはECH普及で別の見直しが必要になった場合。（閾値はCDN IPローテーションのTTL 13〜60秒・15秒差分リフレッシュにより大半は自動吸収される想定を踏まえ、ユーザーと合意した数値）

**実装する場合の骨子（トリガー到達時の参考、詳細は再検討時に Plan Mode で計画化）**:
- `Dockerfile.claude`: nginx（streamモジュール）を固定aptレイヤーに追加、専用ユーザー作成
- 新規 `gen-proxy-conf.sh`: `allowed-domains.txt` から `ssl_preread` 許可マップをビルド時生成
- `init-firewall.sh`: `--refresh-domains`／世代タグ機構を削除、TCP/443 を REDIRECT。GitHub CIDR・DNS・SSH ルールは現行維持
- `entrypoint.sh`: nginx起動をfail-closedで疎通確認、リフレッシュループ削除
- 証明書配布は不要（非終端方式のため。これが採用条件）
- 主要判断ポイント: HTTP/80 を遮断で済ませられるか、ECH 対策をどこに置くか

