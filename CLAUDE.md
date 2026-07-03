# CLAUDE.md

## プロジェクト概要

[findsummits](https://github.com/JJ1XGO/findsummits) プロジェクト向けの Claude Code サンドボックス環境。
[sethjensen1/claude-container](https://github.com/sethjensen1/claude-container)（MIT）をフォークし、findsummits の開発環境に合わせてカスタマイズしたもの。apt/pip パッケージは `.claude-container.d/` で利用側プロジェクトごとに指定でき、本リポジトリ自体は特定プロジェクトに依存しない。

## 使い方

```bash
./claude-container /path/to/project
```

コマンドの全リファレンス（`-b` によるリビルド、`--clean`、シンボリックリンク対応）は README.md の「使い方」節を参照。

## 環境変数

対象プロジェクトのルートに置いた `.claude-container.d/env` ファイル（`KEY=VALUE` 形式の行）で設定し、起動前に自動で読み込まれる。値は最初の `=` 以降を文字どおりに扱う — クォート・展開・コマンド実行は一切解釈されない。このファイルは意図的に `source` しないため、悪意あるターゲットプロジェクトがホスト上でコードを実行することはできない。

変数一覧とデフォルト値は README.md の「環境変数」節を参照。

## アーキテクチャ

> **前提**: 本節以降の `/home/node/` 等のパスや `sudo` コマンドは、`./claude-container` 経由で実際に起動した**コンテナ内部**の事実を説明したものである。このリポジトリのソースをコンテナを介さずホスト上で直接編集している場合、これらのパス・コマンドは実在しない（ビルド対象の仕様として読むこと）。

主要ファイルが連携して動作する:

- **`claude-container`**（bash）— エントリーポイント。絶対パスを解決したうえで、`compute_project_name()` によりターゲットプロジェクトのディレクトリ名（basename、サニタイズ済み）と絶対パスの sha256 先頭8文字を組み合わせて `PROJECT_NAME` を算出する（例: `findsummits-3f2a9c1b`）。これによりイメージ名（`localhost/<PROJECT_NAME>_claude-auth-workspace`）とステージングされたビルドコンテキスト（`.build-context/<PROJECT_NAME>/`）をプロジェクトごとに分離し、すべての `podman compose` 呼び出しに `-p "$PROJECT_NAME"` を渡す — これが無いと、異なるターゲットプロジェクトのビルドを交互に行った際に互いのイメージとステージング済みコンテキストが無言で上書きされてしまう（実インシデント、2026-07-02）。ターゲットプロジェクトの `.claude-container.d/env` から `KEY=VALUE` 行を読み込み（安全なパース、`source` はしない）、`CONTEXT` と `CLAUDE_CONTAINER_DIR` を設定して `podman compose run` に処理を委譲する。`-b` が渡された場合は `CACHEBUST` に現在のエポック秒を設定して install レイヤーが必ずリビルドされるようにし、`podman compose build` を `run` とは別ステップとして実行する — `run --build` はビルド失敗時に既存の古いイメージへフォールバックしてしまう（fail-open）のに対し、別ステップにすることで失敗時は起動を中断する（fail-closed）。ビルド前（`-b` 指定時、またはイメージが未ビルドの場合）に、`entrypoint.sh` と `init-firewall.sh`、およびターゲットプロジェクトの `.claude-container.d/packages.txt` / `requirements.txt` / `allowed-domains.txt`（プロジェクトが提供しない場合は claude-container 同梱のコピーにフォールバック）を、そのプロジェクト専用の `BUILD_CONTEXT_DIR` にステージングする。同じ `.claude-container.d/` 配下でもランタイム設定の `env`（ホスト固有パスを含みうる）はこのステージング対象に意図的に含めない — ビルド時にイメージへ焼き込んではならないため。将来このステージング処理がワイルドカードコピーへ書き換えられて `env` が紛れ込むリグレッションを防ぐため、`stage_build_context()` は `env` がステージング先に存在したら即座に `exit 1` する防御的アサーションを持つ。プロジェクトごとに固定パスを使う（`mktemp -d` は使わない）ことで、ビルドキャッシュを安定させ、クリーンアップ用の trap も不要にしている。`stage_build_context()` はここで GitHub meta スナップショットの取得も行う（詳細は下記「GitHub meta スナップショット」参照）。`--clean <directory>` はそのプロジェクト分のイメージ・ネットワーク・ビルドコンテキストのみを削除する。ディレクトリ指定なしの `--clean`（`clean_all()`）は、存在する `localhost/*_claude-auth-workspace` イメージすべてを走査し、移行前のレガシー共有イメージ `localhost/claude-container_claude-auth-workspace` も含めてすべて削除する。
- **`compose.yml`** — サービス `claude-auth-workspace` を1つだけ定義する。`build.context` は `${BUILD_CONTEXT_DIR}`（上記でステージングされたディレクトリ）、`build.dockerfile` は `${CLAUDE_CONTAINER_DIR}/Dockerfile.claude` — Dockerfile はビルドコンテキストの外に置けるため、`Dockerfile.claude` 自体はステージングせず claude-container リポジトリから直接読み込む。ホストの `~/.claude.json` と `~/.claude/`（認証＋設定）、対象ワークスペース（`/workspace`）、`/etc/localtime`（読み取り専用、ホストのタイムゾーン用）をマウントする。`userns_mode: keep-id` により、コンテナ内のファイルがホストユーザーと同じ UID を持つようにする。`init-firewall.sh` がコンテナのネットワーク名前空間に iptables ルールを設定できるよう `NET_ADMIN`/`NET_RAW` の capability を追加する。`-b` 時のキャッシュ破棄を有効にするため `CACHEBUST` をビルド引数として渡す。`sysctls` で `net.ipv6.conf.{all,default}.disable_ipv6=1` を設定する — podman のデフォルトブリッジネットワークには IPv6 のグローバルルートが無い（リンクローカルの `fe80::` のみ）が、glibc の `getaddrinfo(AI_ADDRCONFIG)` はそれでも IPv6 が利用可能と報告し AAAA レコードを返すため、curl/requests の Happy Eyeballs が許可リスト対象の CDN 系ドメインへの到達不能な IPv6 候補を試みて間欠的に停止することがある。これが主対策であり、`init-firewall.sh` の `ip6tables` DROP（後述）は変わらずセキュリティ境界として機能する。
- **`Dockerfile.claude`** — `debian:stable`（現在は trixie）をベースにビルドし、Claude Code の依存パッケージとステージングされた `packages.txt`/`requirements.txt`（前述）をインストールしたうえで、公式 native installer（`curl -fsSL https://claude.ai/install.sh | bash`）で Claude Code をインストールする。`claude-container` がステージングした `github-meta.json` も `COPY` して `jq` で検証する — このレイヤーではネットワーク呼び出しが発生しないため、Docker の content-hash キャッシュが自然に効く（詳細は下記「GitHub meta スナップショット」参照）。install の `RUN` 直前に `ARG CACHEBUST` を宣言しており、`-b` 使用時は install レイヤー（以降のすべて）が必ずキャッシュを使わず再実行される。非 root の `node` ユーザー（UID 1000、明示的に作成）で動作し、`CMD ["/home/node/entrypoint.sh"]`（ファイアウォールを適用したのち `claude --dangerously-skip-permissions` を exec する）を実行する。`ENTRYPOINT ["/usr/bin/tini", "--"]` により `tini` を PID1 に据え、entrypoint.sh とそれが exec する claude プロセスをその子として動かす。init プロセスが無いと claude 自身が PID1 になり、PID1 に再親付けされた子プロセス（ファイアウォール更新ループの sudo 補助プロセス）を reap できずゾンビとして蓄積し（15秒サイクルごとに約1個、実インシデント 2026-07-02）、さらに claude が終了時にハングした場合（同日: ホストカーネルの workqueue Oops により kill 不能な D 状態スレッドが残り、PID1 が reap 不能なゾンビになった）、crun は PID1 に一切シグナルを送れなくなる — ホスト側で `crun kill ... failed: exit status 1` / "No such process"、`podman stop` が完了できず、コンテナが "Stopping" のまま固着する。tini を PID1 に据えることで PID1 が生存しシグナル送信可能な状態を保ち、reap と `podman stop` が機能し続ける（カーネル側の D 状態ハング自体は tini でも解消できない）。`tini` は `packages.txt` ではなく固定の apt-get レイヤーにインストールする — プロジェクト側の `packages.txt` によって黙って落とされないようにするため（`sudo`/`iptables` と同じ理由）。`debian:stable` を採用した理由: native installer の Claude Code バイナリは glibc のみ依存で Node.js を実行時に必要とせず、Node.js 同梱の `node:24` より軽量な Debian ベースで足りるため。注意: `ca-certificates` は debian:stable にも**同梱されていない**ため、HTTP で先行インストールしてから apt sources を HTTPS に書き換える（Dockerfile 冒頭が2段構成なのはこのため。削除しないこと）。
- **`entrypoint.sh`** — コンテナ起動時に実行されるシェルスクリプト。まず `sudo /usr/local/bin/init-firewall.sh` でエグレス制限を適用し（失敗時は起動中断＝fail-closed。`CLAUDE_CONTAINER_NO_FIREWALL=1` で警告表示の上スキップ）、次にバックグラウンドで `sudo init-firewall.sh --refresh-domains` を15秒間隔で回すループを `&` で起動する（CDNの短いTTLによるIPローテーション追従。詳細は下記「CDN IP ローテーション追従」参照）。ループの出力は対話TUIの端末（`compose.yml` の `tty: true`）を汚さないよう `/tmp/claude-firewall-refresh.log` へリダイレクトする。`exec claude --dangerously-skip-permissions` はこのシェル自身のプロセスイメージを置き換えるだけなので、`&` で先にフォークしたループはそのまま子プロセスとして生き続ける。`CLAUDE_CONTAINER_NO_FIREWALL=1` 時はこのループも起動しない。PID1 は tini（`Dockerfile.claude` 節参照）。最後に `~/.claude/plugins/` 内の設定ファイルに残存するホスト側ユーザーのパス（例: `/home/tsu/.claude`）をコンテナ内パス（`/home/node/.claude`）に自動修正する。ホスト側とコンテナ内でユーザー名が異なる環境でのプラグインパス不整合を吸収するための仕組み。
- **`init-firewall.sh`** — deny-by-default のエグレス許可リスト。Anthropic 公式 devcontainer の同名スクリプトの移植で、iptables で Claude Code に必要なエンドポイント（api.anthropic.com・GitHub IP レンジ等）と `/etc/claude-container/allowed-domains.txt`（ビルド時焼き込み）のドメインのみ許可する。公式との差分: ipset 不使用（rootless podman ではホストの `ip_set` カーネルモジュールを autoload できないため素の iptables ルールで代替）、DNS は `/etc/resolv.conf` のリゾルバ宛のみ、IPv6 は全遮断（許可リストが A レコードのみのため、IPv6 経由のバイパスを防ぐ）。root 所有で node ユーザーは sudoers 定義（`/etc/sudoers.d/node-firewall`）によりこのスクリプトの実行のみ可能 — 実行時にコンテナ内のコードが許可リストを改変できない（sudoers は引数を制限していないため `--refresh-domains` 呼び出しも同じ許可でカバーされる）。GitHub IP レンジは起動時にライブ取得せず、ビルド時に焼き込まれたスナップショット（`/etc/claude-container/github-meta.json`）を読み込むだけ（詳細は下記「GitHub meta スナップショット」参照）。設定完了後に example.com 到達不可・api.github.com / api.anthropic.com 到達可を自己検証する。GitHub 到達確認は API クォータを消費しない TCP 接続確認（`/dev/tcp`）で行う。IPv6 無効化は `compose.yml` の `sysctls` が主対策だが、それが効かない環境向けにこのスクリプト自身も `/proc/sys/net/ipv6/conf/*/disable_ipv6` への書き込みをフォールバックとして試みる（失敗しても警告のみで起動は継続——このスクリプトの他部分の fail-closed 原則に対する意図的な例外）。いずれの結果でも後段の `ip6tables` DROP は変わらず適用される。許可ドメインのIPローテーションには `--refresh-domains` モードで追従する（詳細は下記「CDN IP ローテーション追従」参照）。
- **`packages.txt`** / **`requirements.txt`** / **`allowed-domains.txt`** — claude-container 同梱のデフォルト apt/pip パッケージ一覧と追加許可ドメイン一覧（フォールバック値、空のまま維持）。1行1エントリ、`#` で始まる行はコメント。`requirements.txt` は `pip3 install -r` にそのまま渡されるが、実質的なエントリが無い場合は install ステップ自体を丸ごとスキップする — ベースイメージに pip3 は含まれていないため、`requirements.txt` を使うプロジェクトは `packages.txt` に `python3-pip` を追加する必要がある（さもないと Dockerfile が明示的なエラーで失敗する）。`packages.txt` 内で `-` から始まる行はインストール時にフィルタされ、apt オプションを注入できないようにしている。プロジェクト固有のエントリはここではなくターゲットプロジェクトの `.claude-container.d/` に置く — claude-container 自体はプロジェクト非依存を保つ必要がある。

### GitHub meta スナップショット

`init-firewall.sh` の許可リストが使う GitHub IP レンジは `https://api.github.com/meta` から取得する。未認証 GitHub API のレート制限（60 req/h/IP）を避けるため、取得は `claude-container` の `stage_build_context()` 内の1箇所でのみ行う（`-b` のたび最大1リクエスト）。取得結果は `.build-context/<PROJECT_NAME>/github-meta.json` に書き込まれ、`Dockerfile.claude` がそれを `COPY` してイメージへ焼き込む（ネットワーク呼び出しを伴わないので通常の content-hash キャッシュが効く）。取得に失敗した場合は、(1) このプロジェクトの `.build-context/<PROJECT_NAME>/`（`--clean` まで永続する固定パス）に残っている前回分、(2) それも無ければ他プロジェクトの最新スナップショット（新規プロジェクトの初回ビルド時のフォールバック。GitHub の IP レンジは変更頻度が低いため実用上問題ない）を警告付きで再利用し、いずれも無い場合のみビルドを中断する。`init-firewall.sh` は起動のたびにこのイメージ内スナップショットを読み込むだけで、ランタイムでのライブ取得は行わない — GitHub の IP レンジは変更頻度が低いため、`-b` のたびに更新される多少古いコピーでも実用に足りる。

### CDN IP ローテーション追従

`allowed-domains.txt` 等で許可した CDN 配下のドメイン（例: CloudFront）は DNS の TTL が短く（実測 13〜60秒）、A レコードのセットがセッション中に丸ごと切り替わることがある。`init-firewall.sh` は起動時にドメインを1回解決して個別 IP を `/32` で許可するため、そのままではローテーション後に新規接続が失敗し続ける（2026-07 に実障害として確認）。

対策として、許可ドメインごとの ACCEPT ルールには `-m comment --comment "domain=<domain>;gen=<epoch>"` で世代タグを付与する（GitHub CIDR・ホストネットワークルールにはタグを付けない — 短TTLローテーションと無関係なため）。`entrypoint.sh` が起動するバックグラウンドループから15秒間隔で `init-firewall.sh --refresh-domains` を呼び、チェーンをフラッシュせずに新しい IP を差分追加し、`GRACE_WINDOW_SECONDS`（180秒）を超えて再出現しない IP を個別削除する（実装の詳細手順はスクリプト内コメント参照）。個別ドメインの解決失敗はコンテナを落とさず次サイクルへ持ち越す fail-open 設計（起動時のフル初期化は従来どおり fail-closed のまま）。

### プロジェクト固有設定（`.claude-container.d/`）

利用側プロジェクトの claude-container 向け設定は `.claude-container.d/` ディレクトリに一本化されており、中身は読み込みタイミングが異なる2種類に分かれる。

**ビルド時焼き込み設定**: `.claude-container.d/packages.txt`・`requirements.txt`・`allowed-domains.txt`。存在する場合、ビルドコンテキストのステージング時に claude-container 同梱のデフォルトを上書きする。ファイルが無ければ claude-container 同梱の汎用（空の）デフォルトにフォールバックし、`stage_build_context()` は無いファイルごとに `WARNING:` 行を出力してフォールバックが無言にならないようにする — 以前は claude-container 自身の `packages.txt` に焼き込まれたパッケージに依存していたプロジェクト（2026-07-01 のプロジェクト非依存化リファクタでプロジェクト固有エントリが外出しされる前）は、そうでないと理由も分からずリビルド時にパッケージを失っていた（実インシデント: findsummits の `gcc`/`python3`/`make` がこうして消失した — 上記の `PROJECT_NAME` 衝突とは別の 2026-07-02 の事案）。`allowed-domains.txt` にはエグレスファイアウォールが許可すべき追加ドメイン（例: `pypi.org`）を列挙する。イメージにビルド時に焼き込まれるため、変更を反映するには `-b` でのリビルドが必要。

**ランタイム設定**: `.claude-container.d/env`（`KEY=VALUE` 形式）。上記「環境変数」節の読み込み対象そのもので、起動のたび毎回読み込まれビルド時には一切参照されない。

イメージ名は `localhost/<PROJECT_NAME>_claude-auth-workspace`（`PROJECT_NAME` の算出方法は上記 `claude-container` の項目を参照）。`-b` を渡さずイメージが既に存在する場合、Compose はビルドステップ（およびステージングステップ）を丸ごとスキップする。

**秘密情報は `.claude-container.d/`（`env` を含む）にも通さない。** `packages.txt`/`requirements.txt`/`allowed-domains.txt` はビルド時にイメージへ焼き込まれる（秘密情報は禁止 — ビルドコンテキストは秘密の保管場所ではない、後述の「残存リスク」参照）。`env`（`.claude-container.d/env`）はターゲットプロジェクトがコミットすることを前提とするランタイムファイルなので、秘密でない設定（パス・フラグ等）専用 — 秘密の値を直接書き込んだ場合（例: `GH_TOKEN=...`）、そのままではコンテナに渡らないため `claude-container` が警告で検知する。秘密情報の唯一の正規の置き場所は、パスで参照する独立したホスト側ファイル（例: `GH_TOKEN_FILE`、README.md「利用側プロジェクトの設定」参照）である: `compose.yml` がこれを読み取り専用でマウントし、`environment:` ではなく `entrypoint.sh` が読み込んで export するため、`podman inspect` の出力には一切現れない。

## イメージの変更

リビルド手順、`CACHEBUST`/`CLAUDE_CODE_VERSION` の扱い、`DISABLE_AUTOUPDATER`、`.build-context/` のクリーンアップは README.md の「イメージの変更」節を参照。実装上のポインタ: GitHub meta の再取得は `claude-container` の `stage_build_context()` 内で行われる（上記「GitHub meta スナップショット」参照）。

## コンテナ間の永続化

コンテナ再起動をまたいで保持される bind mount の一覧は README.md の「コンテナ間の永続化」節を参照。bash_history の `.gitignore` 推奨設定は README.md の「利用側プロジェクトの設定」節にある。

## セキュリティモデル

コンテナ内で Claude は `--dangerously-skip-permissions` で動作するため、ツール使用の確認プロンプトなしに動作する。ガードレールはコンテナ境界であり、Claude はマウントされたワークスペースと `/data` への読み書き権限を全面的に持つ。意図したプロジェクトスコープ外の機密データを含むディレクトリはマウントしないこと。

ネットワーク面は `init-firewall.sh` による deny-by-default のエグレス許可リストで制限される（既定で有効）。認証情報（`~/.claude.json`）やソースが実行時にマウントされるため、悪意ある pip パッケージやプロンプトインジェクションによる外部送信・C2 化を「許可済みエンドポイント以外への通信不可」で封じる。無効化は利用側プロジェクトの `.claude-container.d/env` に `CLAUDE_CONTAINER_NO_FIREWALL=1`。

**残存リスク（許可リストでも防げないもの）:**

- DNS トンネリング: リゾルバ宛 53 番は許可されるため、DNS クエリに載せた exfiltration は原理上可能
- 許可済みサービスの悪用: GitHub 等の許可済みドメイン自体を送信先にされるリスクは残る。また CDN 配下のドメイン（claude.ai 等）は IP を共有するため、同一 CDN エッジ上の他サイトへも IP レベルでは到達できる。`GH_TOKEN_FILE`（README.md「利用側プロジェクトの設定」参照）を設定した場合はこのリスクが能動的になる: プロンプトインジェクションや悪意あるパッケージがトークンを読み取り、そのスコープ内で GitHub へ書き込める（対象リポジトリへの意図しない issue 作成・issue 本文経由の情報送信）。ファイアウォールは GitHub 自体を許可しているため防げず、緩和策は fine-grained PAT のスコープ最小化（Issues のみ・対象リポジトリ限定・短期限）のみ
- IP ローテーション: 許可ドメインの IP は約15秒間隔のバックグラウンド差分リフレッシュ（上記 `init-firewall.sh` 節参照）で追従するが、ローテーション直後からリフレッシュが反映されるまでの数十秒（取りこぼし込みで最大 `REFRESH_INTERVAL_SECONDS` の2倍程度）は新規接続が失敗しうる。コンテナ再起動が必須だった以前と比べれば大幅に縮小されるが、ゼロにはできない。GitHub IP レンジはビルド時スナップショット固定のため同様に古くなりうる（`-b` のたびに再取得を試み、失敗時は前回ステージング分を再利用）
- ビルド時ネットワークは無制限: `pip3 install` は setup.py / build backend の任意コードをビルド時に実行しうる。ただし build context に秘密情報は含まれず、イメージへ焼き込まれた悪性コードの実行時通信は上記 firewall が封じる

## Podman 固有の注意

Podman 固有機能（`userns_mode: keep-id`・`--in-pod false`）と Docker 移植時の注意点は README.md の「Podman 固有の注意」節を参照。

## 変更後の確認

テストスイートはない。`./lint.sh` が集約 lint target（`bash -n`・`shellcheck`・`podman compose config` を一括実行。詳細は README.md の「変更後の確認」節を参照）。対象の bash スクリプトはリポジトリ内ファイル（gitignore 対象を除く追跡済み・未追跡）の shebang から動的に検出するため、スクリプトを追加/削除しても対象リストの手動同期は不要（以前は README.md と CLAUDE.md の両方に `bash -n` の対象リストを手書きしており、ズレたことがある）。編集時は PostToolUse hook（`.claude/hooks/lint-posttool.sh`）が該当ファイルの shellcheck 違反を自動提示する。提示された違反はそのターン内で解消する。

---

## 開発ガイドライン

### コア原則

#### 1. 計画を優先する
Plan Modeへの切り替え基準に該当する作業（グローバル CLAUDE.md 参照）は `.claude/plan-<slug>.md` に計画をまとめる。それ以外の軽微な実装タスクは `.claude/todo.md` に直接書く。いずれも承認を得てから実装を始める（詳細は「計画ファイル・handover の扱い」節参照）。

#### 2. サブエージェントを活用
使いどころ・モデル選択・並列利用の基準はグローバル CLAUDE.md（「モデルを使い分ける」「サブエージェントの並列利用」節）に従う。
1つのサブエージェントには1つのタスクを明確に割り当てる。

#### 3. 学びを活かす
指摘やフィードバックを受けたときは、`.claude/lessons.md` にそのポイントを簡潔に記録する。

#### 4. バグ修正の対応
バグ報告を受けたら、ログやエラー、失敗テストを確認した上で、できる限り自律的に修正する。
必要最小限の変更に留め、ユーザーへの質問は最小限にする。
一時しのぎの修正は避け、なぜそのバグが起きたかを理解した上で本質的な解決を目指す。
ただし Plan Mode 切り替え基準（コア原則 1）に該当する規模の場合は、自律修正より計画を優先する。

### セッション開始時のルーティン（必須）
グローバル CLAUDE.md の手順（注入された handover・lessons の確認、関連レッスンの共有）に従う。対象ファイルパスは `.claude/handovers/`（最新1件）・`.claude/lessons.md`（未蒸留分）で、いずれも `.claude/hooks/session-start.sh` が自動注入する。

### Best Practices（教訓蒸留）運用ルール

@.claude/best_practices.md

上記は `@` インポートによりセッション開始時に毎回自動でコンテキストへ読み込まれる。lessons.md は全文注入せず、`.claude/hooks/session-start.sh` が `.claude/best_practices_watermark`（前回蒸留時点の件数）以降の未蒸留分のみを自動注入する。全文が必要な場面（転記時の重複チェック等）でのみ都度 Read する。

- 学びの記録先・方法は「コア原則 3. 学びを活かす」参照
- `/update-best-practices`（グローバルコマンド、Fable 実行・利用不可時は Opus）が `.claude/lessons.md` を再分析し、
  `.claude/best_practices.md`（git 管理対象）を再合成する
  - 蒸留観点: ビルド/キャッシュ運用、コンテナ・セキュリティ境界の設計判断、fail-open/fail-closed の選択基準、ドキュメント整合性、実機検証の徹底
  - 原則数目安: 8〜12件（規模に見合った少なめ設定。増えすぎたら統合する）
  - 除外: プロジェクト固有の技術詳細（特定パッケージ名・特定コマンドの出力形式等）は原則に含めない
  - 実行後、`.claude/best_practices.md` と `.claude/best_practices_watermark` はコマンド内でコミットまで完結する
- lessons.md が一定量増えるとセッション開始時に実行が自動的に推奨される（`.claude/hooks/session-start.sh` が検知）

### タスク管理の流れ
上記ルーティンで把握した情報をもとに、以下の順で進める。

1. 計画を `.claude/todo.md`（軽微タスク）または `.claude/plan-<slug>.md`（Plan Mode 承認済みの本格的な計画）に書く
2. 実装前に計画を確認・承認
3. 進捗をマークしながら作業
4. 各ステップで変更の概要を簡単に説明
5. 完了時に結果をレビューとして記録
6. 修正があったら `.claude/lessons.md` を更新

`.claude/todo.md` は完了した項目を消す（履歴は git で追える）。長期保留中の項目は「保留」セクションへ移す。

### 利用側プロジェクトからの issue 受付フロー

利用側プロジェクト（例: findsummits）が、環境起因（コンテナ・ファイアウォール・ビルド・イメージ等）の
問題・要望を本リポジトリ（`jj1xgo/claude-container`）へ GitHub issue で起票することがある。

**対応フロー**: open issue を確認 → 調査 → 対応方針をコメント → 実装 → 対応完了をコメント
（**リビルド要否を明記**。ビルド時焼き込み設定・イメージ変更を伴う場合はリビルド必須である旨を書く）。

**クローズの役割分担**: 動作確認を要する対応は起票側（利用側プロジェクト）がクローズする。
調査の結果「仕様どおり・対応不要」と判明した場合は、対応側（本リポジトリ）が説明コメント付きで
クローズすることがある。

**利用側に作業を要求する対応**（設定移行等）は issue を Open のままにし、対応完了コメントで
その旨を明示する。

**AI がコメント・クローズする場合**は、本文の**末尾にモデル名のみを署名**として記入する
（例: `— Sonnet 4.5`）。経緯の説明文は書かない。

**注記**: session-start hook が本リポジトリ宛の open issue を自動確認し注入する
（フェイルソフト。`gh` 不在・API 失敗時は一行メッセージのみでスキップする）。

### 計画ファイル・handover の扱い

- **plan ファイルの置き場・命名規則**: `.claude/plan-<slug>.md` とする。`<slug>` は `/plan` コマンドが `~/.claude/plans/<slug>.md`（ホーム配下・グローバル）に自動生成する際のファイル名をそのまま流用し、`plan-` プレフィックスは他の運用ファイルとの視認性のためにつける。`ExitPlanMode` 承認後・ファイル編集を始める前に `mv ~/.claude/plans/<slug>.md .claude/plan-<slug>.md` で移動する（両者は `.claude` という名前を含むが別の場所なので、`mv` 実行時は必ずフルパスで確認すること）。セッションごとに `<slug>` が異なるため、複数セッションが同時に Plan Mode を使っても plan ファイルが衝突しない。
- **plan ファイル内のファイル参照はコード表記にする**: `.claude/plan-<slug>.md` 内でリポジトリ内ファイルを参照するときは、Markdown リンクではなく**コード表記（バッククォート）**で書く。`mv` 元（`~/.claude/plans/`）でも移動先（`.claude/plan-<slug>.md`）でも相対リンクが解決せず broken-link になるため、リンクにしないことで構造的に回避する。
- **計画の各タスクに実行モデルを明記する**: グローバル CLAUDE.md「モデルを使い分ける」節参照。
- **handover ファイル名の日時**: ファイル名に使う日時は必ず `date '+%Y-%m-%d_%H%M'` コマンドで実時刻を取得すること。会話履歴や記憶から日付を推測してはならない（同日別セッションとの衝突を防ぐため）。
- **plan ファイルの完了時の扱い**: 計画の実装が完了し区切りがついたら `.claude/plan-<slug>.md` を `git rm` で削除しコミットする（役目を終えた計画は残さない。履歴は git で追える）。ただし作業が中断・持ち越しになり handover を書いて次セッションへ引き継ぐ場合は削除せず残す。次セッションは `<slug>` を含むファイル名とタイムスタンプで対象を特定して再開する。

### ルールと制約
- **Git**：Conventional Commits形式を使用。本文は日本語で記述（例: `feat: ユーザー認証にOAuth2を追加`）。確認なしに自動コミット・自動pushはしない。
