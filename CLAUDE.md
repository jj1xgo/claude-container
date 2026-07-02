# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

[findsummits](https://github.com/JJ1XGO/findsummits) プロジェクト向けの Claude Code サンドボックス環境。
[sethjensen1/claude-container](https://github.com/sethjensen1/claude-container)（MIT）をフォークし、findsummits の開発環境に合わせてカスタマイズしたもの。apt/pip パッケージは `.claude-container.d/` で利用側プロジェクトごとに指定でき、本リポジトリ自体は特定プロジェクトに依存しない。

## Usage

```bash
./claude-container /path/to/project
```

Full command reference (`-b` rebuild, `--clean`, symlink support) is in README.md's "Usage" section (日本語版「使い方」).

## Environment Variables

Set via a `.claude-container` file (`KEY=VALUE` lines) at the target project root, read automatically before launch. Values are taken literally after the first `=` — no quoting, expansion, or command execution is interpreted. The file is deliberately NOT `source`d, so a malicious target project cannot run code on the host.

Variable list and defaults are in README.md's "Environment Variables" section (日本語版「環境変数」).

## Architecture

> **前提**: 本節以降の `/home/node/` 等のパスや `sudo` コマンドは、`./claude-container` 経由で実際に起動した**コンテナ内部**の事実を説明したものである。このリポジトリのソースをコンテナを介さずホスト上で直接編集している場合、これらのパス・コマンドは実在しない（ビルド対象の仕様として読むこと）。

The main files work together:

- **`claude-container`** (bash) — entry point. Resolves absolute paths, then computes `PROJECT_NAME` from the target project's directory basename (sanitized) plus the first 8 characters of a sha256 hash of its absolute path (e.g. `findsummits-3f2a9c1b`) via `compute_project_name()`. This keys the image name (`localhost/<PROJECT_NAME>_claude-auth-workspace`) and the staged build context (`.build-context/<PROJECT_NAME>/`) per project, and `-p "$PROJECT_NAME"` is passed to every `podman compose` invocation — without this, interleaving builds across different target projects would silently overwrite each other's image and staged context (real incident, 2026-07-02). Reads `KEY=VALUE` lines from the target project's `.claude-container` (safe parse, no `source`), then sets `CONTEXT` and `CLAUDE_CONTAINER_DIR` and delegates to `podman compose run`. When `-b` is passed, sets `CACHEBUST` to the current epoch seconds so the install layer is always rebuilt, and runs `podman compose build` as a separate step before `run` — `run --build` would fall back to the existing stale image when the build fails (fail-open), whereas the separate build step aborts the launch on failure (fail-closed). Before building (on `-b`, or when the image doesn't exist yet), it stages `entrypoint.sh` and `init-firewall.sh` plus the target project's `.claude-container.d/packages.txt` / `requirements.txt` / `allowed-domains.txt` (falling back to claude-container's own bundled copies when the project doesn't provide them) into that project's `BUILD_CONTEXT_DIR`. A fixed path per project (not `mktemp -d`) is used so build caching stays stable and no cleanup trap is needed. `stage_build_context()` also fetches the GitHub meta snapshot here (see "GitHub meta スナップショット" below). `--clean <directory>` removes only that project's image/network/build-context; `--clean` with no directory (`clean_all()`) discovers every `localhost/*_claude-auth-workspace` image and removes all of them, including the legacy pre-migration shared image `localhost/claude-container_claude-auth-workspace`.
- **`compose.yml`** — defines the single service `claude-auth-workspace`. `build.context` is `${BUILD_CONTEXT_DIR}` (the staged directory above); `build.dockerfile` is `${CLAUDE_CONTAINER_DIR}/Dockerfile.claude` — Dockerfiles can live outside the build context, so `Dockerfile.claude` itself is read directly from the claude-container repo without staging. Mounts the host's `~/.claude.json` and `~/.claude/` (auth + config), the target workspace at `/workspace`, and `/etc/localtime` (read-only, for host timezone). Uses `userns_mode: keep-id` so files inside the container have the same UID as the host user. Adds `NET_ADMIN`/`NET_RAW` capabilities so `init-firewall.sh` can install iptables rules inside the container's network namespace. Passes `CACHEBUST` as a build arg to enable cache-busting on `-b`. Sets `net.ipv6.conf.{all,default}.disable_ipv6=1` via `sysctls` — podman's default bridge network has no IPv6 global route (link-local `fe80::` only), but glibc's `getaddrinfo(AI_ADDRCONFIG)` still reports IPv6 as available and returns AAAA records, so curl/requests' Happy Eyeballs intermittently stalls trying unreachable IPv6 candidates for allowlisted CDN-backed domains. This is the primary fix; `init-firewall.sh`'s `ip6tables` DROP (below) remains the security boundary regardless.
- **`Dockerfile.claude`** — builds on `debian:stable` (currently trixie), installs Claude Code dependencies and the staged `packages.txt`/`requirements.txt` (see above), then installs Claude Code via the official native installer (`curl -fsSL https://claude.ai/install.sh | bash`). It also `COPY`s the `github-meta.json` staged by `claude-container` and validates it with `jq` — no network call happens in this layer, so Docker's content-hash caching handles it naturally (see "GitHub meta スナップショット" below). An `ARG CACHEBUST` is declared immediately before the install `RUN`, ensuring the install layer (and everything below it) is never served from cache when `-b` is used. Runs as the non-root `node` user (UID 1000, created explicitly) with `CMD ["/home/node/entrypoint.sh"]` (which applies the firewall, then execs `claude --dangerously-skip-permissions`). `debian:stable` を採用した理由: native installer の Claude Code バイナリは glibc のみ依存で Node.js を実行時に必要とせず、Node.js 同梱の `node:24` より軽量な Debian ベースで足りるため。注意: `ca-certificates` は debian:stable にも**同梱されていない**ため、HTTP で先行インストールしてから apt sources を HTTPS に書き換える（Dockerfile 冒頭が2段構成なのはこのため。削除しないこと）。
- **`entrypoint.sh`** — コンテナ起動時に実行されるシェルスクリプト。まず `sudo /usr/local/bin/init-firewall.sh` でエグレス制限を適用し（失敗時は起動中断＝fail-closed。`CLAUDE_CONTAINER_NO_FIREWALL=1` で警告表示の上スキップ）、次にバックグラウンドで `sudo init-firewall.sh --refresh-domains` を15秒間隔で回すループを `&` で起動する（CDNの短いTTLによるIPローテーション追従。詳細は下記「CDN IP ローテーション追従」参照）。ループの出力は対話TUIの端末（`compose.yml` の `tty: true`）を汚さないよう `/tmp/claude-firewall-refresh.log` へリダイレクトする。`exec claude --dangerously-skip-permissions` はこのシェル自身のプロセスイメージを置き換えるだけなので、`&` で先にフォークしたループはそのまま子プロセスとして生き続ける。`CLAUDE_CONTAINER_NO_FIREWALL=1` 時はこのループも起動しない。最後に `~/.claude/plugins/` 内の設定ファイルに残存するホスト側ユーザーのパス（例: `/home/tsu/.claude`）をコンテナ内パス（`/home/node/.claude`）に自動修正する。ホスト側とコンテナ内でユーザー名が異なる環境でのプラグインパス不整合を吸収するための仕組み。
- **`init-firewall.sh`** — deny-by-default のエグレス許可リスト。Anthropic 公式 devcontainer の同名スクリプトの移植で、iptables で Claude Code に必要なエンドポイント（api.anthropic.com・GitHub IP レンジ等）と `/etc/claude-container/allowed-domains.txt`（ビルド時焼き込み）のドメインのみ許可する。公式との差分: ipset 不使用（rootless podman ではホストの `ip_set` カーネルモジュールを autoload できないため素の iptables ルールで代替）、DNS は `/etc/resolv.conf` のリゾルバ宛のみ、IPv6 は全遮断（許可リストが A レコードのみのため、IPv6 経由のバイパスを防ぐ）。root 所有で node ユーザーは sudoers 定義（`/etc/sudoers.d/node-firewall`）によりこのスクリプトの実行のみ可能 — 実行時にコンテナ内のコードが許可リストを改変できない（sudoers は引数を制限していないため `--refresh-domains` 呼び出しも同じ許可でカバーされる）。GitHub IP レンジは起動時にライブ取得せず、ビルド時に焼き込まれたスナップショット（`/etc/claude-container/github-meta.json`）を読み込むだけ（詳細は下記「GitHub meta スナップショット」参照）。設定完了後に example.com 到達不可・api.github.com / api.anthropic.com 到達可を自己検証する。GitHub 到達確認は API クォータを消費しない TCP 接続確認（`/dev/tcp`）で行う。IPv6 無効化は `compose.yml` の `sysctls` が主対策だが、それが効かない環境向けにこのスクリプト自身も `/proc/sys/net/ipv6/conf/*/disable_ipv6` への書き込みをフォールバックとして試みる（失敗しても警告のみで起動は継続——このスクリプトの他部分の fail-closed 原則に対する意図的な例外）。いずれの結果でも後段の `ip6tables` DROP は変わらず適用される。許可ドメインのIPローテーションには `--refresh-domains` モードで追従する（詳細は下記「CDN IP ローテーション追従」参照）。
- **`packages.txt`** / **`requirements.txt`** / **`allowed-domains.txt`** — claude-container's bundled default apt/pip package lists and extra allowed-domain list (fallback values, kept empty). One entry per line; lines starting with `#` are comments. `requirements.txt` is passed to `pip3 install -r`, but the install step is skipped entirely when the file has no real entries — pip3 is not in the base image, so projects that use `requirements.txt` must add `python3-pip` to their `packages.txt` (the Dockerfile fails with an explicit error otherwise). Lines starting with `-` in `packages.txt` are filtered out at install time so apt options cannot be injected. Project-specific entries belong in the target project's `.claude-container.d/`, not here — claude-container itself must stay project-agnostic.

### GitHub meta スナップショット

`init-firewall.sh` の許可リストが使う GitHub IP レンジは `https://api.github.com/meta` から取得する。未認証 GitHub API のレート制限（60 req/h/IP）を避けるため、取得は `claude-container` の `stage_build_context()` 内の1箇所でのみ行う（`-b` のたび最大1リクエスト）。取得結果は `.build-context/<PROJECT_NAME>/github-meta.json` に書き込まれ、`Dockerfile.claude` がそれを `COPY` してイメージへ焼き込む（ネットワーク呼び出しを伴わないので通常の content-hash キャッシュが効く）。取得に失敗した場合は、(1) このプロジェクトの `.build-context/<PROJECT_NAME>/`（`--clean` まで永続する固定パス）に残っている前回分、(2) それも無ければ他プロジェクトの最新スナップショット（新規プロジェクトの初回ビルド時のフォールバック。GitHub の IP レンジは変更頻度が低いため実用上問題ない）を警告付きで再利用し、いずれも無い場合のみビルドを中断する。`init-firewall.sh` は起動のたびにこのイメージ内スナップショットを読み込むだけで、ランタイムでのライブ取得は行わない — GitHub の IP レンジは変更頻度が低いため、`-b` のたびに更新される多少古いコピーでも実用に足りる。

### CDN IP ローテーション追従

`allowed-domains.txt` 等で許可した CDN 配下のドメイン（例: CloudFront）は DNS の TTL が短く（実測 13〜60秒）、A レコードのセットがセッション中に丸ごと切り替わることがある。`init-firewall.sh` は起動時にドメインを1回解決して個別 IP を `/32` で許可するため、そのままではローテーション後に新規接続が失敗し続ける（2026-07 に実障害として確認）。

対策として、許可ドメインごとの ACCEPT ルールには `-m comment --comment "domain=<domain>;gen=<epoch>"` で世代タグを付与する（GitHub CIDR・ホストネットワークルールにはタグを付けない — 短TTLローテーションと無関係なため）。`entrypoint.sh` が起動するバックグラウンドループから15秒間隔で `init-firewall.sh --refresh-domains` を呼び、チェーンをフラッシュせずに新しい IP を差分追加し、`GRACE_WINDOW_SECONDS`（180秒）を超えて再出現しない IP を個別削除する（実装の詳細手順はスクリプト内コメント参照）。個別ドメインの解決失敗はコンテナを落とさず次サイクルへ持ち越す fail-open 設計（起動時のフル初期化は従来どおり fail-closed のまま）。

### Project-specific packages (`.claude-container.d/`)

A target project can place `.claude-container.d/packages.txt`, `.claude-container.d/requirements.txt`, and/or `.claude-container.d/allowed-domains.txt` at its root (parallel to `.claude-container` for env vars, but a directory to avoid name collision). If present, these override claude-container's bundled defaults when staging the build context. Absent files fall back to claude-container's bundled generic (empty) defaults, and `stage_build_context()` prints a `WARNING:` line per absent file so the fallback is never silent — a project that used to rely on packages baked into claude-container's own `packages.txt` (before the 2026-07-01 project-agnostic refactor moved project-specific entries out) would otherwise lose those packages on rebuild with no indication why (real incident: findsummits' `gcc`/`python3`/`make` disappeared this way — a separate 2026-07-02 incident from the `PROJECT_NAME` collision above). `allowed-domains.txt` lists extra domains (e.g. `pypi.org`) the egress firewall should allow; it is baked into the image at build time, so changing it requires a `-b` rebuild.

