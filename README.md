# relay

Run one goal across many fresh Claude Code sessions. The baton passes before context rot sets in.

```
mission.md (fixed)
    │
    ▼
 leg 1 ──baton──▶ leg 2 ──baton──▶ leg 3 ──▶ ... ──▶ DONE, checked by your verify command
 fresh             fresh            fresh
 context           context          context
```

A long session degrades as its window fills: compaction blurs early decisions, drift creeps in, and the model re-tries things it already ruled out. relay never lets a session get old. A hook measures exact context fill from the session transcript; past a threshold (70% by default) the session distills everything the next one needs into `.relay/baton.md`, ends, and a fresh session picks the baton up. The loop runs unattended until the mission is complete and your verify command agrees.

## Install

```bash
npx skills add ojslabs/relay
```

Or as a Claude Code plugin, which also wires the hooks automatically:

```bash
claude plugin marketplace add ojslabs/relay
claude plugin install relay@relay
```

Or plain git: `git clone https://github.com/ojslabs/relay ~/.claude/relay && ln -s ~/.claude/relay/skills/relay ~/.claude/skills/relay`

## Start a relay

Unattended, from your terminal:

```bash
cd your-project
~/.claude/skills/relay/scripts/relay.sh start \
  "Migrate every fetch call to the new API client and keep the test suite green" \
  --verify "npm test" --threshold 70 --max-legs 20
```

Or from inside a Claude Code conversation: `/relay <your mission>` turns the current session into leg 1; when the sensor fires, it writes the baton, opens its own successor (new Terminal window, tmux window, or headless process), and retires. On Windows use `scripts\relay.ps1` with the same subcommands.

`relay.sh status` shows the state and the per-leg log. `relay.sh resume` continues an interrupted relay from the same baton.

## How it works

Three hooks, three files, one loop:

| Piece | Job |
|---|---|
| `check-context.sh` (PostToolUse) | computes exact fill from the transcript usage numbers; tells the session to hand off at the threshold |
| `on-stop.sh` (Stop) | a leg cannot end with a stale baton; the handoff is forced before the window closes |
| `on-session-start.sh` (SessionStart) | every new session in the project starts holding the mission and the baton |
| `.relay/mission.md` | the goal, written once, never edited |
| `.relay/baton.md` | done work, next steps, failed approaches, and a drift check, rewritten every leg |
| `.relay/log.jsonl` | one line per leg: session id, context tokens at exit, stop reason |

The failed-approaches ledger is the quiet efficiency win: dead ends are paid for once, while same-prompt loop tools re-attempt them every iteration. And completion is never taken on the model's word; `DONE.md` must survive your `--verify` command or the relay keeps going and records the rejected claim in the baton.

## What it is compared to

| | fresh context each round | distilled handoff | trigger | spawns successor | completion check |
|---|---|---|---|---|---|
| ralph-style loops | yes | no, same prompt re-fed | per task | yes | magic token |
| handoff tools (`/handoff`, `/rotate`) | manual | yes | nudge at best | no | none |
| relay | yes | yes | measured fill % | yes | your verify command |

## Platforms

macOS and Linux run everything. Native Windows runs the full relay through `relay.ps1` (PowerShell hooks included); Claude Code's cross-session messaging is not available there, and relay does not depend on it. There is no Claude Code runtime on iOS or Android; a relay running on your machine or in the cloud can be watched from the Claude mobile app via Remote Control.

Logic tests run without any API key on all three platforms: `bash tests/run.sh` or `pwsh tests/run.ps1`.

## Docs

Design details live in [skills/relay/references/architecture.md](skills/relay/references/architecture.md): the exact token math, why handoff at 70% beats 95%, hook payload behavior, and the prior-art map.

## License

MIT
