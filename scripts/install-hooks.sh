#!/bin/bash
# AgentNotch hooks installer:
#  - bridge を ~/.agent-notch/bin/ にコピー
#  - Claude Code / Codex の質問・承認 hooks を AgentNotch bridge に接続
#  - statusLine には触れない
# 冪等。実行前に settings.json をタイムスタンプ付きでバックアップする。
set -euo pipefail
cd "$(dirname "$0")/.."

BIN_DIR="$HOME/.agent-notch/bin"
mkdir -p "$BIN_DIR"
cp build/AgentNotch.app/Contents/MacOS/agent-notch-bridge "$BIN_DIR/agent-notch-bridge"
cp build/AgentNotch.app/Contents/MacOS/agent-notch-bridge "$BIN_DIR/agent-notch"
cp build/AgentNotch.app/Contents/Resources/setup-integrations "$BIN_DIR/setup-integrations"
chmod +x "$BIN_DIR/agent-notch-bridge" "$BIN_DIR/agent-notch"
chmod +x "$BIN_DIR/setup-integrations"
mkdir -p "$HOME/.local/bin"
ln -sfn "$BIN_DIR/agent-notch" "$HOME/.local/bin/agent-notch"

SETTINGS="$HOME/.claude/settings.json"
BACKUP="$SETTINGS.backup.agent-notch.$(date +%Y%m%dT%H%M%S)"
cp "$SETTINGS" "$BACKUP"
echo "backup: $BACKUP"

python3 - "$SETTINGS" <<'EOF'
import json, sys

path = sys.argv[1]
with open(path) as f:
    settings = json.load(f)

CMD = '/bin/sh -c \'[ -x "$HOME/.agent-notch/bin/agent-notch-bridge" ] && AGENT_NOTCH_AGENT=claude exec "$HOME/.agent-notch/bin/agent-notch-bridge"; exit 0\''

def entry(timeout=None):
    hook = {"type": "command", "command": CMD}
    if timeout is not None:
        hook["timeout"] = timeout
    return hook

hooks = settings.get("hooks", {})

# vibe-island の hooks を全イベントから除去
for event in list(hooks.keys()):
    kept = []
    for matcher in hooks[event]:
        matcher["hooks"] = [h for h in matcher.get("hooks", [])
                            if "vibe-island" not in h.get("command", "")
                            and "agent-notch" not in h.get("command", "")]
        if matcher["hooks"]:
            kept.append(matcher)
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]

# AgentNotch bridge を登録
def add(event, matcher, timeout=None):
    block = {"hooks": [entry(timeout)]}
    if matcher is not None:
        block["matcher"] = matcher
    hooks.setdefault(event, []).append(block)

add("Notification", "*")
add("PermissionRequest", "*", timeout=86400)
add("PreToolUse", "AskUserQuestion", timeout=86400)
add("Stop", None)
add("SessionStart", None)
add("SessionEnd", None)

settings["hooks"] = hooks
with open(path, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")
print("hooks installed:", ", ".join(sorted(hooks.keys())))
EOF

CODEX_HOOKS="$HOME/.codex/hooks.json"
mkdir -p "$(dirname "$CODEX_HOOKS")"
[[ -f "$CODEX_HOOKS" ]] || printf '{"hooks":{}}\n' > "$CODEX_HOOKS"
CODEX_BACKUP="$CODEX_HOOKS.backup.agent-notch.$(date +%Y%m%dT%H%M%S)"
cp "$CODEX_HOOKS" "$CODEX_BACKUP"
echo "backup: $CODEX_BACKUP"

python3 - "$CODEX_HOOKS" <<'EOF'
import json, sys

path = sys.argv[1]
with open(path) as f:
    settings = json.load(f)

cmd = '/bin/sh -c \'[ -x "$HOME/.agent-notch/bin/agent-notch-bridge" ] && AGENT_NOTCH_AGENT=codex exec "$HOME/.agent-notch/bin/agent-notch-bridge"; exit 0\''
hooks = settings.setdefault("hooks", {})

for event in list(hooks):
    kept = []
    for group in hooks[event]:
        group["hooks"] = [item for item in group.get("hooks", [])
                          if "vibe-island" not in item.get("command", "")
                          and "agent-notch" not in item.get("command", "")]
        if group["hooks"]:
            kept.append(group)
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]

def add(event, matcher):
    hooks.setdefault(event, []).append({
        "matcher": matcher,
        "hooks": [{
            "type": "command",
            "command": cmd,
            "timeout": 86400,
            "statusMessage": "Waiting in AgentNotch",
        }],
    })

add("PreToolUse", "^request_user_input$")
add("PermissionRequest", "*")

with open(path, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")
print("Codex hooks installed: PermissionRequest, request_user_input")
EOF
