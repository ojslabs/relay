#!/usr/bin/env bash
# PostToolUse hook: the relay's context sensor.
# Computes exact context fill from the session transcript and, past the
# threshold, tells Claude to hand off. Fires once at the threshold and once
# more 10 points later; silent otherwise, so it never spams the session.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

read_hook_input
[ -n "${HOOK_CWD:-}" ] && cd "$HOOK_CWD" 2>/dev/null
relay_active || exit 0
[ -n "${HOOK_TRANSCRIPT:-}" ] || exit 0

threshold="$(json_get "$RELAY_DIR/state.json" threshold)"
threshold="${threshold:-$RELAY_DEFAULT_THRESHOLD}"
window_override="$(json_get "$RELAY_DIR/state.json" window)"
[ -n "$window_override" ] && RELAY_CONTEXT_WINDOW="$window_override"

fill=$(context_fill_pct "$HOOK_TRANSCRIPT")
[ "$fill" -ge "$threshold" ] 2>/dev/null || exit 0

armed_file="$RELAY_DIR/handoff-armed"
last_fired=0
[ -f "$armed_file" ] && last_fired=$(cat "$armed_file" 2>/dev/null || echo 0)

if [ "$last_fired" -eq 0 ] 2>/dev/null; then
  echo "$fill" > "$armed_file"
  hook_block "Relay: context is at ${fill}% of the window (threshold ${threshold}%). Hand off now: stop starting new work, bring .relay/baton.md fully up to date (every section, including the failed-approaches ledger and the drift check), then end the leg. If this leg has not completed any unit of work yet and one small unit clearly fits, finish exactly that one unit first. If the mission is already complete with evidence, write .relay/DONE.md instead."
elif [ "$fill" -ge $(( last_fired + 10 )) ] 2>/dev/null; then
  echo "$fill" > "$armed_file"
  hook_block "Relay: context is now at ${fill}%. Finish the handoff immediately: update .relay/baton.md and end the leg. Every further tool call degrades the handoff."
fi
exit 0
