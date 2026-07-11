# CLAUDE.md

## プロジェクト概要

[sethjensen1/claude-container](https://github.com/sethjensen1/claude-container)（MIT）をフォークした Claude Code サンドボックス環境。apt/pip パッケージや Node.js バージョン等の設定は `.claude-container.d/` で利用側プロジェクトごとに指定でき、本リポジトリ自体は特定プロジェクトに依存しない。

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

各ファイルの役割・実装詳細は README.md の「アーキテクチャ」節を参照。以下はコード変更時に見落としやすい不変条件のみを列挙する。

- **`claude-container`**
  - `compute_project_name()` による `PROJECT_NAME`（basename+sha256先頭8文字）でイメージ名・ビルドステージング先をプロジェクトごとに分離する構造を壊さない。固定パスに戻すと複数プロジェクト交互ビルドで無言の上書きが再発する（2026-07-02）。
  - `-b` 時の build と run は別ステップのまま（fail-closed）。
  - `stage_build_context()` の「`env` がステージング先に存在したら `exit 1`」防御的アサーションを削除しない（`env` はビルド時焼き込み禁止）。
  - GitHub meta 取得はここ1箇所のみで行う（詳細は下記「GitHub meta スナップショット」参照）。
  - ステージング時は `node-version.txt`（詳細は下記「Node.js 任意バージョン導入」参照）も対象に含める。
- **`compose.yml`**
  - IPv6 無効化の `sysctls` と `init-firewall.sh` の `ip6tables` DROP は両方必要（片方だけでは glibc の Happy Eyeballs 経由の間欠停止を防げない、2026-07-02）。
  - `userns_mode: keep-id`・`NET_ADMIN`/`NET_RAW` capability は維持する。
- **`Dockerfile.claude`**
  - `ca-certificates` の HTTP→HTTPS 2段階インストール順序を変えない（debian:stable 未同梱のため。削除しないこと）。
  - `tini` を PID1 に据える構成、および `packages.txt` でなく固定 apt-get レイヤーに置く配置を変えない（プロジェクト側上書きでの消失防止。関連インシデント: `.claude/incidents/2026-07-02_2252_crun-kill-failed-on-session-exit.md`）。
  - `ARG CACHEBUST` はキャッシュ破棄用に `RUN` 内で実際に参照して初めて効く（宣言のみでは無効、2026-06-11）。
  - GitHub meta の検証は下記「GitHub meta スナップショット」参照。
- **`entrypoint.sh`**
  - ファイアウォール適用（fail-closed）→バックグラウンド更新ループ起動（詳細は下記「CDN IP ローテーション追従」参照）→`exec claude` の順序を変えない。
  - PID1 は tini（`Dockerfile.claude` 項目参照）。
- **`init-firewall.sh`**
  - ipset は使わない（rootless podman で `ip_set` カーネルモジュールを autoload できないため素の iptables で代替）。
  - GitHub IP レンジはビルド時スナップショットの読み込みのみ、ランタイムでのライブ取得を追加しない（詳細は下記「GitHub meta スナップショット」参照）。
  - ドメイン IP の追従は下記「CDN IP ローテーション追従」参照。
  - `refresh_domains()` のNXDOMAIN判定（一時的な解決失敗とは区別し、恒久的にドメイン自体が存在しない場合のみ `had_errors` をセットしない）を壊さない — ハードコード済み許可ドメインが恒久的にNXDOMAIN化すると起動そのものがfail-closedで止まり続ける（`statsig.anthropic.com`、2026-07-06）。
- **`packages.txt`** / **`requirements.txt`** / **`allowed-domains.txt`** — claude-container 同梱のデフォルト（フォールバック値）。`node-version.txt` は同梱デフォルトを持たず WARNING も出さない（既存3ファイルとの非対称は既知。経緯は issue #7）。

### Node.js 任意バージョン導入（`node-version.txt`）

詳細は README.md「利用側プロジェクトの設定」節を参照。設計判断: 汎用スクリプト実行フックにせず宣言的ファイルにした（監査対象を無限定にしないため）。

### GitHub meta スナップショット

詳細は README.md「アーキテクチャ」内「GitHub meta スナップショット」節を参照。未認証GitHub APIレート制限回避のため取得は `stage_build_context()` 内1箇所のみ（2026-07-02）。

### CDN IP ローテーション追従

詳細は README.md「アーキテクチャ」節（`init-firewall.sh` の説明内）を参照。世代タグ（`gen=<epoch>`）による差分リフレッシュ構造を壊さない — 起動時1回解決に戻すと CDN の IP ローテーション後に新規接続が全滅する（2026-07-02）。

### プロジェクト固有設定（`.claude-container.d/`）

ビルド時焼き込み設定（`packages.txt`/`requirements.txt`/`allowed-domains.txt`/`node-version.txt`）とランタイム設定（`env`）の区別、フォールバック時のWARNING設計は README.md「利用側プロジェクトの設定」節を参照。秘密情報は `.claude-container.d/`（`env` を含む）にも通さない — 唯一の正規の置き場所はパス参照の独立ホスト側ファイル（例: `GH_TOKEN_FILE`/`GH_TOKEN_SECONDARY_FILE`、README.md「利用側プロジェクトの設定」参照）。

## イメージの変更・永続化

リビルド手順（`CACHEBUST`/`CLAUDE_CODE_VERSION` の扱い、`DISABLE_AUTOUPDATER`、`.build-context/` のクリーンアップ）、コンテナ再起動をまたいで保持される bind mount の一覧、bash_history の `.gitignore` 推奨設定は README.md の「イメージの変更」「コンテナ間の永続化」「利用側プロジェクトの設定」節を参照。

## セキュリティモデル

コンテナ内で Claude は `--dangerously-skip-permissions` で動作するため、ツール使用の確認プロンプトなしに動作する。ガードレールはコンテナ境界であり、Claude はマウントされたワークスペースと `/data` への読み書き権限を全面的に持つ。意図したプロジェクトスコープ外の機密データを含むディレクトリはマウントしないこと。

ネットワーク面は `init-firewall.sh` による deny-by-default のエグレス許可リストで制限される（既定で有効）。認証情報（`~/.claude.json`）やソースが実行時にマウントされるため、悪意ある pip パッケージやプロンプトインジェクションによる外部送信・C2 化を「許可済みエンドポイント以外への通信不可」で封じる。無効化は利用側プロジェクトの `.claude-container.d/env` に `CLAUDE_CONTAINER_NO_FIREWALL=1`。

**残存リスク（許可リストでも防げないもの）:**

- DNS トンネリング: リゾルバ宛 53 番は許可されるため、DNS クエリに載せた exfiltration は原理上可能
- 許可済みサービスの悪用: GitHub 等の許可済みドメイン自体を送信先にされるリスクは残る。また CDN 配下のドメイン（claude.ai 等）は IP を共有するため、同一 CDN エッジ上の他サイトへも IP レベルでは到達できる。`GH_TOKEN_FILE`/`GH_TOKEN_SECONDARY_FILE`（README.md「利用側プロジェクトの設定」参照）を設定した場合はこのリスクが能動的になる: プロンプトインジェクションや悪意あるパッケージがトークンを読み取り、そのスコープ内で GitHub へ書き込める。トークンは2本体制（プライマリ `claude-container-self`＝本リポジトリ限定で Issues + Pull requests RW + Contents Read、セカンダリ `issues-all`＝Issues RW のみで対象リポジトリは fine-grained PAT の設定次第）で、緩和策は各トークンの fine-grained PAT スコープ最小化（対象リポジトリ限定・短期限）。**セカンダリの実際の対象リポジトリはPAT設定側で管理され本ファイルには列挙しない**（列挙するとPAT設定変更のたびにここも直す必要が生じるため）。対象範囲の正本はPAT設定（fine-grained PAT の Repository access）側にあると理解して運用する（個別リポジトリの到達可否確認手順は README.md「利用側プロジェクトの設定」節参照）
  - **push/マージはコンテナ内PATの権限外**: PRマージ（`Contents: write` が必要）は両トークンとも持たないため、悪用されても push・マージ・Release作成には至らない
  - **Pull requests: write による攻撃対象面の拡大**: 他者PRのタイトル・本文改変、レビュー依頼スパム、妨害目的のクローズが可能になる。Issue操作と同種だが一段重い
  - **auto-merge 経由の境界迂回に注意**: PRレビュー承認（`gh pr review --approve`）は `Contents: write` なしで実行できる。claude-container リポジトリで auto-merge が有効な状態だと、コンテナ内トークンによる承認だけで required review 条件が満たされ GitHub 側が自動マージしてしまう可能性がある。対策として claude-container の auto-merge は無効を維持し、**コンテナ内で `gh pr review --approve` を自律実行しない**（push同様、人間の確認を経ずにマージ条件を満たす行為として扱う。PreToolUse hook で機構的にブロック済み — hook の適用範囲・限界と可否早見表は README.md「何ができて何ができないか」節参照）
- IP ローテーション: 許可ドメインの IP は `init-firewall.sh` の `REFRESH_INTERVAL_SECONDS` 間隔のバックグラウンド差分リフレッシュ（上記 `init-firewall.sh` 節参照）で追従するが、ローテーション直後からリフレッシュが反映されるまでの数十秒（取りこぼし込みで最大 `REFRESH_INTERVAL_SECONDS` の2倍程度）は新規接続が失敗しうる。コンテナ再起動が必須だった以前と比べれば大幅に縮小されるが、ゼロにはできない。GitHub IP レンジはビルド時スナップショット固定のため同様に古くなりうる（`-b` のたびに再取得を試み、失敗時は前回ステージング分を再利用）
- ビルド時ネットワークは無制限: `pip3 install` は setup.py / build backend の任意コードをビルド時に実行しうる。ただし build context に秘密情報は含まれず、イメージへ焼き込まれた悪性コードの実行時通信は上記 firewall が封じる

## 変更後の確認

テストスイートはない。`./lint.sh` が集約 lint target（`bash -n`・`shellcheck`・`podman compose config` を一括実行。詳細は README.md の「変更後の確認」節を参照）。対象の bash スクリプトはリポジトリ内ファイル（gitignore 対象を除く追跡済み・未追跡）の shebang から動的に検出するため、スクリプトを追加/削除しても対象リストの手動同期は不要。編集時は PostToolUse hook（`.claude/hooks/lint-posttool.sh`）が該当ファイルの shellcheck 違反を自動提示する。提示された違反はそのターン内で解消する。

---

## 開発ガイドライン

### コア原則

#### 1. 計画を優先する
Plan Modeへの切り替え基準に該当する作業（グローバル CLAUDE.md 参照）は `.claude/plans/<slug>.md` に計画をまとめ、承認を得てから実装を始める（詳細は「計画ファイル・handover の扱い」節参照）。それ以外の軽微な実装タスクは GitHub issue として登録する（「タスク管理の流れ」節参照）。

#### 2. サブエージェントを活用
使いどころ・モデル選択・並列利用の基準はグローバル CLAUDE.md（「モデルを使い分ける」「サブエージェントの並列利用」節）に従う。
1つのサブエージェントには1つのタスクを明確に割り当てる。

#### 3. 学びを活かす
指摘やフィードバックを受けたときは、`.claude/lessons.md` にそのポイントを簡潔に記録する。

#### 4. バグ修正の対応
バグ報告はログ・エラー・失敗テストを確認し、必要最小限の変更で自律的に修正する（質問は最小限に）。
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

### タスク管理の流れ（GitHub Issues）

課題管理はグローバル CLAUDE.md「GitHub Issues による課題管理（opt-in）」のフローに従い、
本リポジトリ（`jj1xgo/claude-container`）の GitHub Issues をトラッカーとして使う。本リポジトリ固有の事項:

- 起票は `gh issue create` で行い、相応しいラベル（下記「ラベル体系」＋グローバル共通ラベル）を付与する
- クローズは `gh issue close` を正とする（コミットの `fixes #N` はユーザーの push 時点まで閉じないため使わない）
- **他リポジトリ（findsummits・sotlas-frontend 等）へ起票したら**、`.claude/filed-issues.txt` に
  `owner/repo#番号` の形式で追記し同ターンでコミットする（session-start hook が状態・最終コメントを
  自動確認する対象になる）。クローズを確認したら該当行を削除しコミットする。セカンダリトークン
  限定の private リポジトリ（`dotclaude-ops` 等）宛も同様に記録する（hook がセカンダリトークンで
  確認する。issue #19）

**ラベル体系**: GitHub デフォルトラベル（`bug`・`enhancement`・`documentation`・`question` 等）に加えて以下を使う。

- `received` — 利用側プロジェクトからの受付（下記「issue 受付フロー」参照）

### 利用側プロジェクトからの issue 受付フロー

利用側プロジェクト（例: findsummits）が、環境起因（コンテナ・ファイアウォール・ビルド・イメージ等）の
問題・要望を本リポジトリへ GitHub issue で起票することがある。フロー・クローズの役割分担・AI 署名は
グローバル CLAUDE.md「GitHub Issues による課題管理（opt-in）」に従う。本リポジトリ固有の要件は以下のとおり。

- **受領時のラベル付与**: `received` ＋種別ラベル（`bug`・`enhancement` 等）を付与する
- **対応完了コメントにはリビルド要否を明記する**: ビルド時焼き込み設定・イメージ変更を伴う場合は
  リビルド必須である旨を書く
- **注記**: session-start hook が本リポジトリ宛の open issue を自動確認し注入する
  （フェイルソフト。`gh` 不在・API 失敗時は一行メッセージのみでスキップする）

### 計画ファイル・handover の扱い

- **plan ファイルは `.claude/plans/<slug>.md`**（`plansDirectory`設定により自動生成、承認後の`mv`は不要）。万一 `~/.claude/plans/` に生成されたら設定が効いていない異常のサインなので報告した上で`mv`する。放棄された未追跡下書きは気づいた時点で削除してよい
- **plan ファイル内のリポジトリ内ファイル参照はコード表記（バッククォート）にする**: 相対リンクは閲覧環境で解決されず broken-link になるため
- **計画の各タスクに実行モデルを明記する**: グローバル CLAUDE.md「モデルを使い分ける」節参照
- **計画ファイルのコミット・削除タイミング**: グローバル CLAUDE.md「1. 計画を優先する」節参照

### バージョン管理（SemVer タグ運用）

判定基準・タグ形式は README.md「バージョニング」節を参照。

- **提案のトリガー**: 利用者から見えるインターフェース（CLI引数・`.claude-container.d/`の設定形式・デフォルト挙動）が変わる一連の変更をコミットし終えたら、SemVer判定に基づく番号案と根拠を添えてタグ付与を**提案**する（ユーザー承認後に作成、自動作成しない）。内部品質・docs・hook調整のみでは提案しない
- **タグメッセージ**: 見出し1行＋空行＋箇条書きが基本形。日本語ブロック→`---`→Englishブロックの順で日英併記する（README.md と異なり言語見出しは付けない）。CHANGELOGファイルは作成しない。ビルド時焼き込み設定・イメージ内容の変更を伴う場合はリビルド要否を明記する
- **push はユーザーがホスト側で実行**: コンテナ内PAT（プライマリ `claude-container-self` を含む）は `Contents: Read` までで `Contents: write` を持たないためpush不可。タグ作成後、`git push origin vX.Y.Z` をホスト側実行コマンドとして提示する
- **GitHub Release作成**: push後に `gh release create <tag> --notes-from-tag --title <tag>` を実行し、タグメッセージをそのまま流用したGitHub Release（タイトル＝タグ名、本文＝タグメッセージそのもの）を作成する。コンテナ内PATは `Contents: write` を持たないため権限エラー（403）になる想定で、その場合はpushと同様にホスト側実行コマンドとして提示する。逆にコンテナ内で成功した場合は想定スコープとの乖離であり、黙って利用継続せずユーザーに報告する
- **既存タグメッセージの書き換え**: タグが指すコミット自体は変えず（`git rev-parse <tag>^{}` の一致を確認）タグオブジェクトのみ再作成する。pushは同じくユーザーがホスト側で実行。対応するGitHub Releaseの notes も、タグ本文（`git tag -l --format='%(contents)' <tag>`）を一時ファイルへ書き出し `gh release edit <tag> --notes-file <file>` で同期する（`gh release edit` には `--notes-from-tag` が無い）。同期しないとタグとReleaseの内容が乖離する

### ルールと制約
- **Git**：確認なしに自動コミット・自動pushはしない（形式はグローバル CLAUDE.md 参照）。
