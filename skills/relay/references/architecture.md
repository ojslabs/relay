# relay architecture

## The sensor: exact context fill, not a guess

Claude Code writes every API exchange to the session transcript
(`~/.claude/projects/<slug>/<session-id>.jsonl`). Each assistant message
carries `message.usage`; the context the model is actually holding equals

```
input_tokens + cache_read_input_tokens + cache_creation_input_tokens
```

of the newest assistant message. That is what the API just billed as input, so
it is the ground truth of window occupancy. `lib.sh:context_tokens` computes it
with jq (python3 fallback); the PowerShell hooks use ConvertFrom-Json. Hook
input JSON does not include token counts (only the statusline JSON does), but
every hook receives `transcript_path`, which is enough.

The default threshold is 70% of a 200,000-token window. Handing off early is
deliberate: the leg needs enough remaining headroom to write a good baton, and
a handoff written at 95% fill is written by the least capable version of the
session. Tune with `--threshold` and `--window`.

## The three hooks

- PostToolUse (`check-context.sh`): computes fill after every tool call. Fires
  a handoff instruction once at the threshold and once more 10 points higher.
  The two-shot design keeps the transcript clean; a hook that nags on every
  tool call would itself burn context.
- Stop (`on-stop.sh`): a leg may not end while the relay is running unless the
  baton was modified after the leg started or DONE.md exists. Blocks at most
  once (`stop_hook_active` is honored), so a misbehaving leg cannot loop.
- SessionStart (`on-session-start.sh`): injects mission + baton into every new
  session in the project as additionalContext, and resets the per-leg trigger.
  This is what lets a manually opened session join the relay.

All three no-op instantly unless `.relay/state.json` exists with
`"status": "running"`, so installing the hooks (or the plugin) has no effect on
normal projects.

## The runner

`relay.sh start` runs legs as `claude -p --output-format json` child processes
and reads each leg's session id from the result JSON to locate its transcript
and log real token numbers to `.relay/log.jsonl`. Stop conditions: verified
DONE, max legs (default 20), or three errored legs. `resume` continues a
stopped relay from the same baton.

## Verified completion

A DONE claim is only accepted when the `--verify` command exits 0. A rejected
DONE is appended to the baton as a verification failure (with the verify
output), so the next leg knows the claim was made and rejected. This replaces
the magic-token exit (`EXIT_SIGNAL`, `<promise>COMPLETE</promise>`) used by
loop tools, which trusts the model's own report.

## Drift control

Three mechanisms, all cheap:

1. `mission.md` is written once and never edited; every leg reads it first.
2. The baton's drift-check section forces each leg to map its next steps back
   to the mission in writing before handing off.
3. The failed-approaches ledger makes dead ends survive the handoff, which is
   the main efficiency win over same-prompt loops that re-attempt them.

## Prior art and the seat relay takes

Loop tools get fresh context but carry only files and checkboxes
(frankbria/ralph-claude-code, AnandChowdhary/continuous-claude,
Th0rgal/open-ralph-wiggum). Handoff tools distill state but stop at a markdown
file and wait for a human (REMvisual/claude-handoff, thepushkarp/handoff,
hex/claude-sessions, which nudges at 80% and still asks you to /clear).
relay does the full cycle unattended: measured trigger, distilled baton,
fresh-session spawn, verified completion.

## Cross-session messaging

Claude Code 2.1.224 (2026-08-07) added SendMessage/ListAgents between your own
sessions (macOS/Linux). relay treats it as optional garnish: a retiring leg may
announce its handoff to peer sessions, but the baton file is the transfer
mechanism and works on every platform, including native Windows where
messaging is unavailable.

Docs: https://code.claude.com/docs/en/cross-session-messaging,
https://code.claude.com/docs/en/hooks.md,
https://code.claude.com/docs/en/headless.md
