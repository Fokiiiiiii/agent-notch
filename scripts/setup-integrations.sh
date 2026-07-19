#!/bin/bash
set -euo pipefail

BACKUP_KEEP="${AGENT_NOTCH_BACKUP_KEEP:-5}"

prune_backups() {
  local target="$1" keep="${2:-5}"
  ls -1t "${target}".backup.agent-notch.* 2>/dev/null | tail -n +"$((keep + 1))" | xargs rm -- 2>/dev/null
  return 0
}

ALL=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --all) ALL=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "agent-notch setup: unknown option: $arg" >&2; exit 2 ;;
  esac
done

BIN_DIR="$HOME/.agent-notch/bin"
LOCAL_BIN="$HOME/.local/bin"
BRIDGE="$BIN_DIR/agent-notch-bridge"
CLI="$BIN_DIR/agent-notch"
STAMP="$(date +%Y%m%dT%H%M%S)"

if [[ ! -x "$BRIDGE" || ! -x "$CLI" ]]; then
  echo "agent-notch setup: install AgentNotch hooks first" >&2
  exit 1
fi

detected() {
  command -v "$1" >/dev/null 2>&1 || [[ "$ALL" == 1 ]]
}

backup() {
  [[ -f "$1" ]] || return 0
  cp "$1" "$1.backup.agent-notch.$STAMP"
  prune_backups "$1" "$BACKUP_KEEP"
}

write_wrapper() {
  local name="$1" agent="$2" command="$3"
  [[ "$DRY_RUN" == 0 ]] || { echo "would install: $LOCAL_BIN/$name"; return; }
  mkdir -p "$LOCAL_BIN"
  printf '#!/bin/sh\nexec "%s" run --agent "%s" -- "%s" "$@"\n' "$CLI" "$agent" "$command" > "$LOCAL_BIN/$name"
  chmod +x "$LOCAL_BIN/$name"
}

configure_gemini() {
  local settings="$HOME/.gemini/settings.json"
  [[ -f "$settings" || "$ALL" == 1 ]] || return 0
  [[ "$DRY_RUN" == 0 ]] || { echo "would configure: Gemini CLI ($settings)"; return; }
  mkdir -p "$(dirname "$settings")"
  [[ -f "$settings" ]] || printf '{}\n' > "$settings"
  backup "$settings"
  python3 - "$settings" "$BRIDGE" <<'PY'
import json, sys
path, bridge = sys.argv[1:]
with open(path) as f:
    settings = json.load(f)
hooks = settings.setdefault("hooks", {})
cmd = f'"{bridge}" --agent-hook gemini'
# NOTE: イベント名（特に "AfterAgent"）はGemini CLI公式ドキュメントで未検証。
# Claude Code由来の命名を流用した可能性がある。
for event in ("SessionStart", "AfterAgent", "Notification", "SessionEnd"):
    groups = hooks.setdefault(event, [])
    for group in groups:
        group["hooks"] = [h for h in group.get("hooks", []) if "--agent-hook gemini" not in h.get("command", "")]
    groups[:] = [g for g in groups if g.get("hooks")]
    groups.append({"hooks": [{"type": "command", "command": cmd, "name": "AgentNotch", "timeout": 5000}]})
with open(path, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
  echo "configured: Gemini CLI"
}

configure_copilot() {
  detected copilot || return 0
  local file="$HOME/.copilot/hooks/agent-notch.json"
  [[ "$DRY_RUN" == 0 ]] || { echo "would configure: GitHub Copilot CLI ($file)"; return; }
  mkdir -p "$(dirname "$file")"
  backup "$file"
  python3 - "$file" "$BRIDGE" <<'PY'
import json, sys
path, bridge = sys.argv[1:]
cmd = f'"{bridge}" --agent-hook copilot'
item = {"type": "command", "bash": cmd, "timeoutSec": 5}
# NOTE: イベント名（sessionStart / agentStop / errorOccurred / notification）は
# GitHub Copilot CLI公式ドキュメントで未検証。Claude Code由来の命名を流用した可能性がある。
data = {"version": 1, "hooks": {
    "sessionStart": [item],
    "agentStop": [item],
    "errorOccurred": [item],
    "notification": [item],
}}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  echo "configured: GitHub Copilot CLI"
}

configure_opencode() {
  detected opencode || return 0
  local file="$HOME/.config/opencode/plugins/agent-notch.js"
  [[ "$DRY_RUN" == 0 ]] || { echo "would configure: OpenCode ($file)"; return; }
  mkdir -p "$(dirname "$file")"
  backup "$file"
  cat > "$file" <<'JS'
export const AgentNotchPlugin = async ({ directory }) => ({
  event: async ({ event }) => {
    const map = {
      "session.created": "start",
      "session.updated": "update",
      "session.status": "update",
      "permission.asked": "attention",
      "session.idle": "done",
      "session.error": "fail",
      "session.deleted": "remove",
    }
    const action = map[event.type]
    if (!action) return
    const info = event.properties?.info ?? event.properties ?? {}
    const id = info.id ?? info.sessionID ?? `opencode:${directory}`
    const message = info.title ?? info.status ?? event.type
    Bun.spawn([`${process.env.HOME}/.agent-notch/bin/agent-notch`, "session", action,
      "--id", String(id), "--agent", "opencode", "--title", "OpenCode",
      "--message", String(message), "--cwd", directory], { stdout: "ignore", stderr: "ignore" })
  },
})
JS
  echo "configured: OpenCode"
}

configure_aider() {
  detected aider || return 0
  local file="$HOME/.aider.conf.yml"
  [[ "$DRY_RUN" == 0 ]] || { echo "would configure: Aider ($file)"; return; }
  [[ -f "$file" ]] || : > "$file"
  backup "$file"
  python3 - "$file" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
text = re.sub(r'(?m)^notifications:\s*.*\n?', '', text)
text = re.sub(r'(?m)^notifications-command:\s*.*\n?', '', text)
text = text.rstrip() + "\nnotifications: true\n"
text += "notifications-command: '$HOME/.agent-notch/bin/agent-notch session attention --agent aider --id \"aider:$PWD\" --title \"Aider\" --message \"Aider is waiting\" --cwd \"$PWD\"'\n"
open(path, 'w').write(text)
PY
  echo "configured: Aider"
}

configure_gemini
configure_copilot
configure_opencode
configure_aider

write_wrapper gemini-notch gemini gemini
write_wrapper copilot-notch copilot copilot
write_wrapper cursor-notch cursor cursor-agent
write_wrapper opencode-notch opencode opencode
write_wrapper aider-notch aider aider
write_wrapper goose-notch goose goose

echo "AgentNotch integrations ready. Native hooks are enabled where supported; use *-notch wrappers otherwise."
