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

# そのプロジェクトのイメージ・ネットワーク・ビルドコンテキストを削除して終了
./claude-container --clean /path/to/project

# 全プロジェクト分のイメージ・ネットワーク・ビルドコンテキストを削除して終了
./claude-container --clean
```

スクリプトはシンボリックリンク経由でも動作する（`readlink` で自身のパスを解決する）。異なるターゲットプロジェクトを交互に起動・リビルドしても互いのイメージ・ビルドコンテキストを上書きしない（後述「アーキテクチャ」参照）。同時に別々のプロジェクトを起動することもできる。

### 環境変数

**利用側プロジェクト**のルートに `.claude-container.d/env` を置くと起動前に自動で読み込まれる。読み込まれるのは `KEY=VALUE` 形式の行のみ（クォートやシェル展開は解釈されない。プロジェクト側ファイルがホスト上でコードを実行できないよう、意図的に `source` していない）。これはビルド時に焼き込まれる設定ではなく起動のたび毎回読み込まれるランタイム設定なので、変更してもリビルド（`-b`）は不要。

| 変数 | デフォルト | 説明 |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | `~` | `.claude.json` と `.claude/` が置かれているディレクトリ |
| `EXTRA_MOUNT` | `/dev/null` | コンテナ内 `/data` に追加でマウントするホスト側パス |
| `TZ` | ホストから自動検出 | コンテナ内のタイムゾーン |
| `CLAUDE_CONTAINER_NO_FIREWALL` | (unset) | `1` でエグレス制限（後述）を無効化 |
| `GH_TOKEN_FILE` | (unset) | GitHub Issues 書き込み用トークンを保存したホスト側ファイルへの絶対パス（後述） |
| `GITCONFIG_FILE` | (unset) | コンテナ内 `~/.gitconfig` として read-only マウントするホスト側 git 設定ファイルのパス（後述） |

`TZ` は起動スクリプトがホストの `/etc/timezone`（なければ `/etc/localtime` シンボリックリンク）から自動検出する。`.claude-container.d/env` で明示した場合はそちらが優先される。

claude-container 自身を対象プロジェクトとして自己ホスト起動する場合（このリポジトリを直接 `./claude-container` の引数に渡す場合）は、`.claude-container.d/env.example` をコピーして `.claude-container.d/env` を作成する。`GH_TOKEN_FILE` 等ホスト固有のパスを含みうるため `.claude-container.d/env` は gitignore 対象で、リポジトリには example のみをコミットする。

### 利用側プロジェクトの設定

bash history はターゲットプロジェクトの `.claude/bash_history` に保存される。誤ってコミットしないよう、ターゲットプロジェクトの `.gitignore` に以下を追加することを推奨する。

```
.claude/bash_history
```

利用側プロジェクトの claude-container 向け設定は `.claude-container.d/` ディレクトリに一本化されている。中身は「起動のたび読み込まれるランタイム設定」と「ビルド時にイメージへ焼き込まれる設定」の2種類に分かれる。

```
.claude-container.d/env                  # ランタイム設定（KEY=VALUE、上記「環境変数」参照）。-b 不要、gitignore 対象
.claude-container.d/packages.txt         # apt パッケージ（1行1パッケージ、# はコメント）。-b 必須、コミット対象
.claude-container.d/requirements.txt     # pip パッケージ（pip3 install -r にそのまま渡される）。-b 必須、コミット対象
.claude-container.d/allowed-domains.txt  # エグレス制限に追加する許可ドメイン（1行1ドメイン、# はコメント）。-b 必須、コミット対象
.claude-container.d/node-version.txt     # 導入する Node.js のバージョン（例: 22.14.0、1行のみ）。-b 必須、コミット対象
```

`env` 以外は任意。`packages.txt`/`requirements.txt`/`allowed-domains.txt` を置かなければ claude-container 同梱のデフォルト（空のフォールバック）が使われる。`allowed-domains.txt` にはプロジェクトの作業に必要な追加ドメイン（例: pip なら `pypi.org` と、パッケージ本体の実ダウンロード先である `files.pythonhosted.org` の両方— index への到達だけでは `pip install` は完走しない）を書く。ビルド時にイメージへ焼き込まれるため、変更を反映するには `-b` での再ビルドが必要（`env` はこのビルド時焼き込みの対象外 — ホスト固有パスをイメージに含めないため）。

`node-version.txt` は apt の debian:stable では入手できない Node.js バージョン（例: 22.x — trixie は 20.x、testing は 22 を飛ばして 24.x）が必要な場合に使う。nodejs.org 公式の Linux tarball を取得し、同梱の `SHASUMS256.txt` でチェックサム検証したうえで展開する。**ビルド時ネットワークは無制限のため、`allowed-domains.txt` に `nodejs.org` を追加する必要はない**（`init-firewall.sh` のエグレス制限はランタイムにのみ適用される）。置かなければ Node.js は導入されない（他の3ファイルと異なり、この場合は WARNING も出ない — 新設の任意機能であり、大多数のプロジェクトが使わないのが正常な状態のため）。

**GitHub Issues への書き込み（`GH_TOKEN_FILE`）**: コンテナ内から `gh` CLI で GitHub Issues に書き込む（例: クロスプロジェクト連絡用の issue 作成）場合、以下の手順でトークンを配線する。

**重要**: 「`.claude-container.d/env` を置く場所」と「PATの `Repository access` で選ぶリポジトリ」は別物である。前者はトークンを**使う側**のプロジェクト（例: findsummits）、後者はIssueの**書き込み先**リポジトリ（例: claude-container）を指す。findsummits から claude-container の Issue に書き込みたい場合、`.claude-container.d/env` は findsummits 側に置き、PATの `Repository access` には `claude-container` を選択する — 自分自身（使う側）のリポジトリを登録するわけではない。

1. GitHub の Settings → Developer settings → Personal access tokens → Fine-grained tokens で新規トークンを作成する。**classic PAT は使わない**（最小の書き込みスコープ `repo` でも全リポジトリのコード読み書きを含んでしまい、漏洩時の被害が過大なため）。設定は以下:
   - Repository access: `Only select repositories` → 連絡用リポジトリのみ選択
   - Repository permissions: `Issues: Read and write` のみ（`Contents`・`Pull requests` 等は付与しない）
   - Expiration: 90日以下を推奨
2. トークン文字列を、`.claude-container.d/env` とは別の、コミット対象ディレクトリの外側にあるファイルに保存する（例: `~/.config/claude-container/<project>-gh-token`）。`chmod 600` で権限を絞ること。
3. ターゲットプロジェクトの `.claude-container.d/env` に、トークン本体ではなく**そのファイルへのパス**だけを書く: `GH_TOKEN_FILE=~/.config/claude-container/<project>-gh-token`。`.claude-container.d/env` はホスト固有のパスを含みうるため gitignore 対象であり、そもそもコミットされない。
4. ファイルが存在しない・通常ファイルでない場合は起動時にエラーで停止する（fail-closed）。パーミッションが `600` でない場合は警告が出る。

トークンはホスト上のファイルとしてのみ扱われ、コンテナの `environment:` には渡らない（`podman inspect` 等にも露出しない）。コンテナ起動時に `entrypoint.sh` がファイルの中身を読んで `GH_TOKEN` としてエクスポートし、`gh` CLI がこれを自動認識する。

**トークンの更新**: 期限が近づいたら GitHub 側でトークンを再生成し、`GH_TOKEN_FILE` が指すファイル（例: `~/.config/claude-container/<project>-gh-token`）の中身を新しい文字列で上書きするだけでよい。`GH_TOKEN_FILE` はビルド時に焼き込まれる設定ではなくランタイムマウントなので、リビルド（`-b`）は不要 — 次回起動時に `entrypoint.sh` が新しい中身を読み直す。

**注意**: 起動時のチェックはファイルの存在とパーミッションのみで、トークン自体が期限切れかどうかは検証しない。期限切れのトークンが入っていてもコンテナは正常に起動し、実際に `gh` コマンドで GitHub API を呼んだ時点で初めて認証エラーになる。気づかず放置しないよう、設定した `Expiration` をどこかにメモしておくこと。

**コンテナ内 git commit（`GITCONFIG_FILE`）**: ホストで `git config --global user.name`/`user.email` を設定していても、デフォルトではコンテナ内に反映されず `git commit` が `Author identity unknown` で失敗する。`.claude-container.d/env` に以下を書くと解消する。

```
GITCONFIG_FILE=~/.gitconfig
```

- 未設定なら従来どおり（`git commit` が `Author identity unknown` で失敗するだけで、他への影響はない）
- 設定した場合、指定ファイルが存在しなければ起動時にエラーで停止する（fail-closed）。存在しないパスをそのまま bind mount すると、ホスト側にその名前の空ディレクトリが誤って作られてしまう問題を避けるため
- read-only マウントのため、コンテナ内から `git config --global` で書き換えることはできない。編集は常にホスト側で行う（ランタイムマウントなので `-b` 再ビルドは不要、次回起動時に反映される）
- `.gitconfig` に `credential.helper` や `include.path` でホスト固有の別ファイルを参照する記述があっても、`git commit` 自体には影響しない（参照先が無ければ黙って無視される、または認証操作時に警告が出る程度）。気になる場合は `user.name`/`user.email` のみを書いた専用ファイルを別途用意し、そちらのパスを `GITCONFIG_FILE` に指定するとよい
- `GITCONFIG_FILE` を設定しても反映されない場合、`/workspace`（起動時に指定したターゲットプロジェクト）自身の `.git/config` に `user.name`/`user.email` が設定されていないか確認する。git の設定優先順位（local > global）により、マウントした `~/.gitconfig`（global 相当）より対象プロジェクトのローカル設定が優先されてしまう

**venv 等の言語ランタイム成果物は必ずコンテナ内で作成する。** ホスト側で `python3 -m venv` 等を実行してターゲットプロジェクト配下に作った場合、生成されるスクリプトのシェバン（例: `venv/bin/pip` の1行目）にホストの絶対パス・ユーザー名（例: `/home/alice/myproject/venv/bin/python3`）が焼き込まれる。同じディレクトリはコンテナ内では `/workspace` 配下・ユーザー `node` としてマウントされるため、そのパスは解決できずシェバン経由の実行（`./venv/bin/djlint` 等）が失敗する（`venv/bin/python3 -m djlint` のように venv 内の python3 をモジュール起動すれば回避できる。素の `python3` はシステム Python で venv の site-packages を見ないため不可）。venv はコンテナを起動してからその中で作成すること。

### アーキテクチャ

主要ファイルが連携して動作する。

- **`claude-container`**（bash）— エントリーポイント。絶対パスを解決し、ターゲットプロジェクトのディレクトリ名（basename）をサニタイズした文字列に絶対パスの sha256 先頭8文字を付与した `PROJECT_NAME` を算出する（例: `findsummits-3f2a9c1b`）。これによりイメージ名（`localhost/<PROJECT_NAME>_claude-auth-workspace`）とビルドコンテキストのステージング先（`.build-context/<PROJECT_NAME>/`）をプロジェクトごとに分離し、`podman compose -p "$PROJECT_NAME"` でプロジェクト名を明示する。以前は全プロジェクト共通の固定イメージ名・固定ステージング先だったため、異なるプロジェクトを交互にビルドすると後勝ちで上書きされる問題があった。`.claude-container.d/env` の `KEY=VALUE` 行を読み込み、`TZ` を自動検出した上で `CONTEXT` / `CLAUDE_CONTAINER_DIR` を設定して `podman compose run` に委譲する。`-b` 指定時は `podman compose build` を `run` とは別ステップで実行する — `run --build` はビルド失敗時に既存の古いイメージへフォールバックしてしまう（fail-open）ため、分離して失敗時は起動へ進ませない（fail-closed）。ビルド前に、プロジェクト側の `.claude-container.d/packages.txt`・`requirements.txt`・`allowed-domains.txt`（無ければ claude-container 同梱のデフォルト）・`node-version.txt`（無ければ空ファイルを都度生成。他の3ファイルと異なり同梱のデフォルトファイルは持たず、WARNING も出さない）と `entrypoint.sh`・`init-firewall.sh`・GitHub meta スナップショット（後述）をこのプロジェクト専用の `BUILD_CONTEXT_DIR` に集約する（`-b` 指定時、またはイメージ未ビルド時のみ実行）。`--clean <directory>` はそのプロジェクト分のイメージ・ネットワーク・ビルドコンテキストのみを、`--clean`（引数なし）は実在する claude-container イメージ全てを走査して全プロジェクト分を削除する（レガシーの単一共有イメージ `localhost/claude-container_claude-auth-workspace` も同じ命名パターンで検出されるため、旧バージョンからの移行時は `--clean` の実行だけで回収できる）。
- **`compose.yml`** — サービス `claude-auth-workspace` を定義。ビルドコンテキストは `${BUILD_CONTEXT_DIR}`（上記でステージングされたディレクトリ）、Dockerfile は `${CLAUDE_CONTAINER_DIR}/Dockerfile.claude` を参照する。ホストの `~/.claude.json` と `~/.claude/`（認証・設定）、対象ワークスペース（`/workspace`）、`/etc/localtime`（タイムゾーン）をマウントする。`userns_mode: keep-id` でコンテナ内ファイルのオーナーをホストユーザーに合わせる。`cap_add` で `NET_ADMIN`/`NET_RAW` を付与し、`init-firewall.sh` がコンテナのネットワーク名前空間に iptables ルールを設定できるようにする。`sysctls` で `net.ipv6.conf.{all,default}.disable_ipv6=1` を設定し、IPv6 をカーネルレベルで無効化する（後述）。
- **`Dockerfile.claude`** — `debian:stable` をベースにビルド。`ca-certificates` を HTTP でインストール後、apt ソースを HTTPS に書き換えてから残りのパッケージを取得する。Claude Code は公式 native installer（`curl -fsSL https://claude.ai/install.sh | bash`）でインストール。非 root ユーザー `node`（UID 1000、明示的に作成）で動作し、`CMD ["/home/node/entrypoint.sh"]`（次項参照）を実行する。`node:24`（約 1.1 GB）から切り替えた理由: native installer は glibc のみ依存で実行時に Node.js を必要としないため、軽量な Debian ベースで十分。slim ではなく full 版を使う理由: full 版には `ca-certificates` 等の基本パッケージが含まれており apt 周りの初期設定が最小限で済む。`ENTRYPOINT ["/usr/bin/tini", "--"]` で `tini` を PID1 に据える。claude 自身が PID1 だと、PID1 に再親付けされた子プロセス（ファイアウォール更新ループの sudo 補助プロセス等）が reap されずゾンビとして蓄積し、さらに claude が終了時にハングした場合（2026-07-02 に実障害: ホストカーネルの workqueue Oops により kill 不能な D 状態スレッドが残存）は PID1 自体が reap 不能なゾンビとなり、crun がシグナルを配送できず（`crun kill ... failed` / "No such process"）`podman stop` でもコンテナを回収できなくなる。tini を PID1 に置くことで reap と `podman stop` が機能し続ける（カーネル側のハング自体は tini でも防げない）。`tini` は `packages.txt` に入れず Dockerfile 固定のパッケージ行に含める — プロジェクト側 `.claude-container.d/packages.txt` で上書きされて消えるのを防ぐため。
- **`entrypoint.sh`** — コンテナの `CMD`（PID1 は上記 tini、このスクリプトと `exec` 先の claude はその子として動く）。起動時に `init-firewall.sh` でエグレス制限を適用し（失敗時は起動を中断）、バックグラウンドでドメイン再解決ループ（約15秒間隔、次項参照）を開始したうえで `claude --dangerously-skip-permissions` を起動する。あわせて `~/.claude/plugins/` 内に残るホスト側のパスをコンテナ内パスへ自動修正する。
- **`init-firewall.sh`** — コンテナ起動時に root（sudo）で実行されるエグレス制限スクリプト。Anthropic 公式 devcontainer の同名スクリプトの移植で、iptables により「許可したドメイン以外への外向き通信を遮断」する（deny-by-default）。Claude Code に必要なエンドポイント（api.anthropic.com・GitHub 等）とプロジェクト指定の `allowed-domains.txt` のみ許可する。GitHub IP レンジは起動時にライブ取得せず、ビルド時に焼き込まれたスナップショットを読み込むだけ（詳細は下記「GitHub meta スナップショット」参照）。設定後に example.com へ到達**できない**こと・api.github.com / api.anthropic.com へ到達**できる**ことを自己検証する（GitHub 側は API クォータを消費しない TCP 接続確認）。失敗時はコンテナを起動しない（fail-closed）。ただし、許可ドメイン（`allowed-domains.txt` 指定分を含む）が恒久的に存在しない場合（NXDOMAIN）は警告に留め起動を継続する（一時的な解決失敗は従来どおり fail-closed）。IPv6 は `compose.yml` の `sysctls` で無効化するのが主対策だが、それが効かない環境向けに本スクリプト自身も `/proc/sys/net/ipv6/conf/*/disable_ipv6` への書き込みをフォールバックとして試みる（失敗しても警告のみで起動は継続する）。いずれの結果にかかわらず、既存の `ip6tables` による IPv6 全遮断（許可リストが A レコードのみのため）は最終防衛線として維持する。許可ドメインの IP は `entrypoint.sh` が起動するバックグラウンドループにより約15秒間隔で再解決され（`init-firewall.sh --refresh-domains`）、新しい IP を差分追加・約3分間見つからない IP を個別削除することで、CDN の短い TTL による IP ローテーションに追従する（チェーン全体のフラッシュは行わないため、更新中に新規接続が失敗する窓は作らない）。
- **`packages.txt`** / **`requirements.txt`** / **`allowed-domains.txt`** — claude-container 同梱のデフォルト apt/pip パッケージ・許可ドメイン一覧（フォールバック既定値）。プロジェクト側で上書きする場合は `.claude-container.d/` を使う（「利用側プロジェクトの設定」参照）。`node-version.txt` にはこの種の同梱デフォルトは無く、プロジェクト側に無ければ `claude-container` がビルドコンテキスト内に空ファイルをその場で生成する（Node.js 未導入という意味で、警告も出さない）。