The image name is `localhost/<PROJECT_NAME>_claude-auth-workspace` (see the `claude-container` bullet above for how `PROJECT_NAME` is derived). When `-b` is not passed and the image already exists, Compose skips the build step (and the staging step) entirely.

## Modifying the Image

Rebuild procedure, `CACHEBUST`/`CLAUDE_CODE_VERSION` handling, `DISABLE_AUTOUPDATER`, and `.build-context/` cleanup are covered in README.md's "Modifying the Image" section (日本語版「イメージの変更」). Implementation pointer: the GitHub meta re-fetch happens inside `claude-container`'s `stage_build_context()` (see "GitHub meta スナップショット" above).

## Persistence Across Container Runs

コンテナ再起動をまたいで保持される bind mount の一覧は README.md の「コンテナ間の永続化」（英語版 "Persistence Across Container Runs"）節を参照。bash_history の `.gitignore` 推奨設定は README.md の「利用側プロジェクトの設定」（英語版 "Target Project Configuration"）節にある。

## Security Model

Claude runs with `--dangerously-skip-permissions` inside the container, meaning it operates without tool-use confirmation prompts. The container boundary is the guardrail — Claude has full read/write access to the mounted workspace and `/data`. Do not mount directories containing sensitive data outside the intended project scope.

ネットワーク面は `init-firewall.sh` による deny-by-default のエグレス許可リストで制限される（既定で有効）。認証情報（`~/.claude.json`）やソースが実行時にマウントされるため、悪意ある pip パッケージやプロンプトインジェクションによる外部送信・C2 化を「許可済みエンドポイント以外への通信不可」で封じる。無効化は利用側プロジェクトの `.claude-container` に `CLAUDE_CONTAINER_NO_FIREWALL=1`。

