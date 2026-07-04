# Node.js 任意バージョン導入機構（`node-version.txt`）の追加

## Context

issue #3（sotlas-frontend からの受付、`enhancement`+`received`）: sotlas-frontend は Node 22.x を要求するが、
claude-container のベースイメージ（debian:stable/trixie）は apt 経由で 22.x を入手できない
（trixie は 20.19.2、testing は 22 を飛ばして 24.18.0、backports は nodejs 自体が無い。調査済み）。

Fable サブエージェントによる設計評価（本セッション内で実施・裏取り済み）:
- 汎用ビルドフック（任意スクリプト実行）案は監査対象が無限定になり却下
- **専用の宣言的設定ファイル**（バージョン番号のみを書く）を推奨。既存の
  packages.txt/requirements.txt/allowed-domains.txt という「宣言的ファイル＋本体側固定ロジック」の
  設計と一貫し、チェックサム検証込みの fail-closed を本体側で保証できる
- issue 本文にある「allowed-domains.txt への nodejs.org 追加が必要」という前提は誤り。ビルド時ネットワークは
  無制限（`init-firewall.sh` は `entrypoint.sh` 起動時＝ランタイムにのみ適用され、`Dockerfile.claude` の
  ビルドステップでは一切呼ばれない。`pip3 install` も同じ理由でビルド時に無制限で実行されている）。
  実装・確認とも本セッションで裏取り済み

この計画は上記の推奨方式（専用宣言的ファイル）を実装するもの。

## 実装

### 1. `.claude-container.d/node-version.txt`（新規・任意）

既存の `packages.txt`/`requirements.txt`/`allowed-domains.txt` と同じ「1行1エントリ、`.txt` 拡張子」の
命名規則に合わせる。中身はバージョン番号1行のみ（例: `22.14.0`。`v` 接頭辞なし）。

### 2. `claude-container` の `stage_build_context()` 更新

既存の `for file in packages.txt requirements.txt allowed-domains.txt` ループ（`WARNING` 付きで
claude-container 同梱の空フォールバックへ切替）とは**別扱い**にする。理由: あのループの `WARNING` は
「以前はプロジェクト固有パッケージが claude-container 本体に直書きされていて、汎用化リファクタ後に
`.claude-container.d/` へ移行し忘れると気づかず消失する」という**過去の移行漏れを検知するための警告**
（2026-07-02 の python3-missing インシデント由来）。`node-version.txt` は今回新設する任意機能であり、
Node を使わない大多数のプロジェクトが持たないのは正常な状態なので、同じ警告を出すと無関係な
プロジェクトにまでノイズになる。

```bash
if [[ -f "$PROJECT_CONF_DIR/node-version.txt" ]]; then
  cp "$PROJECT_CONF_DIR/node-version.txt" "$BUILD_CONTEXT_DIR/node-version.txt"
else
  : > "$BUILD_CONTEXT_DIR/node-version.txt"
fi
```

`stage_build_context()` 内、既存 for ループの直後に追記する。

**Fable レビューでの指摘と決定**: Fable から「allowed-domains.txt 等も多くのプロジェクトには無関係だが
一律 WARNING が出ており、node-version.txt だけ無警告にすると不揃いになる」との再考コメントがあった。
これに対しユーザーと協議のうえ、既存3ファイルの WARNING は変更しない方針とした
（2026-07-02 の移行漏れインシデントの再発検知という役目がまだ生きているため、この計画で触らない）。
一方で node-version.txt には「移行元」が存在しない新設機能なので、この計画では無警告のまま実装する。
既存3ファイルの WARNING 設計そのものを見直すかどうかは別 issue として切り出す（下記「派生 issue の起票」参照）。

### 3. `Dockerfile.claude` 更新

**a. 固定 apt レイヤー（`tini` 等と同じ行、23〜35行目付近）に `xz-utils` を追加**: `tar -xJf` に必要。
`tini` と同じ理由でプロジェクト側 `packages.txt` に置かず固定レイヤーにする（黙って落とされないため）。

**b. `requirements.txt` ブロックの直後（`ENV DEVCONTAINER=true` の手前）に新ブロックを追加**:

```dockerfile
# Install a specific Node.js version from the official nodejs.org tarball when
# .claude-container.d/node-version.txt specifies one (e.g. "22.14.0"). apt on
# debian:stable has no path to Node 22.x (trixie ships 20.x, testing skips
# straight to 24.x), so projects needing 22.x declare just the bare version
# number here instead of a general-purpose build hook (see claude-container#3
# for the design rationale). Verifies the download against nodejs.org's own
# SHASUMS256.txt before extracting — fails the build (not silently) on any
# mismatch or network failure. Architecture is auto-detected (uname -m) since
# the build host may be x86_64 or arm64 (e.g. podman machine on Apple Silicon).
COPY node-version.txt /tmp/node-version.txt
RUN NODE_VERSION="$(tr -d '[:space:]' < /tmp/node-version.txt)" && \
    if [ -n "$NODE_VERSION" ]; then \
      echo "$NODE_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || { \
        echo "ERROR: .claude-container.d/node-version.txt must contain a bare version like 22.14.0 (got: $NODE_VERSION)" >&2; exit 1; }; \
      case "$(uname -m)" in \
        x86_64) NODE_ARCH=x64 ;; \
        aarch64) NODE_ARCH=arm64 ;; \
        *) echo "ERROR: unsupported architecture $(uname -m) for node-version.txt" >&2; exit 1 ;; \
      esac; \
      cd /tmp && \
      curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" && \
      curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" && \
      grep " node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz\$" SHASUMS256.txt > node.sha256 && \
      [ -s node.sha256 ] && \
      sha256sum -c node.sha256 && \
      tar -xJf "node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" -C /usr/local --strip-components=1 && \
      rm -f "node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" SHASUMS256.txt node.sha256; \
    fi
```

