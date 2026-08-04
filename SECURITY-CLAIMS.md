# セキュリティ主張の詳細（試作）

> **この文書は試作段階です**。README.md「セキュリティモデル」節（13ブロック）のうち2件だけを
> 移設した状態で、項目立て・README側の残し方を確認するための実験です。全ブロックの移設が
> 決まったものではありません。

---

## C-1

**対象**: capability 剥奪（`compose.yml` の `cap_add` 対策）

**成立条件・脅威モデル**: このガードレール（エグレスファイアウォール）が機能するのは、Claude（および
その子プロセス）がこの許可リスト自体を書き換えられないことが前提になる。`compose.yml` の `cap_add`
（`NET_ADMIN`/`NET_RAW`）は rootless podman では非root ユーザーの ambient set にも入り全子プロセスへ
継承されるため、対策しなければ Claude が sudo を介さず直接 iptables を操作できてしまう（`CAP_NET_RAW`
は `AF_PACKET` 経由で netfilter 自体を迂回することもできる）。

**保証**: `Dockerfile.claude` の `ENTRYPOINT` でコンテナ起動時にこれらの capability を剥奪しており、
iptables の実消費者は `sudo` 経由で root になった `init-firewall.sh` のみに限定される。

**限界・非対象**（2件）:
1. capability の bounding set 自体は削除できない（削除には `CAP_SETPCAP` が必要で、これも与えていない）
   ため、プロジェクトが `.claude-container.d/packages.txt` で file capabilities 付きバイナリ
   （`iputils-ping`・`wireshark` 等）を追加導入すると、そのバイナリ固有の機能に限って capability が
   復活しうる（同梱デフォルトの `packages.txt` にはそのようなバイナリは含まれない）
2. ホスト側から `podman exec` で入るプロセスは `Dockerfile.claude` の `ENTRYPOINT` を経由しないため、
   この制限の対象外である

**根拠**: `Dockerfile.claude` の `ENTRYPOINT`（`setpriv --ambient-caps=-all --inh-caps=-all` ラップ）。

**再確認契機**: 静的（`Dockerfile.claude`・`compose.yml` の変更時に再確認）。

---

## C-2

**対象**: claude-in-chrome 連携（`jj1xgo/claude-container#32`）

**主張**: claude-in-chrome 連携（`mcp__claude-in-chrome__*`）はファイアウォールでは**原理的に遮断できない**。

**理由（保証なし）**: Claude Code 組み込みの claude-in-chrome 連携は `.mcp.json` を介さないネイティブ
機能のため MCP 監査ゲートの対象外であり、コンテナ内から到達・実行可能である。実機調査では、接続時の
新規 TCP 接続はいずれも `claude.ai`/`api.anthropic.com` 系の443番のみで、これは Claude Code 自体の
動作に必須の許可ドメインである——つまりこの経路はエグレスファイアウォールが遮断しようとしている対象
そのものに相乗りしており、許可ドメインを1つも削らずに塞ぐことはできない。

**検知の性質（強制ではなく事後通知）**: ホスト側に表示されるのは Chrome 標準の `chrome.debugger` 通知
（「"claude"がこのブラウザのデバッグを開始しました」）のみで、これは事前承認ではなく**事後通知＋任意
キャンセル**（人間が画面を注視していなければ素通りする fail-open）である。

**限界・非対象**: コンテナ内のコード（プロンプトインジェクションを受けた可能性のあるものを含む）が、
ホストの実ブラウザ（実ログインセッション込み）を人間の事前承認なしに操作しうる——これは「ガードレールは
コンテナ境界」という前提の**外側**にある残存リスクである。

**緩和策（ソフトゲート）**: `.claude/settings.json` の `permissions.deny` に `mcp__claude-in-chrome__*`
を書く方法があるが、他の MCP 向け `permissions.deny` 同様**コンテナ内から書き換え可能なソフトゲート**
にすぎない。

**根拠**: `jj1xgo/claude-container#32`（実機調査の記録）。

**再確認契機**: 静的（claude-in-chrome 連携の実装変更時に再確認）。
