#!/usr/bin/env bash
# Spawn the next relay leg as a fresh session, then let the current one end.
# Used by in-session mode; the headless runner (relay.sh start) does not need it.
#
# Chooses the most visible home the machine offers:
#   inside tmux            -> new tmux window
#   macOS with a display   -> new Terminal.app window
#   otherwise              -> detached headless leg (nohup)
# Force one with: RELAY_SPAWN=tmux|terminal|headless
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

PROJECT_DIR="$(pwd)"
CLAUDE_CMD="${RELAY_CLAUDE_CMD:-claude}"
PROMPT="Continue the relay in this project: read .relay/mission.md and .relay/baton.md, then work as the next leg. The mission file is fixed; the baton is your inheritance."

"$SCRIPT_DIR/relay.sh" leg-next

mode="${RELAY_SPAWN:-}"
if [ -z "$mode" ]; then
  if [ -n "${TMUX:-}" ]; then mode=tmux
  elif [ "$(uname)" = "Darwin" ]; then mode=terminal
  else mode=headless
  fi
fi

case "$mode" in
  tmux)
    tmux new-window -c "$PROJECT_DIR" "$CLAUDE_CMD \"$PROMPT\"" \
      && echo "relay: successor leg opened in a new tmux window"
    ;;
  terminal)
    /usr/bin/osascript >/dev/null <<EOF
tell application "Terminal"
  activate
  do script "cd $(printf '%q' "$PROJECT_DIR") && $CLAUDE_CMD \"$PROMPT\""
end tell
EOF
    echo "relay: successor leg opened in a new Terminal window"
    ;;
  headless)
    nohup "$CLAUDE_CMD" -p "$PROMPT" --output-format json \
      > "$RELAY_DIR/successor.log" 2>&1 &
    disown 2>/dev/null || true
    echo "relay: successor leg started headless (log: $RELAY_DIR/successor.log)"
    ;;
  *)
    echo "relay: unknown RELAY_SPAWN mode '$mode'" >&2; exit 1
    ;;
esac