#### GitHub meta スナップショット

`init-firewall.sh` の許可リストが使う GitHub IP レンジは `https://api.github.com/meta` から取得する。未認証 GitHub API のレート制限（60 req/h/IP）を避けるため、取得は `claude-container` のビルドコンテキスト準備時（`-b` のたび最大1リクエスト）に1箇所だけで行い、`Dockerfile.claude` がその結果をイメージへ焼き込む。コンテナ起動のたびのライブ取得は行わないため、何度再起動してもレート制限は消費しない。取得に失敗した場合は (1) このプロジェクトの前回ステージング分（`.build-context/<PROJECT_NAME>/` に残っている）、(2) それも無ければ他プロジェクトの最新スナップショット（GitHub の IP レンジは変更頻度が低いため実用上問題ない）を警告付きで再利用し、いずれも無い場合のみビルドを中断する。

### イメージの変更

`Dockerfile.claude` を編集して `./claude-container -b /path/to/project` でリビルドする。`-b` を付けると GitHub meta スナップショットの再取得（上記）が試みられ、あわせて `CACHEBUST` にその時点のエポック秒が渡されて install レイヤーのキャッシュが必ず破棄される。これにより、`-b` のたびに `install.sh` が再実行されて最新版の Claude Code が取得される（apt パッケージ等の上位レイヤーはキャッシュを流用するため高速）。再現性が必要な場合は `compose.yml` で `CLAUDE_CODE_VERSION` を固定する。