`grep` の結果を一旦ファイルに落として `[ -s ]` で空でないことを確認してから `sha256sum -c` に渡す
（Dockerfile の `RUN` はデフォルトで `pipefail` が効かない `/bin/sh -c` のため、パイプ越しに
「grep が1件もマッチしなかった」ケースを握りつぶさないための明示的なガード）。
`uname -m` は `x86_64`/`aarch64` を返す前提（Debian の標準的な出力）。未対応アーキテクチャは
ERROR で fail-closed する。`/usr/local` に `--strip-components=1` で展開するので `node`/`npm` は
既定の `PATH` にそのまま乗る（追加の `ENV PATH` 不要）。

### 4. ドキュメント更新

- `README.md`（日本語・英語の両セクション）: 「利用側プロジェクトの設定」節のファイル一覧表に
  `node-version.txt` を追加（`-b` 必須・コミット対象・任意、と明記。「ビルド時ネットワークは無制限のため
  allowed-domains.txt への追加は不要」も明記し、issue #3 にあった誤前提を再発させない）。
  「アーキテクチャ」節の `packages.txt`/`requirements.txt`/`allowed-domains.txt` の説明にも一言追加。
  「イメージの変更」節のリビルド要否の記述にも `node-version.txt` を含める。
- `/workspace/CLAUDE.md`: 「アーキテクチャ」節の `packages.txt`/`requirements.txt`/`allowed-domains.txt`
  の bullet に `node-version.txt` の扱いを短く追記（詳細な実装理由は上記コード内コメントに譲り、
  CLAUDE.md 側は簡潔にとどめる）。

## 検証

1. `./lint.sh` で `claude-container` の shellcheck / bash -n が通ることを確認
2. 自己ホスト（`/workspace` 自身を対象プロジェクトとして起動）で実地確認:
   - `/workspace/.claude-container.d/node-version.txt` に `22.14.0` を書いて `./claude-container -b /workspace` を実行し、
     ビルドが成功すること・コンテナ内で `node --version` が `v22.14.0` を返すことを確認
   - 不正な値（例: `abc`）に書き換えて再度 `-b` を実行し、fail-closed でビルドが**失敗**することを確認
     （黙って古いイメージにフォールバックしないこと）
   - 確認後、テスト用の `node-version.txt` は削除する（claude-container 自体は Node 不要のため）
3. `.claude-container.d/node-version.txt` を置かない状態（既存プロジェクトの大多数のケース）でも
   ビルドが警告なしに成功することを確認（回帰確認）

## issue #3 への対応

実装・検証完了後、issue #3 に以下を含む対応方針コメントを投稿する（署名: `— Sonnet 5`）:
- 汎用ビルドフックではなく専用の宣言的ファイル方式を採用した理由（Fable 評価の要旨）
- 使い方: `.claude-container.d/node-version.txt` に `22.14.0` のようにバージョンのみを書き、`-b` でリビルド
- issue 本文にあった「allowed-domains.txt への追加が必要」という前提が誤りだった旨の訂正
- **起票側（sotlas-frontend）の作業が必要**なため issue は Open のまま維持し、対応完了コメントにその旨明記する
  （sotlas-frontend 側で `node-version.txt` を作成しリビルド・動作確認後、クローズは起票側に委ねる）

実装完了後、SemVer タグ付与（利用者から見えるインターフェース＝`.claude-container.d/` の設定形式が
増えるため minor 版）をユーザーに提案する。

## 派生 issue の起票

本実装とは独立した論点として、`gh issue create`（本リポジトリ `jj1xgo/claude-container`、
`enhancement` ラベル）で以下を起票する（署名: `— Sonnet 5`）:

- 標題（例）: 「packages.txt/requirements.txt/allowed-domains.txt フォールバック時の WARNING、
  今も一律に出す設計でよいか再検討」
- 本文: Fable レビューで出た「node-version.txt を無警告にするなら既存3ファイルとの不整合になるのでは」
  という指摘を経緯として記載し、現時点では「2026-07-02 の移行漏れインシデントの再発検知役目がまだ
  生きている」との判断で既存3ファイルの WARNING は変更しないことにした旨、再検討トリガー
  （例: インシデント発生からの経過期間、移行が概ね完了したと判断できる時期）を明記する
- 本実装（node-version.txt 追加）をブロックしない独立 issue として扱う
