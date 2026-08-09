#!/usr/bin/env bash
# SessionStart hook: hands the baton to every new session in this project.
# Injects the mission and baton as context, so even a session started by hand
# (a plain `claude` in the directory) picks the relay up instead of drifting.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

read_hook_input
[ -n "${HOOK_CWD:-}" ] && cd "$HOOK_CWD" 2>/dev/null
relay_active || exit 0

# New leg begins: reset the per-leg handoff trigger.
rm -f "$RELAY_DIR/handoff-armed" 2>/dev/null

mission=""
baton=""
[ -f "$RELAY_DIR/mission.md" ] && mission="$(cat "$RELAY_DIR/mission.md")"
[ -f "$RELAY_DIR/baton.md" ] && baton="$(cat "$RELAY_DIR/baton.md")"

context="An active relay is running in this project. You are its next leg.

The mission (fixed, never edit .relay/mission.md):
---
${mission}
---

The baton from previous legs (.relay/baton.md):
---
${baton}
---

Continue from the baton's next steps. Honor its failed-approaches list. Keep the baton current as you work; a hook will tell you when context fill requires a handoff."

if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$context" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
else
  python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":sys.argv[1]}}))' "$context"
fi
exit 0
