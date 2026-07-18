# AgentNotch

Mac のノッチに常駐する AI コーディングエージェント監視アプリ（Vibe Island 風、Nook デザイン）。
Claude Code / Codex / Antigravity のセッションをノッチから監視し、Claude Code の権限承認をノッチ上の Allow/Deny で応答できる。

## ビルド & 起動

```bash
bash scripts/build-app.sh     # SwiftPM release ビルド → build/AgentNotch.app
open build/AgentNotch.app
```

- Xcode 不要（CommandLineTools の Swift のみ）。
- ~/Documents は iCloud 同期のため、ビルド成果物は `~/.cache/agent-notch/build` に置く（build-app.sh が設定済み）。`swift build` をプロジェクト直下の `.build` で走らせないこと（SQLite disk I/O error になる）。

## フック連携のインストール

```bash
bash scripts/install-hooks.sh
```

- bridge を `~/.agent-notch/bin/agent-notch-bridge` にコピーし、`~/.claude/settings.json` の hooks（Notification / PermissionRequest / Stop / SessionStart / SessionEnd）を登録する。実行前に settings.json を自動バックアップ。
- Codex は `~/.codex/config.toml` の `notify` → `~/.agent-notch/bin/codex-notify`（既存 Computer Use クライアントと多重配送するラッパー）。

## アーキテクチャ

```
Claude Code CLI ─ hooks ──▶ agent-notch-bridge ─┐ UNIX socket
                └ ~/.claude/projects/*.jsonl ───┤ (~/.agent-notch/run/agent-notch.sock)
Codex ────────── notify (codex-notify) ─────────┼──▶ AgentNotch.app
                └ ~/.codex/sessions rollout ────┤
Antigravity ──── conversations/ mtime ──────────┘
```

- PermissionRequest はブロッキング hook: bridge がソケットで承認要求を送り、ノッチの Allow/Deny 押下で decision JSON を hook stdout に返す。応答不能時は無出力 exit 0 で通常プロンプトにフォールバック。
- デバッグ: 受信イベントは `~/.agent-notch/events.log` に追記される。

## 表示挙動

- Finderを含む通常のSpaceでは最小ノッチを常時表示する。
- Finder以外のアプリが真のフルスクリーンになった場合だけ隠し、画面上端中央への300ms滞留で再表示する。
- 200msのhoverでNookを展開し、離脱時は140ms後に縮小する。承認待ち中は自動で閉じない。
- 承認要求・イベント時は自動で表示+展開する。

## UI

- Nook: Agents / Media / Today / Systemを1ページ1主要機能で切り替え。
- Tray: ローカルファイルの一時ShelfとAirDrop / Compress / Copy Path / AI Attach操作。
- Agent: 複数セッション、状態、現在の処理、Pause / Resume / Stop / Terminal。
- Approval / Plan Review / Agent QuestionはNook内のインライン操作面として表示。

## 今後の接続作業

- Pause / Resume / Stopの実エージェント制御チャネル
- Claude / Codexのusage実値
- Plan Review / Agent Questionのhookイベント配送
- OSのMedia Remote・カレンダー・バッテリー・バックグラウンドタスク実データ
