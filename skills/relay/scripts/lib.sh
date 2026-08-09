#!/usr/bin/env bash
# Shared helpers for the relay scripts and hooks.
# Everything here must run on stock macOS bash 3.2 and Linux bash/dash.

RELAY_DIR="${RELAY_DIR:-.relay}"
RELAY_DEFAULT_WINDOW=200000
RELAY_DEFAULT_THRESHOLD=70

# Read one top-level string/number field out of a small flat JSON file.
# Usage: json_get <file> <key>
json_get() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null
  else
    python3 - "$file" "$key" 2>/dev/null <<'PY'
import json, sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2])
    if v is not None:
        print(v)
except Exception:
    pass
PY
  fi
}

# Parse fields we care about from a hook's stdin JSON. Reads stdin once and
# sets: HOOK_TRANSCRIPT, HOOK_CWD, HOOK_STOP_ACTIVE, HOOK_SESSION_ID.
read_hook_input() {
  local input
  input="$(cat)"
  if command -v jq >/dev/null 2>&1; then
    HOOK_TRANSCRIPT=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
    HOOK_CWD=$(printf '%s' "$input" | jq -r '.cwd // empty')
    HOOK_STOP_ACTIVE=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')
    HOOK_SESSION_ID=$(printf '%s' "$input" | jq -r '.session_id // empty')
  else
    eval "$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print("HOOK_TRANSCRIPT=%r" % (d.get("transcript_path") or ""))
print("HOOK_CWD=%r" % (d.get("cwd") or ""))
print("HOOK_STOP_ACTIVE=%r" % ("true" if d.get("stop_hook_active") else "false"))
print("HOOK_SESSION_ID=%r" % (d.get("session_id") or ""))
' 2>/dev/null)"
  fi
}

# Current context tokens for a session = input + cache_read + cache_creation
# on the newest assistant message in the transcript. This is exact, not an
# estimate: it is what the API just charged for the context.
# Usage: context_tokens <transcript.jsonl>
context_tokens() {
  local t="$1"
  [ -f "$t" ] || { echo 0; return; }
  if command -v jq >/dev/null 2>&1; then
    tail -n 400 "$t" | jq -rs '
      [ .[] | select(.message.usage.input_tokens != null) ] | last |
      if . == null then 0 else
        (.message.usage.input_tokens
         + (.message.usage.cache_read_input_tokens // 0)
         + (.message.usage.cache_creation_input_tokens // 0))
      end' 2>/dev/null || echo 0
  else
    tail -n 400 "$t" | python3 -c '
import json, sys
last = 0
for line in sys.stdin:
    try:
        u = json.loads(line).get("message", {}).get("usage")
    except Exception:
        continue
    if u and u.get("input_tokens") is not None:
        last = ((u.get("input_tokens") or 0)
                + (u.get("cache_read_input_tokens") or 0)
                + (u.get("cache_creation_input_tokens") or 0))
print(last)' 2>/dev/null || echo 0
  fi
}

# Percentage of the context window in use, integer 0-100+.
# Usage: context_fill_pct <transcript.jsonl>
context_fill_pct() {
  local tokens window
  tokens=$(context_tokens "$1")
  window="${RELAY_CONTEXT_WINDOW:-$RELAY_DEFAULT_WINDOW}"
  [ -n "$tokens" ] && [ "$tokens" -gt 0 ] 2>/dev/null || { echo 0; return; }
  echo $(( tokens * 100 / window ))
}

# File mtime as epoch seconds, BSD and GNU stat both handled.
mtime_epoch() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# Emit a hook JSON response that feeds `reason` back to Claude.
hook_block() {
  local reason="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg r "$reason" '{decision: "block", reason: $r}'
  else
    python3 -c 'import json,sys; print(json.dumps({"decision":"block","reason":sys.argv[1]}))' "$reason"
  fi
}

relay_active() {
  [ -f "$RELAY_DIR/state.json" ] && [ "$(json_get "$RELAY_DIR/state.json" status)" = "running" ]
}
