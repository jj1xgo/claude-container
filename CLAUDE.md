# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

[findsummits](https://github.com/JJ1XGO/findsummits) プロジェクト向けの Claude Code サンドボックス環境。
[sethjensen1/claude-container](https://github.com/sethjensen1/claude-container)（MIT）をフォークし、findsummits の開発環境に合わせてカスタマイズしたもの。apt/pip パッケージは `.claude-container.d/` で利用側プロジェクトごとに指定でき、本リポジトリ自体は特定プロジェクトに依存しない。

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
| `TZ` | Auto-detected from host | Timezone inside the container |
| `CLAUDE_CONTAINER_NO_FIREWALL` | (unset) | Set to `1` to disable the egress allowlist firewall |

These can be set in a `.claude-container` file at the target project root — it is read automatically before launch. Only `KEY=VALUE` lines are honored (values are taken literally after the first `=`; no quoting, expansion, or command execution — the file is deliberately NOT `source`d so a malicious target project cannot run code on the host).

## Architecture

The main files work together:

- **`claude-container`** (bash) — entry point. Resolves absolute paths, reads `KEY=VALUE` lines from the target project's `.claude-container` (safe parse, no `source`), then sets `CONTEXT` and `CLAUDE_CONTAINER_DIR` and delegates to `podman compose run`. When `-b` is passed, sets `CACHEBUST` to the current epoch seconds so the install layer is always rebuilt, and runs `podman compose build` as a separate step before `run` — `run --build` would fall back to the existing stale image when the build fails (fail-open), whereas the separate build step aborts the launch on failure (fail-closed). Before building (on `-b`, or when the image doesn't exist yet), it stages `entrypoint.sh` and `init-firewall.sh` plus the target project's `.claude-container.d/packages.txt` / `requirements.txt` / `allowed-domains.txt` (falling back to claude-container's own bundled copies when the project doesn't provide them) into a fixed path, `.build-context/`, and passes it as `BUILD_CONTEXT_DIR`. A fixed path (not `mktemp -d`) is used so build caching stays stable and no cleanup trap is needed.
- **`compose.yml`** — defines the single service `claude-auth-workspace`. `build.context` is `${BUILD_CONTEXT_DIR}` (the staged directory above); `build.dockerfile` is `${CLAUDE_CONTAINER_DIR}/Dockerfile.claude` — Dockerfiles can live outside the build context, so `Dockerfile.claude` itself is read directly from the claude-container repo without staging. Mounts the host's `~/.claude.json` and `~/.claude/` (auth + config) plus the target workspace at `/workspace`. Uses `userns_mode: keep-id` so files inside the container have the same UID as the host user. Adds `NET_ADMIN`/`NET_RAW` capabilities so `init-firewall.sh` can install iptables rules inside the container's network namespace. Passes `CACHEBUST` as a build arg to enable cache-busting on `-b`.
- **`Dockerfile.claude`** — builds on `debian:stable` (currently trixie), installs Claude Code dependencies and the staged `packages.txt`/`requirements.txt` (see above), then installs Claude Code via the official native installer (`curl -fsSL https://claude.ai/install.sh | bash`). An `ARG CACHEBUST` is declared immediately before the install step and referenced in the `RUN` command; this ensures the install layer (and everything below) is never served from cache when `-b` is used. Runs as the non-root `node` user (UID 1000, created explicitly) with `CMD ["/home/node/entrypoint.sh"]` (which applies the firewall, then execs `claude --dangerously-skip-permissions`). `debian:stable` を採用した理由: native installer の Claude Code バイナリは glibc のみ依存で Node.js を実行時に必要とせず、Node.js 同梱の `node:24` より軽量な Debian ベースで足りるため。注意: `ca-certificates` は debian:stable にも**同梱されていない**ため、HTTP で先行インストールしてから apt sources を HTTPS に書き換える（Dockerfile 冒頭が2段構成なのはこのため。削除しないこと）。
- **`entrypoint.sh`** — コンテナ起動時に実行されるシェルスクリプト。まず `sudo /usr/local/bin/init-firewall.sh` でエグレス制限を適用し（失敗時は起動中断＝fail-closed。`CLAUDE_CONTAINER_NO_FIREWALL=1` で警告表示の上スキップ）、次に `~/.claude/plugins/` 内の設定ファイルに残存するホスト側ユーザーのパス（例: `/home/tsu/.claude`）をコンテナ内パス（`/home/node/.claude`）に自動修正してから `claude --dangerously-skip-permissions` を起動する。ホスト側とコンテナ内でユーザー名が異なる環境でのプラグインパス不整合を吸収するための仕組み。
- **`init-firewall.sh`** — deny-by-default のエグレス許可リスト。Anthropic 公式 devcontainer の同名スクリプトの移植で、iptables で Claude Code に必要なエンドポイント（api.anthropic.com・GitHub IP レンジ等）と `/etc/claude-container/allowed-domains.txt`（ビルド時焼き込み）のドメインのみ許可する。公式との差分: ipset 不使用（rootless podman ではホストの `ip_set` カーネルモジュールを autoload できないため素の iptables ルールで代替）、DNS は `/etc/resolv.conf` のリゾルバ宛のみ、IPv6 は全遮断（許可リストが A レコードのみのため、IPv6 経由のバイパスを防ぐ）。root 所有で node ユーザーは sudoers 定義（`/etc/sudoers.d/node-firewall`）によりこのスクリプトの実行のみ可能 — 実行時にコンテナ内のコードが許可リストを改変できない。設定完了後に example.com 到達不可・api.github.com / api.anthropic.com 到達可を自己検証する。
- **`packages.txt`** / **`requirements.txt`** / **`allowed-domains.txt`** — claude-container's bundled default apt/pip package lists and extra allowed-domain list (fallback values, kept empty). One entry per line; lines starting with `#` are comments. `requirements.txt` is passed to `pip3 install -r`, but the install step is skipped entirely when the file has no real entries — pip3 is not in the base image, so projects that use `requirements.txt` must add `python3-pip` to their `packages.txt` (the Dockerfile fails with an explicit error otherwise). Lines starting with `-` in `packages.txt` are filtered out at install time so apt options cannot be injected. Project-specific entries belong in the target project's `.claude-container.d/`, not here — claude-container itself must stay project-agnostic.

### Project-specific packages (`.claude-container.d/`)

A target project can place `.claude-container.d/packages.txt`, `.claude-container.d/requirements.txt`, and/or `.claude-container.d/allowed-domains.txt` at its root (parallel to `.claude-container` for env vars, but a directory to avoid name collision). If present, these override claude-container's bundled defaults when staging the build context. Absent files fall back silently. `allowed-domains.txt` lists extra domains (e.g. `pypi.org`) the egress firewall should allow; it is baked into the image at build time, so changing it requires a `-b` rebuild.

The image name is fixed as `localhost/claude-container_claude-auth-workspace` (Compose-derived). When `-b` is not passed and the image already exists, Compose skips the build step (and the staging step) entirely.

## Modifying the Image

Edit `Dockerfile.claude` and rebuild with `./claude-container -b /path/to/project`. The `-b` flag passes a `CACHEBUST` build arg (current epoch seconds) that busts the install-layer cache on every run, so `install.sh` always re-executes and fetches the latest Claude Code. Layers above the install step are still served from cache, keeping rebuilds fast. Pin the Claude Code version by setting `CLAUDE_CODE_VERSION` (e.g. `CLAUDE_CODE_VERSION=2.1.119` in the target project's `.claude-container`); it defaults to `latest` and is wired through `build.args` in `compose.yml`.

`.build-context/` is a generated build context under the claude-container repo (git-ignored). It's removed by `./claude-container --clean`.

## Persistence Across Container Runs

コンテナは `--rm` で起動するため終了時に内部の状態は消えるが、以下はホストに bind mount されているため**コンテナを再起動しても保持される**：

| コンテナ内パス | ホスト側 | 内容 |
|---|---|---|
| `/home/node/.claude/` | `~/.claude/` | Claude のメモリ・設定・セッション履歴 |
| `/home/node/.claude.json` | `~/.claude.json` | Claude の認証情報 |
| `/workspace/` | 起動時に指定したディレクトリ | 作業対象プロジェクト |

bash history は `/workspace/.claude/bash_history` に保存される（上表の `/workspace/` マウントにより保持）。

> **利用者向け注意**: ターゲットプロジェクトのリポジトリで `.claude/bash_history` を誤ってコミットしないよう、`.gitignore` に `.claude/bash_history` を追加することを推奨する。

## Security Model

Claude runs with `--dangerously-skip-permissions` inside the container, meaning it operates without tool-use confirmation prompts. The container boundary is the guardrail — Claude has full read/write access to the mounted workspace and `/data`. Do not mount directories containing sensitive data outside the intended project scope.

ネットワーク面は `init-firewall.sh` による deny-by-default のエグレス許可リストで制限される（既定で有効）。認証情報（`~/.claude.json`）やソースが実行時にマウントされるため、悪意ある pip パッケージやプロンプトインジェクションによる外部送信・C2 化を「許可済みエンドポイント以外への通信不可」で封じる。無効化は利用側プロジェクトの `.claude-container` に `CLAUDE_CONTAINER_NO_FIREWALL=1`。

**残存リスク（許可リストでも防げないもの）:**

- DNS トンネリング: リゾルバ宛 53 番は許可されるため、DNS クエリに載せた exfiltration は原理上可能
- 許可済みサービスの悪用: GitHub 等の許可済みドメイン自体を送信先にされるリスクは残る。また CDN 配下のドメイン（claude.ai 等）は IP を共有するため、同一 CDN エッジ上の他サイトへも IP レベルでは到達できる
- IP ローテーション: 許可リストは起動時に解決した IP ベースのため、CDN の IP 変更で長時間セッション中に到達不能になることがある（コンテナ再起動で再解決）
- ビルド時ネットワークは無制限: `pip3 install` は setup.py / build backend の任意コードをビルド時に実行しうる。ただし build context に秘密情報は含まれず、イメージへ焼き込まれた悪性コードの実行時通信は上記 firewall が封じる

## Podman-specific Notes

- `userns_mode: keep-id` maps the host user's UID/GID into the container. This is a Podman feature and has no Docker equivalent — remove it if adapting for Docker.
- `--in-pod false` prevents Podman Compose from wrapping the service in a Pod (the default Podman Compose behavior). Docker Compose ignores this flag.

## Verifying Changes

There is no test suite. After editing the script or Compose/Dockerfile, verify with:

```bash
# Syntax check the shell scripts (use shellcheck too if available)
bash -n claude-container entrypoint.sh init-firewall.sh

# Validate Compose file
podman compose -f compose.yml config
```

---

## 開発ガイドライン

### コア原則

#### 1. 計画を優先する
Plan Modeへの切り替え基準に該当する作業（グローバル CLAUDE.md 参照）は `.claude/plan-<slug>.md` に計画をまとめる。それ以外の軽微な実装タスクは `.claude/todo.md` に直接書く。いずれも承認を得てから実装を始める（詳細は「計画ファイル・handover の扱い」節参照）。

#### 2. サブエージェントを活用
調査・探索・並列作業が必要な場合は、サブエージェントを積極的に使い、メインのコンテキストをクリーンに保つ。
1つのサブエージェントには1つのタスクを明確に割り当てる。

#### 3. 学びを活かす
指摘やフィードバックを受けたときは、`.claude/lessons.md` にそのポイントを簡潔に記録する。
同じ指摘やフィードバックが繰り返さないよう、改善に努める。

#### 4. バグ修正の対応
バグ報告を受けたら、ログやエラー、失敗テストを確認した上で、できる限り自律的に修正する。
必要最小限の変更に留め、ユーザーへの質問は最小限にする。
一時しのぎの修正は避け、なぜそのバグが起きたかを理解した上で本質的な解決を目指す。

### セッション開始時のルーティン（必須）
以下を順番に実行してから作業を始める：

1. `.claude/handovers/` を確認し、過去1週間のファイルを古い順に読む
2. `.claude/lessons.md` を読み、今回のタスクに関連する学びを把握する
3. 関連するレッスンがあれば、作業開始前にユーザーに共有する

作業の区切りやセッション終了時には、`/handover` の実行を促す（または手動でhandoverドキュメントを作成する）。

### タスク管理の流れ
上記ルーティンで把握した情報をもとに、以下の順で進める。

1. 計画を `.claude/todo.md`（軽微タスク）または `.claude/plan-<slug>.md`（Plan Mode 承認済みの本格的な計画）に書く
2. 実装前に計画を確認・承認
3. 進捗をマークしながら作業
4. 各ステップで変更の概要を簡単に説明
5. 完了時に結果をレビューとして記録
6. 修正があったら `.claude/lessons.md` を更新

`.claude/todo.md` は完了した項目を消す（履歴は git で追える）。長期保留中の項目は「保留」セクションへ移す。

### 計画ファイル・handover の扱い

- **plan ファイルの置き場・命名規則**: `.claude/plan-<slug>.md` とする。`<slug>` は `/plan` コマンドが `~/.claude/plans/<slug>.md`（ホーム配下・グローバル）に自動生成する際のファイル名をそのまま流用し、`plan-` プレフィックスは他の運用ファイルとの視認性のためにつける。`ExitPlanMode` 承認後・ファイル編集を始める前に `mv ~/.claude/plans/<slug>.md .claude/plan-<slug>.md` で移動する（両者は `.claude` という名前を含むが別の場所なので、`mv` 実行時は必ずフルパスで確認すること）。セッションごとに `<slug>` が異なるため、複数セッションが同時に Plan Mode を使っても plan ファイルが衝突しない。
- **plan ファイル内のファイル参照はコード表記にする**: `.claude/plan-<slug>.md` 内でリポジトリ内ファイルを参照するときは、Markdown リンクではなく**コード表記（バッククォート）**で書く。`mv` 元（`~/.claude/plans/`）でも移動先（`.claude/plan-<slug>.md`）でも相対リンクが解決せず broken-link になるため、リンクにしないことで構造的に回避する。
- **計画の各タスクに実行モデルを明記する**: グローバル CLAUDE.md「モデルを使い分ける」節参照。
- **handover ファイル名の日時**: ファイル名に使う日時は必ず `date '+%Y-%m-%d_%H%M'` コマンドで実時刻を取得すること。会話履歴や記憶から日付を推測してはならない（同日別セッションとの衝突を防ぐため）。
- **plan ファイルの完了時の扱い**: 計画の実装が完了し区切りがついたら `.claude/plan-<slug>.md` を `git rm` で削除しコミットする（役目を終えた計画は残さない。履歴は git で追える）。ただし作業が中断・持ち越しになり handover を書いて次セッションへ引き継ぐ場合は削除せず残す。次セッションは `<slug>` を含むファイル名とタイムスタンプで対象を特定して再開する。

### ルールと制約
- **Git**：Conventional Commits形式を使用。本文は日本語で記述（例: `feat: ユーザー認証にOAuth2を追加`）。確認なしに自動コミット・自動pushはしない。

### 開発環境
@CLAUDE_ENV.md
