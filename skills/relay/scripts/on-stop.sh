#!/usr/bin/env bash
# Stop hook: the relay's handoff gate.
# A leg may end only after it has either updated the baton this leg or
# declared verified completion. Without this gate, a session can die silently
# and the next leg inherits a stale baton, which is how drift starts.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

read_hook_input
[ -n "${HOOK_CWD:-}" ] && cd "$HOOK_CWD" 2>/dev/null
relay_active || exit 0

# Never block twice in a row: if the previous stop was already blocked by this
# hook, let the session end rather than loop forever.
[ "${HOOK_STOP_ACTIVE:-false}" = "true" ] && exit 0

# Mission complete: nothing to gate.
[ -f "$RELAY_DIR/DONE.md" ] && exit 0

leg_started=$(json_get "$RELAY_DIR/state.json" leg_started_at)
leg_started="${leg_started:-0}"
baton_mtime=0
[ -f "$RELAY_DIR/baton.md" ] && baton_mtime=$(mtime_epoch "$RELAY_DIR/baton.md")

if [ "$baton_mtime" -ge "$leg_started" ] 2>/dev/null && [ "$baton_mtime" -gt 0 ]; then
  # Baton refreshed this leg: clean handoff, let the leg end.
  exit 0
fi

hook_block "Relay: this session is an active relay leg and .relay/baton.md has not been updated since the leg started. Before ending, rewrite the baton so the next session can continue without you: what is done (with file paths), what is in flight, ranked next steps, failed approaches that must not be retried, and a one-paragraph drift check tying the next steps back to .relay/mission.md. If the mission is fully complete, write .relay/DONE.md with the evidence instead."
exit 0
