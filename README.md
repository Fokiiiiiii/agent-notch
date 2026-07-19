# AgentNotch

Mac のノッチに常駐する AI コーディングエージェント監視アプリ（Vibe Island 風、Nook デザイン）。
Claude Code / Codex / Antigravity のセッションをノッチから監視し、Claude CodeとCodexの質問・権限承認へノッチ上で応答できる。

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

- bridge を `~/.agent-notch/bin/agent-notch-bridge` にコピーし、Claude Codeの`AskUserQuestion`／承認hookと、Codexの`request_user_input`／承認hookを登録する。設定ファイルは実行前に自動バックアップ。
- 共通CLIを `~/.local/bin/agent-notch` に配置する（PATHに`~/.local/bin`が必要）。
- Codex は `~/.codex/hooks.json` の `PreToolUse`(`request_user_input`) / `PermissionRequest` フックを通じて bridge に接続する（`install-hooks.sh` が自動登録）。

## アーキテクチャ

```
Claude Code CLI ─ hooks ──▶ agent-notch-bridge ─┐ UNIX socket
                └ ~/.claude/projects/*.jsonl ───┤ (~/.agent-notch/run/agent-notch.sock)
Codex ─ hooks ───────────────────────────────────┼──▶ AgentNotch.app
                └ ~/.codex/sessions rollout ────┤
Antigravity ──── conversations/ mtime ──────────┘
```

- PermissionRequest はブロッキング hook: bridge がソケットで承認要求を送り、ノッチの Allow/Deny 押下で decision JSON を hook stdout に返す。応答不能時は無出力 exit 0 で通常プロンプトにフォールバック。
- デバッグ: 受信イベントは `~/.agent-notch/events.log` に追記される。

## 共通CLI

ノッチ搭載Macをお持ちの方は`agent-notch ping`を実行し、`screenInfo`フィールドの値を報告してください。

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

# native hookや独自プラグインからブロッキング操作を取り込む共通口
agent-notch question --agent gemini --prompt "Deploy target?" \
  --option Production --option Staging --option "Local only"
agent-notch permission --agent opencode --tool Bash --summary "npm run deploy"
agent-notch plan --agent codex --title "Auth refactor" --summary "Extract validation; add tests"
```

CLIは`~/.agent-notch/run/agent-notch.sock`だけを使用し、外部通信やテレメトリは行わない。`--id`を省略した場合はagentとcwdから安定したIDを生成する。

### Agent連携

| Agent | 接続方法 |
| --- | --- |
| Claude Code | native hooks + transcript |
| Codex | native hooks (`request_user_input` / `PermissionRequest`) + rollout logs |
| Gemini CLI ※ | native hooks (`~/.gemini/settings.json`) |
| GitHub Copilot CLI ※ | native user hooks (`~/.copilot/hooks/agent-notch.json`) |
| OpenCode | native global plugin (`~/.config/opencode/plugins/agent-notch.js`) |
| Aider | native notifications command |
| Cursor Agent | `cursor-notch` / `agent-notch run` |
| Goose | `goose-notch` / `agent-notch run` |
| Antigravity | conversation watcher |

自動設定は管理対象の設定だけを置換し、既存ファイルには`backup.agent-notch.<timestamp>`を作る。`gemini-notch`、`copilot-notch`、`cursor-notch`、`opencode-notch`、`aider-notch`、`goose-notch`は常に生成される。

※ フックイベント名は現時点で公式ドキュメントに基づく検証が未完了です。動作しない場合は Issue で報告してください。

## 表示挙動

- Finderを含む通常のSpaceでは最小ノッチを常時表示する。
- Finder以外のアプリが真のフルスクリーンになった場合だけ隠し、画面上端中央への300ms滞留で再表示する。
- クリックでNookを確実に開閉する。hoverは部品の反応に限定し、承認待ち中は自動で閉じない。
- 承認要求・質問・失敗時はCompact通知だけを表示し、クリック後に操作画面を展開する。操作中のページは奪わない。

## UI

- Nook: Agents / Media / Today / Systemを1ページ1主要機能で切り替え。
- Media: macOSの現在の再生セッションを自動検出。再生中はジャケット色に連動するCompact波形を表示し、250msホバーでノッチを横へ広げて曲名をプレビュー、クリック後に進捗と再生操作を表示する。
- Tray: NSPanelネイティブのファイルDropとファイルピッカーを備えた一時Shelf。ファイル追加時はTrayを自動表示し、空にするまでポインタ移動や外側操作では閉じない。選択ファイルを開く / Finder表示 / AirDrop / Compress / Copy Path / AI用コピーを実行できる。
- Agent: 複数セッション、状態、現在の処理、Terminal復帰を表示。`agent-notch run`管理下のプロセスだけPause / Resume / Stopを実行できる。
- Usage: [CodexBar](https://github.com/steipete/CodexBar)のprovider正規化JSONを利用し、Codex / Claude等の実測値または取得エラーを表示する（CodexBar未導入時は`Unavailable`）。
- Approval / Plan Review / Agent QuestionはNook内のブロッキング操作面として表示し、回答を呼び出し元へ返す。
- System: バッテリー・メモリ・ストレージに加え、Xcode / Git / Docker / Downloadの実行中プロセスだけをBackground Activityとして表示する。

## Third-party components

- `Vendor/MediaRemoteAdapter`: BSD 3-Clause License. macOSの現在の再生セッション取得・操作に使用。ライセンス全文は同ディレクトリの`LICENSE`に収録。