`.claude-container.d/` のパッケージ一覧・許可ドメイン（`allowed-domains.txt`）・Node バージョン指定（`node-version.txt`）を変更した場合も、イメージへ反映するには `-b` での再ビルドが必要。

`.build-context/` は claude-container リポジトリ直下に生成されるビルドコンテキストの生成物（`.gitignore` 対象）で、プロジェクトごとに `.build-context/<PROJECT_NAME>/` のサブディレクトリへ分離される。`./claude-container --clean /path/to/project` でそのプロジェクト分のみ、`./claude-container --clean`（引数なし）で全プロジェクト分をまとめて削除できる。

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

ネットワークは既定で `init-firewall.sh` によるエグレス許可リストで制限される。Claude Code に必要なエンドポイント（Anthropic API・GitHub 等）と `.claude-container.d/allowed-domains.txt` で指定したドメイン以外への外向き通信は遮断されるため、悪意ある pip パッケージやプロンプトインジェクションが認証情報（`~/.claude.json`）やソースコードを任意の外部ホストへ送信することを防ぐ。開放が必要な場合は `.claude-container.d/env` に `CLAUDE_CONTAINER_NO_FIREWALL=1` を書いて無効化できる（自己責任）。

**制限しても残るリスク**: DNS クエリを使ったトンネリング、許可済みサービス（GitHub 等）自体への送信、CDN の共有 IP 経由の到達は原理上防げない。許可ドメインの IP は約15秒間隔のバックグラウンド再解決で追従するが（上記アーキテクチャ節参照）、ローテーション直後からリフレッシュが反映されるまでの数十秒間は新規接続が失敗しうる（コンテナ再起動が必要だった以前と比べれば大幅に縮小されるが、ゼロにはできない）。GitHub IP レンジはビルド時スナップショット固定のため、コンテナ再起動では更新されず `-b` でのリビルドが必要。ビルド時（`pip3 install` 等）のネットワークは制限されない。