**残存リスク（許可リストでも防げないもの）:**

- DNS トンネリング: リゾルバ宛 53 番は許可されるため、DNS クエリに載せた exfiltration は原理上可能
- 許可済みサービスの悪用: GitHub 等の許可済みドメイン自体を送信先にされるリスクは残る。また CDN 配下のドメイン（claude.ai 等）は IP を共有するため、同一 CDN エッジ上の他サイトへも IP レベルでは到達できる
- IP ローテーション: 許可ドメインの IP は約15秒間隔のバックグラウンド差分リフレッシュ（上記 `init-firewall.sh` 節参照）で追従するが、ローテーション直後からリフレッシュが反映されるまでの数十秒（取りこぼし込みで最大 `REFRESH_INTERVAL_SECONDS` の2倍程度）は新規接続が失敗しうる。コンテナ再起動が必須だった以前と比べれば大幅に縮小されるが、ゼロにはできない。GitHub IP レンジはビルド時スナップショット固定のため同様に古くなりうる（`-b` のたびに再取得を試み、失敗時は前回ステージング分を再利用）
- ビルド時ネットワークは無制限: `pip3 install` は setup.py / build backend の任意コードをビルド時に実行しうる。ただし build context に秘密情報は含まれず、イメージへ焼き込まれた悪性コードの実行時通信は上記 firewall が封じる

