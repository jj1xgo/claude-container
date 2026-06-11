# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

[findsummits](https://github.com/JJ1XGO/findsummits) プロジェクト向けの Claude Code サンドボックス環境。
[sethjensen1/claude-container](https://github.com/sethjensen1/claude-container)（MIT）をフォークし、findsummits の開発環境に合わせてカスタマイズしたもの。

## Usage

```bash
# Run Claude in a target directory
./claude-container /path/to/project

# Force image rebuild
./claude-container -b /path/to/project
```

The script can be symlinked anywhere; it resolves its own location via `readlink` to find `compose.yml` and `Dockerfile.claude`.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | `~` | Directory containing `.claude.json` and `.claude/` |
| `EXTRA_MOUNT` | `/dev/null` | Additional host path mounted at `/data` inside the container |

These can be set in a `.env` file at the target project root — it is sourced automatically before launch.

## Architecture

Three files work together:

- **`claude-container`** (bash) — entry point. Resolves absolute paths, loads `.env`, then sets `CONTEXT` and `CLAUDE_CONTAINER_DIR` and delegates to `podman compose run`. When `-b` is passed, sets `CACHEBUST` to the current epoch seconds so the install layer is always rebuilt.
- **`compose.yml`** — defines the single service `claude-auth-workspace`. Mounts the host's `~/.claude.json` and `~/.claude/` (auth + config) plus the target workspace at `/workspace`. Uses `userns_mode: keep-id` so files inside the container have the same UID as the host user. Passes `CACHEBUST` as a build arg to enable cache-busting on `-b`.
- **`Dockerfile.claude`** — builds on `debian:stable` (currently trixie), installs Claude Code dependencies and project-specific packages, then installs Claude Code via the official native installer (`curl -fsSL https://claude.ai/install.sh | bash`). An `ARG CACHEBUST` is declared immediately before the install step and referenced in the `RUN` command; this ensures the install layer (and everything below) is never served from cache when `-b` is used. Runs as the non-root `node` user (UID 1000, created explicitly) with `CMD ["claude", "--dangerously-skip-permissions"]`. `debian:stable` を採用した理由: 公式推奨インストール方法が native installer に変わり、Claude Code のネイティブバイナリは glibc のみ依存で Node.js を実行時に必要としない。Node.js 同梱の `node:24`（約 1.1 GB）は不要になったため軽量な Debian ベースに切り替え、最終イメージサイズを大幅に削減。slim ではなく full 版を使う理由: `ca-certificates` が同梱されており、HTTPS apt の順序問題を回避できる。
- **`packages.txt`** — project-specific apt package list. One package per line; lines starting with `#` are treated as comments and ignored.
- **`requirements.txt`** — project-specific pip package list, passed directly to `pip3 install -r`.

The image name is fixed as `localhost/claude-container_claude-auth-workspace` (Compose-derived). When `-b` is not passed and the image already exists, Compose skips the build step entirely.

## Modifying the Image

Edit `Dockerfile.claude` and rebuild with `./claude-container -b /path/to/project`. The `-b` flag passes a `CACHEBUST` build arg (current epoch seconds) that busts the install-layer cache on every run, so `install.sh` always re-executes and fetches the latest Claude Code. Layers above the install step are still served from cache, keeping rebuilds fast. Pin `CLAUDE_CODE_VERSION` in `compose.yml` if reproducibility matters.

## Persistence Across Container Runs

コンテナは `--rm` で起動するため終了時に内部の状態は消えるが、以下はホストに bind mount されているため**コンテナを再起動しても保持される**：

| コンテナ内パス | ホスト側 | 内容 |
|---|---|---|
| `/home/node/.claude/` | `~/.claude/` | Claude のメモリ・設定・セッション履歴 |
| `/home/node/.claude.json` | `~/.claude.json` | Claude の認証情報 |
| `/workspace/` | 起動時に指定したディレクトリ | 作業対象プロジェクト |

bash history は `/workspace/.claude/bash_history` に保存される。`/workspace/` はホストに bind mount されているため、**コンテナを再起動しても保持される**。

> **利用者向け注意**: ターゲットプロジェクトのリポジトリで `.claude/bash_history` を誤ってコミットしないよう、`.gitignore` に `.claude/bash_history` を追加することを推奨する。

## Security Model

Claude runs with `--dangerously-skip-permissions` inside the container, meaning it operates without tool-use confirmation prompts. The container boundary is the only guardrail — Claude has full read/write access to the mounted workspace and `/data`. Do not mount directories containing sensitive data outside the intended project scope.

## Podman-specific Notes

- `userns_mode: keep-id` maps the host user's UID/GID into the container. This is a Podman feature and has no Docker equivalent — remove it if adapting for Docker.
- `--in-pod false` prevents Podman Compose from wrapping the service in a Pod (the default Podman Compose behavior). Docker Compose ignores this flag.

## Verifying Changes

There is no test suite. After editing the script or Compose/Dockerfile, verify with:

```bash
# Syntax check the shell script
bash -n claude-container

# Validate Compose file
podman compose -f compose.yml config
```

---

## 開発ガイドライン

### コア原則

#### 1. 計画を優先する
小さな修正（1〜4ステップで終わる明らかな作業）以外は、まず計画を立てる。
以下に該当する場合は、実装を始める前にユーザーにPlan Modeへの切り替えを提案する：
- 5ステップ以上になる作業
- 複数ファイルにまたがる変更
- アーキテクチャ判断が必要な場合
- このまま進めると後で修正が増えると判断した場合

計画は `.claude/mgmt/todo.md` に簡潔にまとめ、承認を得てから実装を始める。

#### 2. サブエージェントを活用
調査・探索・並列作業が必要な場合は、サブエージェントを積極的に使い、メインのコンテキストをクリーンに保つ。
1つのサブエージェントには1つのタスクを明確に割り当てる。

#### 3. 検証を徹底する
タスクを完了とする前に、必ず動作を確認する。
テストを実行し、ログや差分をチェックして、正しさを明確に示す。

#### 4. 学びを活かす
指摘やフィードバックを受けたときは、`.claude/mgmt/lessons.md` にそのポイントを簡潔に記録する。
同じ指摘やフィードバックが繰り返さないよう、改善に努める。

#### 5. バグ修正の対応
バグ報告を受けたら、ログやエラー、失敗テストを確認した上で、できる限り自律的に修正する。
必要最小限の変更に留め、ユーザーへの質問は最小限にする。
一時しのぎの修正は避け、なぜそのバグが起きたかを理解した上で本質的な解決を目指す。

### コミュニケーションスタイル
- **日本語で応答**する（コード、変数名、ファイル名は英語のまま）
- 回答は**簡潔に**。自明な説明は省略し、要約は箇条書きにする
- フィードバックは**率直に**（遠回しや婉曲な表現は避ける）
- 質問は1度につき**1つだけ**にする
- 複雑なタスクは、実装前に計画を提示して承認を得てから着手する

### セッション開始時のルーティン（必須）
以下を順番に実行してから作業を始める：

1. `.claude/handovers/` を確認し、過去1週間のファイルを古い順に読む
2. `.claude/mgmt/lessons.md` を読み、今回のタスクに関連する学びを把握する
3. 関連するレッスンがあれば、作業開始前にユーザーに共有する

作業の区切りやセッション終了時には、`/handover` の実行を促す（または手動でhandoverドキュメントを作成する）

### タスク管理の流れ
上記ルーティンで把握した情報をもとに、以下の順で進める。

1. 計画を `.claude/mgmt/todo.md` に書く
2. 実装前に計画を確認・承認
3. 進捗をマークしながら作業
4. 各ステップで変更の概要を簡単に説明
5. 完了時に結果をレビューとして記録
6. 修正があったら `.claude/mgmt/lessons.md` を更新

**plan.md の置き場**: `/workspace/.claude/mgmt/plan.md`
`/plan` コマンドはシステムの都合で `/home/node/.claude/plans/` に自動生成するため、セッション終了前に手動で移動する。

### ルールと制約
- **Git**：Conventional Commits形式を使用。本文は日本語で記述（例: `feat: ユーザー認証にOAuth2を追加`）。確認なしに自動コミット・自動pushはしない。
- **禁止事項**：READMEやドキュメントを勝手に生成・変更しない、テストコードを確認なしに削除・コメントアウトしない、既存の動作するコードを理由なくリファクタリングしない。

### 開発環境
@CLAUDE_ENV.md
