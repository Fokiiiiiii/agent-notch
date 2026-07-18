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
- 共通CLIを `~/.local/bin/agent-notch` に配置する（PATHに`~/.local/bin`が必要）。
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

## 共通CLI

```bash
agent-notch ping
agent-notch show                 # Nookを固定表示
agent-notch hide
agent-notch toggle

agent-notch session start \
  --id build-123 --agent codex \
  --title "Build API" --message "Running tests" --cwd "$PWD"
agent-notch session update --id build-123 --agent codex --message "18 / 24 tests"
agent-notch session attention --id build-123 --agent codex --message "Approval required"
agent-notch session done --id build-123 --agent codex --message "All tests passed"
agent-notch session fail --id build-123 --agent codex --message "2 tests failed"
agent-notch session remove --id build-123 --agent codex

# 対応CLIを自動検出し、バックアップ付きでnative hookを設定
agent-notch setup
agent-notch setup --dry-run
agent-notch setup --all          # 未インストールCLI用の設定経路も作成

# native hookがない／不安定なCLIは共通ラッパーで追跡
agent-notch run --agent cursor -- cursor-agent
cursor-notch                     # 上記の短縮ラッパー
```

CLIは`~/.agent-notch/run/agent-notch.sock`だけを使用し、外部通信やテレメトリは行わない。`--id`を省略した場合はagentとcwdから安定したIDを生成する。

### Agent連携

| Agent | 接続方法 |
| --- | --- |
| Claude Code | native hooks + transcript |
| Codex | notify + rollout logs |
| Gemini CLI | native hooks (`~/.gemini/settings.json`) |
| GitHub Copilot CLI | native user hooks (`~/.copilot/hooks/agent-notch.json`) |
| OpenCode | native global plugin (`~/.config/opencode/plugins/agent-notch.js`) |
| Aider | native notifications command |
| Cursor Agent | `cursor-notch` / `agent-notch run` |
| Goose | `goose-notch` / `agent-notch run` |
| Antigravity | conversation watcher |

自動設定は管理対象の設定だけを置換し、既存ファイルには`backup.agent-notch.<timestamp>`を作る。`gemini-notch`、`copilot-notch`、`cursor-notch`、`opencode-notch`、`aider-notch`、`goose-notch`は常に生成される。

## 表示挙動

- Finderを含む通常のSpaceでは最小ノッチを常時表示する。
- Finder以外のアプリが真のフルスクリーンになった場合だけ隠し、画面上端中央への300ms滞留で再表示する。
- クリックでNookを確実に開閉する。hoverは部品の反応に限定し、承認待ち中は自動で閉じない。
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
