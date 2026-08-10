#!/usr/bin/env bash
# relay: run one goal across many fresh Claude Code sessions.
#
#   relay.sh start "mission" [options]   begin a relay in this directory
#   relay.sh resume                      continue a stopped/interrupted relay
#   relay.sh status                      show state and the leg log
#   relay.sh stop                        halt the relay (baton is kept)
#   relay.sh init                        create .relay/ and install hooks only
#
# Options for start/resume:
#   --verify "cmd"     command that must exit 0 before completion is accepted
#   --max-legs N       hard cap on sessions (default 20)
#   --threshold PCT    context fill percent that triggers handoff (default 70)
#   --window TOKENS    context window size in tokens (default 200000)
#   --model NAME       model for each leg (default: your configured default)
#   --budget USD       per-leg spend cap, passed to claude --max-budget-usd
#   --claude-arg X     extra argument passed through to claude (repeatable)
#
# Environment: RELAY_CLAUDE_CMD overrides the claude binary (used by tests).
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

CLAUDE_CMD="${RELAY_CLAUDE_CMD:-claude}"
CMD="${1:-}"
[ -n "$CMD" ] && shift

die() { echo "relay: $*" >&2; exit 1; }

now_epoch() { date +%s; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

write_state() {
  # write_state <status> <leg> <threshold> <window> <max_legs> <verify> <leg_started_at>
  python3 - "$RELAY_DIR/state.json" "$@" 2>/dev/null <<'PY' ||
import json, sys
p = sys.argv[1]
keys = ["status", "leg", "threshold", "window", "max_legs", "verify", "leg_started_at"]
vals = sys.argv[2:9]
d = {}
for k, v in zip(keys, vals):
    d[k] = int(v) if v.lstrip("-").isdigit() else v
json.dump(d, open(p, "w"), indent=2)
PY
  {
    # Fallback without python3: hand-rolled flat JSON (values are simple).
    printf '{\n  "status": "%s",\n  "leg": %s,\n  "threshold": %s,\n  "window": %s,\n  "max_legs": %s,\n  "verify": "%s",\n  "leg_started_at": %s\n}\n' \
      "$1" "$2" "$3" "$4" "$5" "$6" "$7" > "$RELAY_DIR/state.json"
  }
}

log_leg() {
  # log_leg <leg> <session_id> <tokens> <fill_pct> <stop_reason>
  printf '{"leg":%s,"session_id":"%s","ended":"%s","context_tokens":%s,"fill_pct":%s,"stop_reason":"%s"}\n' \
    "$1" "$2" "$(now_iso)" "$3" "$4" "$5" >> "$RELAY_DIR/log.jsonl"
}

install_hooks() {
  # Merge the relay hooks into .claude/settings.json non-destructively.
  mkdir -p .claude
  python3 - "$SCRIPT_DIR" 2>/dev/null <<'PY' || die "hook install needs python3 or manual setup; see docs/install.md"
import json, os, sys
sd = sys.argv[1]
path = ".claude/settings.json"
settings = {}
if os.path.exists(path):
    with open(path) as f:
        settings = json.load(f)
hooks = settings.setdefault("hooks", {})
def ensure(event, script):
    cmd = f'"{sd}/{script}"'
    lst = hooks.setdefault(event, [])
    for m in lst:
        for h in m.get("hooks", []):
            if script in h.get("command", ""):
                return
    lst.append({"matcher": "*", "hooks": [{"type": "command", "command": cmd}]} if event == "PostToolUse"
               else {"hooks": [{"type": "command", "command": cmd}]})
ensure("PostToolUse", "check-context.sh")
ensure("Stop", "on-stop.sh")
ensure("SessionStart", "on-session-start.sh")
with open(path, "w") as f:
    json.dump(settings, f, indent=2)
print("relay: hooks installed in .claude/settings.json")
PY
}

leg_prompt() {
  local leg="$1"
  sed -e "s/{{LEG}}/$leg/g" "$SCRIPT_DIR/../assets/leg-prompt.md"
}

# Defaults, overridable by flags.
MISSION=""
VERIFY=""
MAX_LEGS=20
THRESHOLD=$RELAY_DEFAULT_THRESHOLD
# 0 means auto: detect the model's real window from leg 1's result and record
# it. --window overrides. Never assume; a wrong window mistimes every handoff.
WINDOW=0
MODEL=""
BUDGET=""
EXTRA_ARGS=()

parse_opts() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --verify) VERIFY="$2"; shift 2;;
      --max-legs) MAX_LEGS="$2"; shift 2;;
      --threshold) THRESHOLD="$2"; shift 2;;
      --window) WINDOW="$2"; shift 2;;
      --model) MODEL="$2"; shift 2;;
      --budget) BUDGET="$2"; shift 2;;
      --claude-arg) EXTRA_ARGS+=("$2"); shift 2;;
      *) if [ -z "$MISSION" ]; then MISSION="$1"; shift; else die "unknown option: $1"; fi;;
    esac
  done
}

