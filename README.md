# claude-container

[日本語](#日本語) | [English](#english)

---

<a id="日本語"></a>

## 日本語

[sethjensen1/claude-container](https://github.com/sethjensen1/claude-container) を、
[findsummits](https://github.com/JJ1XGO/findsummits) の開発環境用にカスタマイズした Podman 上の Claude Code コンテナ実行環境。

Podman + Compose を使い、ホストの Claude 認証情報を共有しながら任意のディレクトリを `/workspace` にマウントして Claude Code を起動する。

他のプロジェクトでも使える様にある程度は汎用化したつもり。

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

**利用側プロジェクト**のルートに `.claude-container` を置くと起動前に自動で読み込まれる。

| 変数 | デフォルト | 説明 |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | `~` | `.claude.json` と `.claude/` が置かれているディレクトリ |
| `EXTRA_MOUNT` | （なし） | コンテナ内 `/data` に追加でマウントするホスト側パス |
| `TZ` | ホストから自動検出 | コンテナ内のタイムゾーン |

`TZ` は起動スクリプトがホストの `/etc/timezone`（なければ `/etc/localtime` シンボリックリンク）から自動検出する。`.claude-container` で明示した場合はそちらが優先される。

### 利用側プロジェクトの設定

bash history はターゲットプロジェクトの `.claude/bash_history` に保存される。誤ってコミットしないよう、ターゲットプロジェクトの `.gitignore` に以下を追加することを推奨する。

```
.claude/bash_history
```

### アーキテクチャ

5つのファイルが連携して動作する。

- **`claude-container`**（bash）— エントリーポイント。絶対パスを解決し、`.env` を読み込み、`TZ` を自動検出した上で `CONTEXT` / `CLAUDE_CONTAINER_DIR` を設定して `podman compose run` に委譲する。
- **`compose.yml`** — サービス `claude-auth-workspace` を定義。ホストの `~/.claude.json` と `~/.claude/`（認証・設定）、対象ワークスペース（`/workspace`）、`/etc/localtime`（タイムゾーン）をマウントする。`userns_mode: keep-id` でコンテナ内ファイルのオーナーをホストユーザーに合わせる。
- **`Dockerfile.claude`** — `debian:stable` をベースにビルド。`ca-certificates` を HTTP でインストール後、apt ソースを HTTPS に書き換えてから残りのパッケージを取得する。Claude Code は公式 native installer（`curl -fsSL https://claude.ai/install.sh | bash`）でインストール。非 root ユーザー `node`（UID 1000、明示的に作成）で `claude --dangerously-skip-permissions` を起動する。`node:24`（約 1.1 GB）から切り替えた理由: native installer は glibc のみ依存で実行時に Node.js を必要としないため、軽量な Debian ベースで十分。slim ではなく full 版を使う理由: full 版には `ca-certificates` 等の基本パッケージが含まれており apt 周りの初期設定が最小限で済む。
- **`packages.txt`** — プロジェクト固有の apt パッケージ一覧。1行1パッケージ、`#` 始まりはコメント扱い。
- **`requirements.txt`** — プロジェクト固有の pip パッケージ一覧。`pip3 install -r` にそのまま渡される。

### イメージの変更

`Dockerfile.claude` を編集して `./claude-container -b /path/to/project` でリビルドする。`-b` を付けると `CACHEBUST` にその時点のエポック秒が渡され、install レイヤーのキャッシュが必ず破棄される。これにより、`-b` のたびに `install.sh` が再実行されて最新版の Claude Code が取得される（apt パッケージ等の上位レイヤーはキャッシュを流用するため高速）。再現性が必要な場合は `compose.yml` で `CLAUDE_CODE_VERSION` を固定する。

Claude Code の自動アップデートは `compose.yml` の `DISABLE_AUTOUPDATER: "1"` で無効化している。コンテナは `--rm` で起動するためアップデートを取得しても終了時に消えるためで、バージョン更新は `-b` でのリビルドで行う。

### コンテナ間の永続化

コンテナは `--rm` で起動するため終了時に内部の状態は消えるが、以下はホストに bind mount されているため**コンテナを再起動しても保持される**。

| コンテナ内パス | ホスト側 | 内容 |
|---|---|---|
| `/home/node/.claude/` | `~/.claude/` | Claude のメモリ・設定・セッション履歴 |
| `/home/node/.claude.json` | `~/.claude.json` | Claude の認証情報 |
| `/workspace/` | 起動時に指定したディレクトリ | 作業対象プロジェクト |

### セキュリティモデル

Claude は `--dangerously-skip-permissions` で起動するため、ツール使用の確認プロンプトなしに動作する。ガードレールはコンテナ境界のみ — マウントされたワークスペースと `/data` への読み書きアクセスを持つ。意図したプロジェクトスコープ外の機密データを含むディレクトリはマウントしないこと。

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

Designed to be general-purpose enough to use with other projects as well.

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

Place a `.claude-container` file at the root of the **target project** to have it sourced automatically before launch.

| Variable | Default | Description |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | `~` | Directory containing `.claude.json` and `.claude/` |
| `EXTRA_MOUNT` | (none) | Additional host path to mount at `/data` inside the container |
| `TZ` | Auto-detected from host | Timezone inside the container |

`TZ` is auto-detected from the host's `/etc/timezone` (or `/etc/localtime` symlink). An explicit value in `.claude-container` takes precedence.

### Target Project Configuration

Bash history is saved to `.claude/bash_history` in the target project. To avoid accidentally committing it, add the following to the target project's `.gitignore`:

```
.claude/bash_history
```

### Architecture

Five files work together:

- **`claude-container`** (bash) — Entry point. Resolves absolute paths, sources `.claude-container`, auto-detects `TZ`, sets `CONTEXT` / `CLAUDE_CONTAINER_DIR`, and delegates to `podman compose run`.
- **`compose.yml`** — Defines the `claude-auth-workspace` service. Mounts `~/.claude.json`, `~/.claude/`, the target workspace (`/workspace`), and `/etc/localtime`. Uses `userns_mode: keep-id` to match the host user's UID/GID.
- **`Dockerfile.claude`** — Based on `debian:stable`. Installs `ca-certificates` via HTTP first, then rewrites apt sources to HTTPS before installing remaining packages. Claude Code is installed via the official native installer (`curl -fsSL https://claude.ai/install.sh | bash`). Runs as the non-root `node` user (UID 1000, created explicitly) with `claude --dangerously-skip-permissions`. Switched from `node:24` (~1.1 GB) because the native installer only requires glibc — no runtime Node.js needed. Full (not slim) Debian is used to avoid extra setup steps that slim requires.
- **`packages.txt`** — Project-specific apt package list. One package per line; lines starting with `#` are comments.
- **`requirements.txt`** — Project-specific pip package list, passed directly to `pip3 install -r`.

### Modifying the Image

Edit `Dockerfile.claude` and rebuild with `./claude-container -b /path/to/project`. The `-b` flag passes a `CACHEBUST` build arg (current epoch seconds) that busts the install-layer cache on every run, so `install.sh` always re-executes and fetches the latest Claude Code. Layers above the install step (apt packages etc.) are still served from cache, keeping rebuilds fast. Pin `CLAUDE_CODE_VERSION` in `compose.yml` if reproducibility matters.

Claude Code's auto-updater is disabled via `DISABLE_AUTOUPDATER: "1"` in `compose.yml`. Since containers run with `--rm`, any updates downloaded at runtime are discarded on exit anyway — use `-b` to rebuild the image when you want a newer version.

### Persistence Across Container Runs

Containers start with `--rm`, so internal state is lost on exit. However, the following bind mounts are **preserved across restarts**:

| Container path | Host path | Contents |
|---|---|---|
| `/home/node/.claude/` | `~/.claude/` | Claude memory, config, session history |
| `/home/node/.claude.json` | `~/.claude.json` | Claude credentials |
| `/workspace/` | Directory specified at launch | Target project |

### Security Model

Claude runs with `--dangerously-skip-permissions`, meaning it operates without tool-use confirmation prompts. The container boundary is the only guardrail — Claude has full read/write access to the mounted workspace and `/data`. Do not mount directories containing sensitive data outside the intended project scope.

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