## Podman-specific Notes

Podman 固有機能（`userns_mode: keep-id`・`--in-pod false`）と Docker 移植時の注意点は README.md の "Podman-specific Notes" 節（日本語版「Podman 固有の注意」）を参照。

## Verifying Changes

テストスイートはない。確認コマンド（`bash -n` の対象・`podman compose config`）は README.md の "Verifying Changes" 節（日本語版「変更後の確認」）を参照。**新しいシェルスクリプトを追加/削除したときは、`bash -n` の対象ファイルリストを README.md と CLAUDE.md の両方で揃えること**（過去に両者がズレていたことがある）。

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

#### 4. バグ修正の対応
バグ報告を受けたら、ログやエラー、失敗テストを確認した上で、できる限り自律的に修正する。
必要最小限の変更に留め、ユーザーへの質問は最小限にする。
一時しのぎの修正は避け、なぜそのバグが起きたかを理解した上で本質的な解決を目指す。

### セッション開始時のルーティン（必須）
グローバル CLAUDE.md の手順（注入された handover・lessons の確認、関連レッスンの共有）に従う。対象ファイルパスは `.claude/handovers/`（最新1件）・`.claude/lessons.md`（未蒸留分）で、いずれも `.claude/hooks/session-start.sh` が自動注入する。

