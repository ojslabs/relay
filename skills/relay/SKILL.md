---
name: relay
description: >-
  Run one long goal across many fresh Claude Code sessions with automatic
  handoff before context rot sets in. A hook measures exact context fill from
  the transcript; past a threshold the current session distills its state into
  a baton file (.relay/baton.md), a fresh session spawns, picks the baton up,
  and the loop continues until the mission is complete and verified. Use this
  whenever the user says /relay, mentions a relay, asks to hand off to a new
  session, wants a long mission to survive context limits, complains about
  context rot, compaction, drift, or a session "getting dumber", or gives a
  task clearly too large for one context window (big migrations, audits,
  multi-hour builds). Also use it proactively when your own context is filling
  and real work remains.
---

# relay

One mission, many fresh sessions. Each session is a leg: it inherits the baton,
works, and hands off before its context window degrades. State lives on disk in
`.relay/`, never in any one session's memory.

All paths below are relative to this skill directory unless they start with `.relay/`.

## Which mode

**Runner mode (default for "run this whole thing"):** an outer loop drives
headless legs unattended. Use when the user gives a mission and wants it done.

```bash
scripts/relay.sh start "the mission text" \
  --verify "pnpm test"        # optional but recommended: completion gate \
  --threshold 70              # handoff at 70% context fill \
  --max-legs 20 --model sonnet --budget 5
```

Run it in the background (it may take hours) and monitor `.relay/log.jsonl`.
Pass `--claude-arg --dangerously-skip-permissions` only if the user asked for
fully unattended execution in a directory they trust.

**In-session mode (the current conversation becomes leg 1):** use when the user
wants THIS session to start the relay.

```bash
scripts/relay.sh leg-begin "the mission text" --threshold 70
```

Then work normally. The hooks are now armed (see below). When the context
sensor tells you to hand off: update every section of `.relay/baton.md`, run
`scripts/spawn-successor.sh`, tell the user a successor session has opened, and
end your reply. Do not keep working past the signal; a sharp handoff beats
three more degraded tool calls.

## What the hooks do (installed by both modes into .claude/settings.json)

- `check-context.sh` (PostToolUse): computes exact context fill from the
  transcript (input + cache tokens of the newest assistant message over the
  window). At the threshold it tells the session to hand off; ten points later
  it insists. Silent otherwise.
- `on-stop.sh` (Stop): a leg may not end with a stale baton. If the baton was
  not updated this leg and the mission is not done, the stop is blocked once
  with instructions.
- `on-session-start.sh` (SessionStart): every new session in the project starts
  with the mission and baton injected, so even a manually opened session joins
  the relay instead of drifting.

## Baton discipline (the part that actually prevents drift)

`.relay/mission.md` is written once and never edited. `.relay/baton.md` is
rewritten by every leg and has fixed sections: mission digest, done so far
(with file paths), in flight, ranked next steps, failed approaches (never
retry these), learnings, and a drift check paragraph that ties the next steps
back to the mission. The failed-approaches ledger is what makes a relay
cheaper than one long session: dead ends are paid for once.

## Completion

A leg that believes the mission is complete writes `.relay/DONE.md` containing
evidence: commands run and their real output. If a `--verify` command is set,
the runner executes it; a failing verify rejects the DONE, appends the failure
to the baton, and the relay continues. Never write DONE.md without evidence.

## Answering questions about a running relay

`scripts/relay.sh status` prints state and the leg log. Each `.relay/log.jsonl`
line records the leg, session id, context tokens and fill at exit, and the stop
reason. For design details read `references/architecture.md`.

## Cross-session messaging

On Claude Code 2.1.224+ (macOS/Linux), a retiring leg may additionally announce
itself to peer sessions via the SendMessage tool ("relay leg N handed off,
successor is starting"). This is garnish, not load-bearing: the baton file is
the transfer mechanism and works everywhere, including Windows.
