#!/usr/bin/env bash
# Relay logic tests. No API calls: legs are played by tests/fake-claude/claude.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/skills/relay/scripts"
FIXTURE="$ROOT/tests/fixtures/transcript.jsonl"
FAKE="$ROOT/tests/fake-claude/claude"
PASS=0; FAIL=0

ok()   { echo "  ok: $1"; PASS=$(( PASS + 1 )); }
bad()  { echo "  FAIL: $1"; FAIL=$(( FAIL + 1 )); }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi }

fresh_dir() { d=$(mktemp -d); cd "$d" || exit 1; }

echo "1. context math"
. "$SCRIPTS/lib.sh"
tok=$(context_tokens "$FIXTURE")
check "newest assistant usage wins (2+16543+58087=74632)" [ "$tok" = "74632" ]
fill=$(RELAY_CONTEXT_WINDOW=200000 context_fill_pct "$FIXTURE")
check "fill percent computed against the window (37)" [ "$fill" = "37" ]

echo "2. context sensor (check-context.sh)"
fresh_dir
mkdir -p .relay
printf '{"status":"running","threshold":5,"window":200000}\n' > .relay/state.json
hook_json() { printf '{"transcript_path":"%s","cwd":"%s"}' "$FIXTURE" "$PWD"; }
out=$(hook_json | bash "$SCRIPTS/check-context.sh")
check "fires past threshold" grep -q "Hand off now" <<EOF
$out
EOF
check "arms the per-leg marker with current fill" [ "$(cat .relay/handoff-armed)" = "37" ]
out=$(hook_json | bash "$SCRIPTS/check-context.sh")
check "silent at same fill after firing" [ -z "$out" ]
printf '{"status":"running","threshold":90,"window":200000}\n' > .relay/state.json
rm -f .relay/handoff-armed
out=$(hook_json | bash "$SCRIPTS/check-context.sh")
check "silent below threshold" [ -z "$out" ]

echo "3. handoff gate (on-stop.sh)"
fresh_dir
mkdir -p .relay
echo baton > .relay/baton.md
future=$(( $(date +%s) + 500 ))
printf '{"status":"running","leg_started_at":%s}\n' "$future" > .relay/state.json
out=$(printf '{"cwd":"%s"}' "$PWD" | bash "$SCRIPTS/on-stop.sh")
check "blocks a leg ending with a stale baton" grep -q "has not been updated" <<EOF
$out
EOF
printf '{"status":"running","leg_started_at":10}\n' > .relay/state.json
out=$(printf '{"cwd":"%s"}' "$PWD" | bash "$SCRIPTS/on-stop.sh")
check "allows a leg with a fresh baton" [ -z "$out" ]
printf '{"status":"running","leg_started_at":%s}\n' "$future" > .relay/state.json
out=$(printf '{"cwd":"%s","stop_hook_active":true}' "$PWD" | bash "$SCRIPTS/on-stop.sh")
check "never blocks twice in a row (stop_hook_active)" [ -z "$out" ]

echo "4. runner completes an honest mission"
fresh_dir
export RELAY_CLAUDE_CMD="$FAKE" FAKE_PLAN="work,work,done"
bash "$SCRIPTS/relay.sh" start "toy mission" --verify "test -f proof.txt" --max-legs 5 >/dev/null 2>&1
check "state is done" grep -q '"status": *"done"' .relay/state.json
check "took exactly 3 legs" [ "$(grep -c '"leg"' .relay/log.jsonl)" = "3" ]
check "legs produced work" [ -f out-1.txt ] && [ -f out-3.txt ]

echo "5. false DONE is caught by verify"
fresh_dir
export FAKE_PLAN="done-lie,done"
bash "$SCRIPTS/relay.sh" start "toy mission" --verify "test -f proof.txt" --max-legs 5 >/dev/null 2>&1
check "eventually done" grep -q '"status": *"done"' .relay/state.json
check "the lie cost exactly one extra leg" [ "$(grep -c '"leg"' .relay/log.jsonl)" = "2" ]
check "rejection recorded in the baton" grep -q "Verification failure" .relay/baton.md

echo "6. max-legs cap"
fresh_dir
export FAKE_PLAN="work,work,work,work"
bash "$SCRIPTS/relay.sh" start "toy mission" --max-legs 2 --verify "test -f never.txt" >/dev/null 2>&1
check "stops at the cap" grep -q '"status": *"stopped"' .relay/state.json
check "ran exactly max legs" [ "$(grep -c '"leg"' .relay/log.jsonl)" = "2" ]

echo ""
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = "0" ]