### Best Practices（教訓蒸留）運用ルール

@.claude/best_practices.md

上記は `@` インポートによりセッション開始時に毎回自動でコンテキストへ読み込まれる。lessons.md は全文注入せず、`.claude/hooks/session-start.sh` が `.claude/best_practices_watermark`（前回蒸留時点の件数）以降の未蒸留分のみを自動注入する。全文が必要な場面（転記時の重複チェック等）でのみ都度 Read する。

- 学びの記録先・方法は「コア原則 3. 学びを活かす」参照
- `/update-best-practices`（グローバルコマンド、Opus 実行）が `.claude/lessons.md` を再分析し、
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

### 計画ファイル・handover の扱い

- **plan ファイルの置き場・命名規則**: `.claude/plan-<slug>.md` とする。`<slug>` は `/plan` コマンドが `~/.claude/plans/<slug>.md`（ホーム配下・グローバル）に自動生成する際のファイル名をそのまま流用し、`plan-` プレフィックスは他の運用ファイルとの視認性のためにつける。`ExitPlanMode` 承認後・ファイル編集を始める前に `mv ~/.claude/plans/<slug>.md .claude/plan-<slug>.md` で移動する（両者は `.claude` という名前を含むが別の場所なので、`mv` 実行時は必ずフルパスで確認すること）。セッションごとに `<slug>` が異なるため、複数セッションが同時に Plan Mode を使っても plan ファイルが衝突しない。
- **plan ファイル内のファイル参照はコード表記にする**: `.claude/plan-<slug>.md` 内でリポジトリ内ファイルを参照するときは、Markdown リンクではなく**コード表記（バッククォート）**で書く。`mv` 元（`~/.claude/plans/`）でも移動先（`.claude/plan-<slug>.md`）でも相対リンクが解決せず broken-link になるため、リンクにしないことで構造的に回避する。
- **計画の各タスクに実行モデルを明記する**: グローバル CLAUDE.md「モデルを使い分ける」節参照。
- **handover ファイル名の日時**: ファイル名に使う日時は必ず `date '+%Y-%m-%d_%H%M'` コマンドで実時刻を取得すること。会話履歴や記憶から日付を推測してはならない（同日別セッションとの衝突を防ぐため）。
- **plan ファイルの完了時の扱い**: 計画の実装が完了し区切りがついたら `.claude/plan-<slug>.md` を `git rm` で削除しコミットする（役目を終えた計画は残さない。履歴は git で追える）。ただし作業が中断・持ち越しになり handover を書いて次セッションへ引き継ぐ場合は削除せず残す。次セッションは `<slug>` を含むファイル名とタイムスタンプで対象を特定して再開する。

### ルールと制約
- **Git**：Conventional Commits形式を使用。本文は日本語で記述（例: `feat: ユーザー認証にOAuth2を追加`）。確認なしに自動コミット・自動pushはしない。