run_loop() {
  local leg
  leg=$(json_get "$RELAY_DIR/state.json" leg); leg="${leg:-0}"
  THRESHOLD=$(json_get "$RELAY_DIR/state.json" threshold)
  WINDOW=$(json_get "$RELAY_DIR/state.json" window)
  MAX_LEGS=$(json_get "$RELAY_DIR/state.json" max_legs)
  VERIFY=$(json_get "$RELAY_DIR/state.json" verify)

  while :; do
    if [ -f "$RELAY_DIR/DONE.md" ]; then
      if [ -z "$VERIFY" ]; then
        echo "relay: mission complete after $leg leg(s) (no verify command set)."
        write_state done "$leg" "$THRESHOLD" "$WINDOW" "$MAX_LEGS" "$VERIFY" 0
        break
      fi
      echo "relay: DONE claimed by leg $leg, running verify: $VERIFY"
      if sh -c "$VERIFY" > "$RELAY_DIR/verify-output.txt" 2>&1; then
        echo "relay: verify passed. Mission complete after $leg leg(s)."
        write_state done "$leg" "$THRESHOLD" "$WINDOW" "$MAX_LEGS" "$VERIFY" 0
        break
      fi
      echo "relay: verify FAILED. Removing DONE.md and continuing."
      {
        echo ""
        echo "## Verification failure (leg $leg, $(now_iso))"
        echo "The DONE claim was rejected. \`$VERIFY\` exited nonzero:"
        echo '```'
        tail -n 40 "$RELAY_DIR/verify-output.txt"
        echo '```'
        echo "Do not write DONE.md again until this passes."
      } >> "$RELAY_DIR/baton.md"
      rm -f "$RELAY_DIR/DONE.md"
    fi

    if [ "$leg" -ge "$MAX_LEGS" ]; then
      echo "relay: hit max legs ($MAX_LEGS) without completion. Baton kept; 'relay.sh resume' to continue."
      write_state stopped "$leg" "$THRESHOLD" "$WINDOW" "$MAX_LEGS" "$VERIFY" 0
      break
    fi

    leg=$(( leg + 1 ))
    rm -f "$RELAY_DIR/handoff-armed"
    write_state running "$leg" "$THRESHOLD" "$WINDOW" "$MAX_LEGS" "$VERIFY" "$(now_epoch)"
    echo "relay: leg $leg starting ($(now_iso))"

    # The prompt goes directly after -p: variadic flags like --allowedTools
    # would otherwise swallow a trailing positional prompt as extra values.
    local args=(-p "$(leg_prompt "$leg")" --output-format json)
    [ -n "$MODEL" ] && args+=(--model "$MODEL")
    [ -n "$BUDGET" ] && args+=(--max-budget-usd "$BUDGET")
    [ ${#EXTRA_ARGS[@]} -gt 0 ] && args+=("${EXTRA_ARGS[@]}")

    local out session_id win_env=""
    [ "$WINDOW" -gt 0 ] 2>/dev/null && win_env="$WINDOW"
    out=$(RELAY_RUNNER=1 RELAY_CONTEXT_WINDOW="$win_env" "$CLAUDE_CMD" "${args[@]}" 2>>"$RELAY_DIR/runner-errors.log")
    local exit_code=$?

    # Learn the model's real context window from the leg's own result, so
    # every later leg measures fill against the truth rather than a guess.
    local detected
    detected=$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    for u in (json.load(sys.stdin).get("modelUsage") or {}).values():
        w = u.get("contextWindow")
        if w: print(int(w)); break
except Exception:
    pass' 2>/dev/null)
    if [ -n "$detected" ] && [ "$detected" -gt 0 ] 2>/dev/null && [ "$detected" != "$WINDOW" ]; then
      [ "$WINDOW" -gt 0 ] 2>/dev/null && echo "relay: context window is ${detected} (was using ${WINDOW}); recalibrating"
      WINDOW="$detected"
      write_state running "$leg" "$THRESHOLD" "$WINDOW" "$MAX_LEGS" "$VERIFY" "$(now_epoch)"
    fi
    session_id=$(printf '%s' "$out" | { jq -r '.session_id // empty' 2>/dev/null || python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("session_id",""))
except Exception: print("")'; })

    local transcript tokens fill
    transcript=""
    [ -n "$session_id" ] && transcript=$(ls "$HOME"/.claude/projects/*/"$session_id".jsonl 2>/dev/null | head -1)
    tokens=$(context_tokens "$transcript")
    local win_for_pct="$WINDOW"
    [ "$win_for_pct" -gt 0 ] 2>/dev/null || win_for_pct="$RELAY_DEFAULT_WINDOW"
    fill=$(( tokens * 100 / win_for_pct ))

    local reason="handoff"
    [ $exit_code -ne 0 ] && reason="error($exit_code)"
    [ -f "$RELAY_DIR/DONE.md" ] && reason="done-claimed"
    log_leg "$leg" "${session_id:-unknown}" "$tokens" "$fill" "$reason"
    echo "relay: leg $leg ended: $reason, context ${fill}% (${tokens} tokens)"

    if [ $exit_code -ne 0 ] && [ ! -f "$RELAY_DIR/DONE.md" ]; then
      local fails
      fails=$(grep -c '"stop_reason":"error' "$RELAY_DIR/log.jsonl" 2>/dev/null)
      [ -n "$fails" ] || fails=0
      if [ "$fails" -ge 3 ] 2>/dev/null; then
        echo "relay: three legs have errored; stopping. See $RELAY_DIR/runner-errors.log"
        write_state stopped "$leg" "$THRESHOLD" "$WINDOW" "$MAX_LEGS" "$VERIFY" 0
        break
      fi
    fi
  done
}

case "$CMD" in
  init)
    mkdir -p "$RELAY_DIR"
    install_hooks
    echo "relay: initialized. Start with: relay.sh start \"your mission\""
    ;;
  start)
    parse_opts "$@"
    [ -n "$MISSION" ] || die "start needs a mission: relay.sh start \"...\""
    [ -f "$RELAY_DIR/state.json" ] && [ "$(json_get "$RELAY_DIR/state.json" status)" = "running" ] && \
      die "a relay is already running here; use resume, status, or stop"
    mkdir -p "$RELAY_DIR"
    install_hooks
    printf '%s\n' "$MISSION" > "$RELAY_DIR/mission.md"
    cp "$SCRIPT_DIR/../assets/baton-template.md" "$RELAY_DIR/baton.md"
    : > "$RELAY_DIR/log.jsonl"
    rm -f "$RELAY_DIR/DONE.md" "$RELAY_DIR/handoff-armed"
    write_state running 0 "$THRESHOLD" "$WINDOW" "$MAX_LEGS" "$VERIFY" 0
    echo "relay: mission recorded in $RELAY_DIR/mission.md"
    run_loop
    ;;
  resume)
    parse_opts "$@"
    [ -f "$RELAY_DIR/state.json" ] || die "no relay here; use start"
    local_status=$(json_get "$RELAY_DIR/state.json" status)
    [ "$local_status" = "done" ] && die "this relay already completed; start a new one"
    write_state running "$(json_get "$RELAY_DIR/state.json" leg)" \
      "$(json_get "$RELAY_DIR/state.json" threshold)" "$(json_get "$RELAY_DIR/state.json" window)" \
      "$(json_get "$RELAY_DIR/state.json" max_legs)" "$(json_get "$RELAY_DIR/state.json" verify)" 0
    run_loop
    ;;
  leg-begin)
    # Turn the CURRENT interactive session into leg 1 (in-session mode).
    parse_opts "$@"
    [ -n "$MISSION" ] || die "leg-begin needs a mission"
    mkdir -p "$RELAY_DIR"
    install_hooks
    printf '%s\n' "$MISSION" > "$RELAY_DIR/mission.md"
    [ -f "$RELAY_DIR/baton.md" ] || cp "$SCRIPT_DIR/../assets/baton-template.md" "$RELAY_DIR/baton.md"
    : > "$RELAY_DIR/log.jsonl"
    rm -f "$RELAY_DIR/DONE.md" "$RELAY_DIR/handoff-armed"
    write_state running 1 "$THRESHOLD" "$WINDOW" "$MAX_LEGS" "$VERIFY" "$(now_epoch)"
    echo "relay: this session is now leg 1. Mission recorded; hooks armed."
    ;;
  leg-next)
    # Called by spawn-successor before the next session starts.
    [ -f "$RELAY_DIR/state.json" ] || die "no relay here"
    leg=$(json_get "$RELAY_DIR/state.json" leg); leg=$(( ${leg:-0} + 1 ))
    write_state running "$leg" "$(json_get "$RELAY_DIR/state.json" threshold)" \
      "$(json_get "$RELAY_DIR/state.json" window)" "$(json_get "$RELAY_DIR/state.json" max_legs)" \
      "$(json_get "$RELAY_DIR/state.json" verify)" "$(now_epoch)"
    rm -f "$RELAY_DIR/handoff-armed"
    echo "relay: leg $leg armed"
    ;;
  status)
    [ -f "$RELAY_DIR/state.json" ] || die "no relay in this directory"
    cat "$RELAY_DIR/state.json"
    echo "--- legs ---"
    [ -f "$RELAY_DIR/log.jsonl" ] && cat "$RELAY_DIR/log.jsonl"
    ;;
  stop)
    [ -f "$RELAY_DIR/state.json" ] || die "no relay in this directory"
    write_state stopped "$(json_get "$RELAY_DIR/state.json" leg)" \
      "$(json_get "$RELAY_DIR/state.json" threshold)" "$(json_get "$RELAY_DIR/state.json" window)" \
      "$(json_get "$RELAY_DIR/state.json" max_legs)" "$(json_get "$RELAY_DIR/state.json" verify)" 0
    echo "relay: stopped. Baton and log kept in $RELAY_DIR/"
    ;;
  *)
    sed -n '2,20p' "$0"
    exit 1
    ;;
esac