`GH_TOKEN_FILE`（前述）を設定した場合、上記「許可済みサービス自体への送信」というリスクが受動的なものから能動的なものに変わる: プロンプトインジェクションや悪意あるパッケージがコンテナ内からトークンを読み取り、そのスコープ内で GitHub に書き込める（対象リポジトリへの意図しない issue 作成・改変、issue 本文を経由した情報送信）。ファイアウォールは GitHub 自体への通信を許可しているため、これを防げない。緩和策は fine-grained PAT のスコープ最小化（Issues のみ・対象リポジトリ限定・短期限）で、被害を「その1リポジトリの issue 操作」に構造的に限定すること。

### Podman 固有の注意

- `userns_mode: keep-id` はホストユーザーの UID/GID をコンテナ内にマップする Podman 固有の機能。Docker に移植する場合は削除する。
- `--in-pod false` は Podman Compose がデフォルトでサービスを Pod にラップする挙動を抑制する。Docker Compose はこのフラグを無視する。

### 変更後の確認

テストスイートはない。スクリプトや Compose / Dockerfile を編集した後は以下で確認する。

```bash
./lint.sh
```

`lint.sh` は、リポジトリ内の bash スクリプト（gitignore 対象を除く追跡済み・未追跡ファイルから shebang で自動判定するため、スクリプトを追加・削除しても対象リストの更新は不要）への `bash -n` と `shellcheck`、および `podman compose -f compose.yml config` をまとめて実行する。shellcheck 未インストール時はエラーで失敗する（`sudo apt-get install shellcheck` で導入）。podman が無い環境（コンテナ内での開発時）では Compose 検証のみ警告付きでスキップされる。

