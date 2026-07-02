# claude-container

[日本語](#日本語) | [English](#english)

---

<a id="日本語"></a>

## 日本語

[sethjensen1/claude-container](https://github.com/sethjensen1/claude-container) を、
[findsummits](https://github.com/JJ1XGO/findsummits) の開発環境用にカスタマイズした Podman 上の Claude Code コンテナ実行環境。

Podman + Compose を使い、ホストの Claude 認証情報を共有しながら任意のディレクトリを `/workspace` にマウントして Claude Code を起動する。

他のプロジェクトでも使える様にある程度は汎用化したつもり。apt/pip パッケージも `.claude-container.d/`（後述）でプロジェクトごとに指定でき、claude-container リポジトリ自体にはプロジェクト固有のパッケージを持たせない。

### 前提

- [Podman](https://podman.io/) および `podman-compose`
- ホストに `~/.claude.json`（Claude 認証情報）が存在すること

### 使い方

```bash
# 任意のディレクトリで Claude Code を起動
./claude-container /path/to/project

# イメージを強制リビルドして起動
./claude-container -b /path/to/project

# イメージ・ネットワーク・dangling イメージを削除して終了
./claude-container --clean
```

スクリプトはシンボリックリンク経由でも動作する（`readlink` で自身のパスを解決する）。

### 環境変数

**利用側プロジェクト**のルートに `.claude-container` を置くと起動前に自動で読み込まれる。読み込まれるのは `KEY=VALUE` 形式の行のみ（クォートやシェル展開は解釈されない。プロジェクト側ファイルがホスト上でコードを実行できないよう、意図的に `source` していない）。

| 変数 | デフォルト | 説明 |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | `~` | `.claude.json` と `.claude/` が置かれているディレクトリ |
| `EXTRA_MOUNT` | （なし） | コンテナ内 `/data` に追加でマウントするホスト側パス |
| `TZ` | ホストから自動検出 | コンテナ内のタイムゾーン |
| `CLAUDE_CONTAINER_NO_FIREWALL` | （なし） | `1` でエグレス制限（後述）を無効化 |

`TZ` は起動スクリプトがホストの `/etc/timezone`（なければ `/etc/localtime` シンボリックリンク）から自動検出する。`.claude-container` で明示した場合はそちらが優先される。

### 利用側プロジェクトの設定

bash history はターゲットプロジェクトの `.claude/bash_history` に保存される。誤ってコミットしないよう、ターゲットプロジェクトの `.gitignore` に以下を追加することを推奨する。

```
.claude/bash_history
```

**プロジェクト固有の apt/pip パッケージと許可ドメイン**は、ターゲットプロジェクトのルートに `.claude-container.d/` ディレクトリを置くことで指定できる。

```
.claude-container.d/packages.txt         # apt パッケージ（1行1パッケージ、# はコメント）
.claude-container.d/requirements.txt     # pip パッケージ（pip3 install -r にそのまま渡される）
.claude-container.d/allowed-domains.txt  # エグレス制限に追加する許可ドメイン（1行1ドメイン、# はコメント）
```

いずれも任意。置かなければ claude-container 同梱のデフォルト（空のフォールバック）が使われる。`allowed-domains.txt` にはプロジェクトの作業に必要な追加ドメイン（例: `pypi.org`）を書く。ビルド時にイメージへ焼き込まれるため、変更を反映するには `-b` での再ビルドが必要。

### アーキテクチャ

主要ファイルが連携して動作する。

- **`claude-container`**（bash）— エントリーポイント。絶対パスを解決し、`.claude-container` の `KEY=VALUE` 行を読み込み、`TZ` を自動検出した上で `CONTEXT` / `CLAUDE_CONTAINER_DIR` を設定して `podman compose run` に委譲する。ビルド前に、プロジェクト側の `.claude-container.d/packages.txt`・`requirements.txt`・`allowed-domains.txt`（無ければ claude-container 同梱のデフォルト）と `entrypoint.sh`・`init-firewall.sh` を固定パス `.build-context/` に集約し、それを `BUILD_CONTEXT_DIR` としてビルドコンテキストに渡す（`-b` 指定時、またはイメージ未ビルド時のみ実行）。
- **`compose.yml`** — サービス `claude-auth-workspace` を定義。ビルドコンテキストは `${BUILD_CONTEXT_DIR}`（上記でステージングされたディレクトリ）、Dockerfile は `${CLAUDE_CONTAINER_DIR}/Dockerfile.claude` を参照する。ホストの `~/.claude.json` と `~/.claude/`（認証・設定）、対象ワークスペース（`/workspace`）、`/etc/localtime`（タイムゾーン）をマウントする。`userns_mode: keep-id` でコンテナ内ファイルのオーナーをホストユーザーに合わせる。
- **`Dockerfile.claude`** — `debian:stable` をベースにビルド。`ca-certificates` を HTTP でインストール後、apt ソースを HTTPS に書き換えてから残りのパッケージを取得する。Claude Code は公式 native installer（`curl -fsSL https://claude.ai/install.sh | bash`）でインストール。非 root ユーザー `node`（UID 1000、明示的に作成）で `claude --dangerously-skip-permissions` を起動する。`node:24`（約 1.1 GB）から切り替えた理由: native installer は glibc のみ依存で実行時に Node.js を必要としないため、軽量な Debian ベースで十分。slim ではなく full 版を使う理由: full 版には `ca-certificates` 等の基本パッケージが含まれており apt 周りの初期設定が最小限で済む。
- **`init-firewall.sh`** — コンテナ起動時に root（sudo）で実行されるエグレス制限スクリプト。Anthropic 公式 devcontainer の同名スクリプトの移植で、iptables により「許可したドメイン以外への外向き通信を遮断」する（deny-by-default）。Claude Code に必要なエンドポイント（api.anthropic.com・GitHub 等）とプロジェクト指定の `allowed-domains.txt` のみ許可し、設定後に example.com へ到達**できない**こと・api.github.com / api.anthropic.com へ到達**できる**ことを自己検証する。失敗時はコンテナを起動しない（fail-closed）。
- **`packages.txt`** / **`requirements.txt`** / **`allowed-domains.txt`** — claude-container 同梱のデフォルト apt/pip パッケージ・許可ドメイン一覧（フォールバック既定値）。プロジェクト側で上書きする場合は `.claude-container.d/` を使う（「利用側プロジェクトの設定」参照）。

### イメージの変更

`Dockerfile.claude` を編集して `./claude-container -b /path/to/project` でリビルドする。`-b` を付けると `CACHEBUST` にその時点のエポック秒が渡され、install レイヤーのキャッシュが必ず破棄される。これにより、`-b` のたびに `install.sh` が再実行されて最新版の Claude Code が取得される（apt パッケージ等の上位レイヤーはキャッシュを流用するため高速）。再現性が必要な場合は `compose.yml` で `CLAUDE_CODE_VERSION` を固定する。

`.claude-container.d/` のパッケージ一覧や許可ドメイン（`allowed-domains.txt`）を変更した場合も、イメージへ反映するには `-b` での再ビルドが必要。

`.build-context/` は claude-container リポジトリ直下に生成されるビルドコンテキストの生成物（`.gitignore` 対象）で、`./claude-container --clean` で削除される。

Claude Code の自動アップデートは `compose.yml` の `DISABLE_AUTOUPDATER: "1"` で無効化している。コンテナは `--rm` で起動するためアップデートを取得しても終了時に消えるためで、バージョン更新は `-b` でのリビルドで行う。

### コンテナ間の永続化

コンテナは `--rm` で起動するため終了時に内部の状態は消えるが、以下はホストに bind mount されているため**コンテナを再起動しても保持される**。

| コンテナ内パス | ホスト側 | 内容 |
|---|---|---|
| `/home/node/.claude/` | `~/.claude/` | Claude のメモリ・設定・セッション履歴 |
| `/home/node/.claude.json` | `~/.claude.json` | Claude の認証情報 |
| `/workspace/` | 起動時に指定したディレクトリ | 作業対象プロジェクト |

### セキュリティモデル

Claude は `--dangerously-skip-permissions` で起動するため、ツール使用の確認プロンプトなしに動作する。ガードレールはコンテナ境界 — マウントされたワークスペースと `/data` への読み書きアクセスを持つ。意図したプロジェクトスコープ外の機密データを含むディレクトリはマウントしないこと。

ネットワークは既定で `init-firewall.sh` によるエグレス許可リストで制限される。Claude Code に必要なエンドポイント（Anthropic API・GitHub 等）と `.claude-container.d/allowed-domains.txt` で指定したドメイン以外への外向き通信は遮断されるため、悪意ある pip パッケージやプロンプトインジェクションが認証情報（`~/.claude.json`）やソースコードを任意の外部ホストへ送信することを防ぐ。開放が必要な場合は `.claude-container` に `CLAUDE_CONTAINER_NO_FIREWALL=1` を書いて無効化できる（自己責任）。

**制限しても残るリスク**: DNS クエリを使ったトンネリング、許可済みサービス（GitHub 等）自体への送信、CDN の共有 IP 経由の到達は原理上防げない。また許可リストは起動時に解決した IP ベースのため、CDN の IP 変更で長時間セッション中に到達不能になった場合はコンテナを再起動する。ビルド時（`pip3 install` 等）のネットワークは制限されない。

### Podman 固有の注意

- `userns_mode: keep-id` はホストユーザーの UID/GID をコンテナ内にマップする Podman 固有の機能。Docker に移植する場合は削除する。
- `--in-pod false` は Podman Compose がデフォルトでサービスを Pod にラップする挙動を抑制する。Docker Compose はこのフラグを無視する。

### 変更後の確認

テストスイートはない。スクリプトや Compose / Dockerfile を編集した後は以下で確認する。

```bash
# シェルスクリプトの構文チェック
bash -n claude-container

# Compose ファイルの検証
podman compose -f compose.yml config
```

### 参考

- [Running Claude Code CLI in a Container (Endpoint Dev Blog)](https://www.endpointdev.com/blog/2026/03/claude-code-cli-in-container/) — フォーク元作者 Seth Jensen によるコンテナ化の解説記事

### ライセンス

GPL-3.0。フォーク元（sethjensen1/claude-container）は MIT ライセンス。詳細は [LICENSE](LICENSE) を参照。

---

<a id="english"></a>

## English

A Podman-based Claude Code container environment, forked from [sethjensen1/claude-container](https://github.com/sethjensen1/claude-container) and customized for the [findsummits](https://github.com/JJ1XGO/findsummits) development environment.

Launches Claude Code by mounting any directory as `/workspace`, sharing the host's Claude credentials via Podman + Compose.

Designed to be general-purpose enough to use with other projects as well. apt/pip packages are also per-project via `.claude-container.d/` (see below) — the claude-container repo itself carries no project-specific packages.

### Requirements

- [Podman](https://podman.io/) and `podman-compose`
- `~/.claude.json` (Claude credentials) must exist on the host

### Usage

```bash
# Launch Claude Code in any directory
./claude-container /path/to/project

# Force rebuild the image and launch
./claude-container -b /path/to/project

# Remove image, network, and dangling images
./claude-container --clean
```

The script works via symlink — it resolves its own path using `readlink`.

### Environment Variables

Place a `.claude-container` file at the root of the **target project** to have it read automatically before launch. Only `KEY=VALUE` lines are honored (no quoting or shell expansion — the file is deliberately NOT `source`d, so a target project cannot execute code on the host).

| Variable | Default | Description |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | `~` | Directory containing `.claude.json` and `.claude/` |
| `EXTRA_MOUNT` | (none) | Additional host path to mount at `/data` inside the container |
| `TZ` | Auto-detected from host | Timezone inside the container |
| `CLAUDE_CONTAINER_NO_FIREWALL` | (none) | Set to `1` to disable the egress firewall (see below) |

`TZ` is auto-detected from the host's `/etc/timezone` (or `/etc/localtime` symlink). An explicit value in `.claude-container` takes precedence.

### Target Project Configuration

Bash history is saved to `.claude/bash_history` in the target project. To avoid accidentally committing it, add the following to the target project's `.gitignore`:

```
.claude/bash_history
```

**Project-specific apt/pip packages and allowed domains** can be declared by placing a `.claude-container.d/` directory at the root of the target project:

```
.claude-container.d/packages.txt         # apt packages, one per line; lines starting with # are comments
.claude-container.d/requirements.txt     # pip packages, passed directly to pip3 install -r
.claude-container.d/allowed-domains.txt  # extra domains for the egress firewall, one per line; # for comments
```

All are optional. If absent, claude-container's bundled defaults (empty fallbacks) are used. `allowed-domains.txt` lists extra domains the project needs (e.g. `pypi.org`). It is baked into the image at build time, so changing it requires a `-b` rebuild.

### Architecture

The main files work together:

- **`claude-container`** (bash) — Entry point. Resolves absolute paths, reads `KEY=VALUE` lines from `.claude-container` (safe parse, no `source`), auto-detects `TZ`, sets `CONTEXT` / `CLAUDE_CONTAINER_DIR`, and delegates to `podman compose run`. Before building, it stages `entrypoint.sh` and `init-firewall.sh` plus the project's `.claude-container.d/packages.txt` / `requirements.txt` / `allowed-domains.txt` (or claude-container's bundled defaults if absent) into a fixed path, `.build-context/`, and passes that as `BUILD_CONTEXT_DIR` (only when `-b` is passed, or when the image hasn't been built yet).
- **`compose.yml`** — Defines the `claude-auth-workspace` service. The build context is `${BUILD_CONTEXT_DIR}` (the staged directory above); the Dockerfile is `${CLAUDE_CONTAINER_DIR}/Dockerfile.claude`. Mounts `~/.claude.json`, `~/.claude/`, the target workspace (`/workspace`), and `/etc/localtime`. Uses `userns_mode: keep-id` to match the host user's UID/GID.
- **`Dockerfile.claude`** — Based on `debian:stable`. Installs `ca-certificates` via HTTP first, then rewrites apt sources to HTTPS before installing remaining packages. Claude Code is installed via the official native installer (`curl -fsSL https://claude.ai/install.sh | bash`). Runs as the non-root `node` user (UID 1000, created explicitly) with `claude --dangerously-skip-permissions`. Switched from `node:24` (~1.1 GB) because the native installer only requires glibc — no runtime Node.js needed. Full (not slim) Debian is used to avoid extra setup steps that slim requires.
- **`init-firewall.sh`** — Egress firewall script run as root (via sudo) at container startup. A port of the same-named script from Anthropic's official devcontainer: it blocks all outbound traffic except allowed destinations (deny-by-default iptables rules). Only the endpoints Claude Code needs (api.anthropic.com, GitHub, etc.) and the project's `allowed-domains.txt` are allowed. After setup it self-verifies that example.com is **unreachable** and api.github.com / api.anthropic.com **are** reachable, and refuses to start the container on failure (fail-closed).
- **`packages.txt`** / **`requirements.txt`** / **`allowed-domains.txt`** — claude-container's bundled default apt/pip package and allowed-domain lists (fallback values). Projects override these via `.claude-container.d/` (see "Target Project Configuration" above).

### Modifying the Image

Edit `Dockerfile.claude` and rebuild with `./claude-container -b /path/to/project`. The `-b` flag passes a `CACHEBUST` build arg (current epoch seconds) that busts the install-layer cache on every run, so `install.sh` always re-executes and fetches the latest Claude Code. Layers above the install step (apt packages etc.) are still served from cache, keeping rebuilds fast. Pin `CLAUDE_CODE_VERSION` in `compose.yml` if reproducibility matters.

Changes to the package lists or allowed domains (`allowed-domains.txt`) under `.claude-container.d/` also require a `-b` rebuild to take effect.

`.build-context/` is a generated build context under the claude-container repo (git-ignored) and is removed by `./claude-container --clean`.

Claude Code's auto-updater is disabled via `DISABLE_AUTOUPDATER: "1"` in `compose.yml`. Since containers run with `--rm`, any updates downloaded at runtime are discarded on exit anyway — use `-b` to rebuild the image when you want a newer version.

### Persistence Across Container Runs

Containers start with `--rm`, so internal state is lost on exit. However, the following bind mounts are **preserved across restarts**:

| Container path | Host path | Contents |
|---|---|---|
| `/home/node/.claude/` | `~/.claude/` | Claude memory, config, session history |
| `/home/node/.claude.json` | `~/.claude.json` | Claude credentials |
| `/workspace/` | Directory specified at launch | Target project |

### Security Model

Claude runs with `--dangerously-skip-permissions`, meaning it operates without tool-use confirmation prompts. The container boundary is the guardrail — Claude has full read/write access to the mounted workspace and `/data`. Do not mount directories containing sensitive data outside the intended project scope.

Network access is restricted by default via the `init-firewall.sh` egress allowlist. Outbound traffic to anything other than the endpoints Claude Code needs (Anthropic API, GitHub, etc.) and the domains listed in `.claude-container.d/allowed-domains.txt` is blocked, preventing malicious pip packages or prompt injection from exfiltrating credentials (`~/.claude.json`) or source code to arbitrary hosts. If you need unrestricted network access, set `CLAUDE_CONTAINER_NO_FIREWALL=1` in `.claude-container` (at your own risk).

**Residual risks the allowlist cannot prevent**: tunneling over DNS queries, exfiltration to allowed services themselves (e.g. GitHub), and reachability of other sites behind shared CDN IPs. The allowlist is based on IPs resolved at startup, so if a CDN rotates IPs during a long session, restart the container to re-resolve. Build-time network access (`pip3 install` etc.) is not restricted.

### Podman-specific Notes

- `userns_mode: keep-id` maps the host user's UID/GID into the container. This is a Podman feature — remove it if adapting for Docker.
- `--in-pod false` prevents Podman Compose from wrapping the service in a Pod (default Podman Compose behavior). Docker Compose ignores this flag.

### Verifying Changes

There is no test suite. After editing the script or Compose/Dockerfile, verify with:

```bash
# Syntax check the shell script
bash -n claude-container

# Validate Compose file
podman compose -f compose.yml config
```

### References

- [Running Claude Code CLI in a Container (Endpoint Dev Blog)](https://www.endpointdev.com/blog/2026/03/claude-code-cli-in-container/) — Container setup guide by Seth Jensen, the original fork author

### License

GPL-3.0. The original fork ([sethjensen1/claude-container](https://github.com/sethjensen1/claude-container)) is MIT-licensed. See [LICENSE](LICENSE) for details.