### バージョニング

[Semantic Versioning](https://semver.org/lang/ja/) に従い、リリースは annotated git タグ（`vX.Y.Z`）で管理し、タグごとに `gh release create <tag> --notes-from-tag` でタグメッセージをそのまま流用した GitHub Release を作成する（CHANGELOG ファイルは作らない）。番号は利用者から見えるインターフェース（CLI 引数・`.claude-container.d/` の設定形式・デフォルト挙動）を基準に判定する:

- **MAJOR** — 後方互換性が壊れる変更（デフォルト挙動の変更、設定形式の削除・非互換化など、利用者が対応しないと従来どおり動かないもの）
- **MINOR** — 後方互換な機能追加（既存の使い方はそのまま動く）
- **PATCH** — 後方互換なバグ修正のみ

バージョン履歴は GitHub の [Releases ページ](https://github.com/jj1xgo/claude-container/releases)で一覧・購読できる（`git tag -n1` でも確認可能）。

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

# Remove that project's image, network, and build context, then exit
./claude-container --clean /path/to/project

# Remove all projects' images, networks, and build contexts, then exit
./claude-container --clean
```

The script works via symlink — it resolves its own path using `readlink`. Launching or rebuilding different target projects, even interleaved, no longer overwrites each other's image or build context (see "Architecture" below). Multiple projects can also be run concurrently.

### Environment Variables

Place a `.claude-container.d/env` file at the root of the **target project** to have it read automatically before launch. Only `KEY=VALUE` lines are honored (no quoting or shell expansion — the file is deliberately NOT `source`d, so a target project cannot execute code on the host). This is a runtime setting re-read on every launch, not something baked into the image, so changing it never requires a `-b` rebuild.

| Variable | Default | Description |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | `~` | Directory containing `.claude.json` and `.claude/` |
| `EXTRA_MOUNT` | `/dev/null` | Additional host path to mount at `/data` inside the container |
| `TZ` | Auto-detected from host | Timezone inside the container |
| `CLAUDE_CONTAINER_NO_FIREWALL` | (unset) | Set to `1` to disable the egress firewall (see below) |
| `GH_TOKEN_FILE` | (unset) | Absolute path on the host to a file holding a GitHub Issues write token (see below) |
| `GITCONFIG_FILE` | (unset) | Path on the host to a git config file to mount read-only as `~/.gitconfig` inside the container (see below) |

`TZ` is auto-detected from the host's `/etc/timezone` (or `/etc/localtime` symlink). An explicit value in `.claude-container.d/env` takes precedence.

If you self-host claude-container against itself (passing this repo directly as the argument to `./claude-container`), copy `.claude-container.d/env.example` to `.claude-container.d/env`. It may contain host-specific paths (e.g. `GH_TOKEN_FILE`), so `.claude-container.d/env` is gitignored and only the example is committed.

### Target Project Configuration

Bash history is saved to `.claude/bash_history` in the target project. To avoid accidentally committing it, add the following to the target project's `.gitignore`:

```
.claude/bash_history
```

Target-project-specific claude-container configuration lives entirely under `.claude-container.d/`. Files there fall into two categories: runtime settings (re-read on every launch) and build-time settings (baked into the image).

```
.claude-container.d/env                  # runtime settings (KEY=VALUE, see "Environment Variables" above); no -b needed, gitignored
.claude-container.d/packages.txt         # apt packages, one per line; lines starting with # are comments; requires -b, committed
.claude-container.d/requirements.txt     # pip packages, passed directly to pip3 install -r; requires -b, committed
.claude-container.d/allowed-domains.txt  # extra domains for the egress firewall, one per line; # for comments; requires -b, committed
.claude-container.d/node-version.txt     # Node.js version to install (e.g. 22.14.0, single line); requires -b, committed
```

All except `env` are optional. If `packages.txt`/`requirements.txt`/`allowed-domains.txt` are absent, claude-container's bundled defaults (empty fallbacks) are used. `allowed-domains.txt` lists extra domains the project needs (e.g. for pip: both `pypi.org` and `files.pythonhosted.org` — the latter serves the actual package downloads, so reaching the index alone isn't enough for `pip install` to succeed). These three are baked into the image at build time, so changing them requires a `-b` rebuild (`env` is deliberately excluded from this baking — it may hold host-specific paths that must never end up in the image).

`node-version.txt` is for Node.js versions apt can't provide on debian:stable (e.g. 22.x — trixie ships 20.x, testing skips straight to 24.x). It fetches the official Linux tarball from nodejs.org and verifies it against nodejs.org's own `SHASUMS256.txt` before extracting. **Build-time network is unrestricted, so no `allowed-domains.txt` entry for `nodejs.org` is needed** (the `init-firewall.sh` egress restriction only applies at runtime). If absent, no Node.js is installed — and unlike the other three files, no WARNING fires in this case (it's a new opt-in feature; not having it is the normal state for most projects).

**Writing to GitHub Issues (`GH_TOKEN_FILE`)**: To let the container write to GitHub Issues via the `gh` CLI (e.g. for a cross-project communication channel), wire up a token as follows.

**Important**: "where you place `.claude-container.d/env`" and "which repository you select under the PAT's `Repository access`" are two different things. The former is the project that **uses** the token (e.g. findsummits); the latter is the repository you're **writing issues to** (e.g. claude-container). To let findsummits write issues to claude-container, place `.claude-container.d/env` inside findsummits and select `claude-container` under `Repository access` — not the project that's doing the writing.

1. Create a token under GitHub Settings → Developer settings → Personal access tokens → Fine-grained tokens. **Do not use a classic PAT** — even its narrowest write scope (`repo`) grants read/write on all your repositories, which is too much blast radius for a leaked token. Configure it as:
   - Repository access: `Only select repositories` → the communication repo only
   - Repository permissions: `Issues: Read and write` only (do not grant `Contents`, `Pull requests`, etc.)
   - Expiration: 90 days or less recommended
2. Save the token string in a file outside the committed project tree, separate from `.claude-container.d/env` (e.g. `~/.config/claude-container/<project>-gh-token`). `chmod 600` it.
3. In the target project's `.claude-container.d/env`, set `GH_TOKEN_FILE` to that file's **path**, not the token itself: `GH_TOKEN_FILE=~/.config/claude-container/<project>-gh-token`. `.claude-container.d/env` is gitignored (it may hold host-specific paths), so it's never committed in the first place.
4. Startup aborts (fail-closed) if the file doesn't exist or isn't a regular file; a warning is printed if its permissions aren't `600`.

The token is only ever a file on the host — it's never passed via the container's `environment:` (so it doesn't show up in `podman inspect`, etc.). At startup, `entrypoint.sh` reads the file's contents and exports it as `GH_TOKEN`, which the `gh` CLI picks up automatically.

**Rotating the token**: When it's nearing expiration, regenerate it on GitHub's side and overwrite the contents of the file `GH_TOKEN_FILE` points to (e.g. `~/.config/claude-container/<project>-gh-token`) with the new string. `GH_TOKEN_FILE` is a runtime mount, not something baked in at build time, so no rebuild (`-b`) is needed — `entrypoint.sh` picks up the new contents on the next launch.

**Note**: the startup check only verifies the file exists and its permissions — it does not validate whether the token itself has expired. A container with an expired token still starts normally; the failure only surfaces the first time `gh` actually calls the GitHub API. Keep track of the `Expiration` you set so this doesn't go unnoticed.

**Committing from inside the container (`GITCONFIG_FILE`)**: Even if you've set `git config --global user.name`/`user.email` on the host, it isn't reflected inside the container by default, so `git commit` fails with `Author identity unknown`. Fix it by adding this to `.claude-container.d/env`:

```
GITCONFIG_FILE=~/.gitconfig
```

- If unset, behavior is unchanged (`git commit` just fails with `Author identity unknown`; nothing else is affected)
- If set, startup aborts with an error if the file doesn't exist (fail-closed) — this avoids a bind-mount quirk where a nonexistent source path gets silently created as an empty directory on the host
- The mount is read-only, so `git config --global` cannot be used to edit it from inside the container. Always edit it on the host (it's a runtime mount, so no `-b` rebuild is needed — the next launch picks up the change)
- A `credential.helper` or `include.path` entry pointing at a host-specific file doesn't affect `git commit` itself (a missing include is silently ignored, and a missing credential helper only warns during authenticated operations). If that's a concern, point `GITCONFIG_FILE` at a dedicated file containing only `user.name`/`user.email` instead
- If `GITCONFIG_FILE` doesn't seem to take effect, check whether `/workspace` (the target project you launched) has its own `.git/config` with `user.name`/`user.email` set. Git's config precedence (local > global) means the target project's local setting wins over the mounted `~/.gitconfig` (which acts as the global config)

**Always create language-runtime artifacts like venvs inside the container, not on the host.** Running `python3 -m venv` on the host inside the target project directory bakes the host's absolute path and username into the generated scripts' shebangs (e.g. `venv/bin/pip`'s first line becomes `/home/alice/myproject/venv/bin/python3`). Since the same directory is mounted inside the container at `/workspace` under the `node` user, that path doesn't resolve and shebang-based execution (`./venv/bin/djlint`, etc.) fails (invoke the venv's own python3 as a module instead, e.g. `venv/bin/python3 -m djlint` — plain `python3` is the system interpreter and won't see the venv's site-packages). Create the venv from inside a running container instead.

### Architecture

The main files work together:

- **`claude-container`** (bash) — Entry point. Resolves absolute paths, then computes `PROJECT_NAME` from the target project's directory basename (sanitized) plus the first 8 characters of a sha256 hash of its absolute path (e.g. `findsummits-3f2a9c1b`). This separates the image name (`localhost/<PROJECT_NAME>_claude-auth-workspace`) and the staged build context (`.build-context/<PROJECT_NAME>/`) per project, and `-p "$PROJECT_NAME"` is passed to `podman compose` accordingly. Previously the image name and staging path were fixed regardless of the target project, so interleaving builds across different projects would silently overwrite each other's image and staged context. Reads `KEY=VALUE` lines from `.claude-container.d/env` with a safe parser (no `source`), auto-detects `TZ`, sets `CONTEXT` / `CLAUDE_CONTAINER_DIR`, and delegates to `podman compose run`. When `-b` is passed, `podman compose build` runs as a separate step before `run` — `run --build` would fall back to the existing stale image when the build fails (fail-open), whereas the separate build step aborts the launch on failure (fail-closed). Before building, it stages `entrypoint.sh`, `init-firewall.sh`, the GitHub meta snapshot (see below), plus the project's `.claude-container.d/packages.txt` / `requirements.txt` / `allowed-domains.txt` (or claude-container's bundled defaults if absent) and `node-version.txt` (an empty file is synthesized on the fly if absent — unlike the other three, it has no bundled default and never warns) into that project's `BUILD_CONTEXT_DIR` (only when `-b` is passed, or when the image hasn't been built yet). `--clean <directory>` removes only that project's image, network, and build context; `--clean` (no directory) scans for all existing claude-container images and removes every project's worth (the legacy shared image `localhost/claude-container_claude-auth-workspace` matches the same naming pattern, so upgrading from an older version just requires running `--clean` once to reclaim it).
- **`compose.yml`** — Defines the `claude-auth-workspace` service. The build context is `${BUILD_CONTEXT_DIR}` (the staged directory above); the Dockerfile is `${CLAUDE_CONTAINER_DIR}/Dockerfile.claude`. Mounts `~/.claude.json`, `~/.claude/`, the target workspace (`/workspace`), and `/etc/localtime`. Uses `userns_mode: keep-id` to match the host user's UID/GID. Adds `NET_ADMIN`/`NET_RAW` capabilities via `cap_add` so `init-firewall.sh` can configure iptables rules inside the container's network namespace. Sets `net.ipv6.conf.{all,default}.disable_ipv6=1` via `sysctls` to disable IPv6 at the kernel level (see below).
- **`Dockerfile.claude`** — Based on `debian:stable`. Installs `ca-certificates` via HTTP first, then rewrites apt sources to HTTPS before installing remaining packages. Claude Code is installed via the official native installer (`curl -fsSL https://claude.ai/install.sh | bash`). Runs as the non-root `node` user (UID 1000, created explicitly), executing `CMD ["/home/node/entrypoint.sh"]` (see next item). Switched from `node:24` (~1.1 GB) because the native installer only requires glibc — no runtime Node.js needed. Full (not slim) Debian is used to avoid extra setup steps that slim requires. `ENTRYPOINT ["/usr/bin/tini", "--"]` puts `tini` at PID1: with claude itself as PID1, children reparented to PID1 (e.g. the firewall refresh loop's sudo helpers) were never reaped and accumulated as zombies, and when claude wedged on exit (2026-07-02: a host-kernel workqueue Oops left an unkillable D-state thread), the zombie PID1 could not be signalled at all (`crun kill ... failed` / "No such process") and `podman stop` could not reclaim the container. tini keeps reaping and `podman stop` working (it cannot fix a kernel-side wedge itself). `tini` is kept out of `packages.txt` and installed in the fixed apt layer instead, so a project's `.claude-container.d/packages.txt` can't silently drop it.
- **`entrypoint.sh`** — The container's `CMD` (PID1 is the `tini` above; this script and the claude process it execs into run as its child). Applies the egress firewall via `init-firewall.sh` at startup (aborts launch on failure), starts a background domain re-resolution loop (~15s interval, see next item), then launches `claude --dangerously-skip-permissions`. Also auto-fixes host-specific paths under `~/.claude/plugins/` to their in-container equivalents.
- **`init-firewall.sh`** — Egress firewall script run as root (via sudo) at container startup. A port of the same-named script from Anthropic's official devcontainer: it blocks all outbound traffic except allowed destinations (deny-by-default iptables rules). Only the endpoints Claude Code needs (api.anthropic.com, GitHub, etc.) and the project's `allowed-domains.txt` are allowed. GitHub IP ranges are never fetched live at startup — only the build-time snapshot is read (see "GitHub Meta Snapshot" below). After setup it self-verifies that example.com is **unreachable** and api.github.com / api.anthropic.com **are** reachable (the GitHub check is a quota-free TCP connect), and refuses to start the container on failure (fail-closed). The one exception: if an allowed domain (including one from `allowed-domains.txt`) no longer exists at all (NXDOMAIN), that's logged as a warning and startup proceeds — only transient resolution failures still trip fail-closed. IPv6 is primarily disabled via `compose.yml`'s `sysctls`; as a fallback for environments where that doesn't take effect, this script also attempts to write `/proc/sys/net/ipv6/conf/*/disable_ipv6` itself (non-fatal if it fails — logs a warning and continues). Either way, the existing `ip6tables` IPv6 blackhole (the allowlist only resolves A records) remains the last line of defense. Allowed domains' IPs are re-resolved roughly every 15s by a background loop `entrypoint.sh` starts (`init-firewall.sh --refresh-domains`), which diff-adds newly seen IPs and individually removes ones unseen for about 3 minutes — this keeps up with CDNs that rotate IPs on short TTLs, without ever flushing the whole chain (so no gap where new connections fail during a refresh).
- **`packages.txt`** / **`requirements.txt`** / **`allowed-domains.txt`** — claude-container's bundled default apt/pip package and allowed-domain lists (fallback values). Projects override these via `.claude-container.d/` (see "Target Project Configuration" above). `node-version.txt` has no such bundled default — if the project doesn't provide one, `claude-container` synthesizes an empty file in the build context on the fly (meaning "no Node.js install", with no warning).

#### GitHub Meta Snapshot

The GitHub IP ranges used by `init-firewall.sh`'s allowlist come from `https://api.github.com/meta`. To avoid the unauthenticated GitHub API rate limit (60 req/h/IP), the fetch happens in exactly one place — while `claude-container` stages the build context (at most one request per `-b`) — and `Dockerfile.claude` bakes the result into the image. There's no live fetch on container startup, so restarting the container never consumes the rate limit. If the fetch fails, (1) this project's previously staged snapshot (still in `.build-context/<PROJECT_NAME>/`) is reused with a warning, or (2) failing that, another project's most recent snapshot is reused with a warning (GitHub's IP ranges change infrequently enough that this is fine in practice); the build only aborts if neither exists.

### Modifying the Image

Edit `Dockerfile.claude` and rebuild with `./claude-container -b /path/to/project`. The `-b` flag re-fetches the GitHub meta snapshot (see above) and passes a `CACHEBUST` build arg (current epoch seconds) that busts the install-layer cache on every run, so `install.sh` always re-executes and fetches the latest Claude Code. Layers above the install step (apt packages etc.) are still served from cache, keeping rebuilds fast. Pin `CLAUDE_CODE_VERSION` in `compose.yml` if reproducibility matters.

Changes to the package lists, allowed domains (`allowed-domains.txt`), or Node.js version (`node-version.txt`) under `.claude-container.d/` also require a `-b` rebuild to take effect.

`.build-context/` is a generated build context under the claude-container repo (git-ignored), split into a `.build-context/<PROJECT_NAME>/` subdirectory per project. `./claude-container --clean /path/to/project` removes just that project's; `./claude-container --clean` (no directory) removes all of them.

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

Network access is restricted by default via the `init-firewall.sh` egress allowlist. Outbound traffic to anything other than the endpoints Claude Code needs (Anthropic API, GitHub, etc.) and the domains listed in `.claude-container.d/allowed-domains.txt` is blocked, preventing malicious pip packages or prompt injection from exfiltrating credentials (`~/.claude.json`) or source code to arbitrary hosts. If you need unrestricted network access, set `CLAUDE_CONTAINER_NO_FIREWALL=1` in `.claude-container.d/env` (at your own risk).

**Residual risks the allowlist cannot prevent**: tunneling over DNS queries, exfiltration to allowed services themselves (e.g. GitHub), and reachability of other sites behind shared CDN IPs. Allowed domains' IPs keep up with rotation via the ~15s background refresh (see Architecture above), but the tens of seconds between a rotation and the next refresh cycle can still see new-connection failures (a large improvement over needing a container restart, but not zero). GitHub IP ranges are fixed at build time, so a container restart does not refresh them — a `-b` rebuild is required instead. Build-time network access (`pip3 install` etc.) is not restricted.

If `GH_TOKEN_FILE` (above) is set, the "exfiltration to allowed services themselves" risk above stops being passive: prompt injection or a malicious package running in the container can read the token and write to GitHub within its scope (unintended issue creation/edits on the target repo, or using an issue body as an exfiltration channel). The firewall cannot prevent this since GitHub itself is an allowed destination. The mitigation is scoping the fine-grained PAT down (Issues only, single repository, short expiration), which structurally limits the blast radius to issue operations on that one repository.

### Podman-specific Notes

- `userns_mode: keep-id` maps the host user's UID/GID into the container. This is a Podman feature — remove it if adapting for Docker.
- `--in-pod false` prevents Podman Compose from wrapping the service in a Pod (default Podman Compose behavior). Docker Compose ignores this flag.

### Verifying Changes

There is no test suite. After editing the script or Compose/Dockerfile, verify with:

```bash
./lint.sh
```

`lint.sh` runs `bash -n` and `shellcheck` on every bash script in the repository (tracked and untracked files minus gitignored ones, detected by shebang, so the target list needs no maintenance when scripts are added or removed), plus `podman compose -f compose.yml config`. It fails with an explicit error if shellcheck is not installed (`sudo apt-get install shellcheck`). When podman is unavailable (e.g. developing inside the container), only the Compose validation is skipped with a warning.

### Versioning

Releases follow [Semantic Versioning](https://semver.org/) and are managed with annotated git tags (`vX.Y.Z`); each tag gets a GitHub Release created with `gh release create <tag> --notes-from-tag`, reusing the tag message verbatim (no separate CHANGELOG file). Version numbers are judged against the user-visible interface (CLI arguments, the `.claude-container.d/` configuration format, and default behavior):

- **MAJOR** — backward-incompatible changes (changed defaults, removed or incompatible configuration formats — anything that breaks existing usage until the user adapts)
- **MINOR** — backward-compatible feature additions (existing usage keeps working)
- **PATCH** — backward-compatible bug fixes only

Browse the version history on the [GitHub Releases page](https://github.com/jj1xgo/claude-container/releases) (list and subscribe), or with `git tag -n1`.

### References

- [Running Claude Code CLI in a Container (Endpoint Dev Blog)](https://www.endpointdev.com/blog/2026/03/claude-code-cli-in-container/) — Container setup guide by Seth Jensen, the original fork author

### License

GPL-3.0. The original fork ([sethjensen1/claude-container](https://github.com/sethjensen1/claude-container)) is MIT-licensed. See [LICENSE](LICENSE) for details.
