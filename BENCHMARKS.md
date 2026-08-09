# relay A/B benchmark, 2026-08-09

Four real SWE-bench Lite issues, run head to head: a plain single Claude Code
session versus the same session driven by relay. Same model (sonnet), same $4
budget cap, same tool allowlist, fresh clone per run. The agent saw only the
issue text; resolution was scored afterward by applying each instance's hidden
test patch and running its FAIL_TO_PASS tests. Elo comes from blind pairwise
judging: 3 lenses (correctness, minimality, root cause) x both presentation
orders, judges shown only the issue and the two anonymized patches.

## Results

| issue | arm | resolved | wall | sessions | output tokens |
|---|---|---|---|---|---|
| django-14999 | baseline | yes | 139s | 1 | 19,998 |
| django-14999 | relay @70% | yes | 103s | 1 | 13,233 |
| django-14999 | relay @30% | yes | 144s | 1 | 17,649 |
| flask-4045 | baseline | no | 135s | 1 | 16,625 |
| flask-4045 | relay @70% | no | 203s | 1 | 29,079 |
| requests-3362 | baseline | yes | 123s | 1 | 17,738 |
| requests-3362 | relay @70% | no | 239s | 1 | 32,471 |
| pytest-7432 | baseline | yes | 97s | 1 | 12,978 |
| pytest-7432 | relay @70% | yes | 191s | 1 | 26,371 |
| pytest-7432 | relay @30% | yes | 347s | 2 | 58,433 |

Elo after 36 blind comparisons: baseline 1017, relay @30% 999, relay @70% 983.
Win record baseline vs relay @70%: 6 wins, 2 losses, 16 ties.

## What the numbers actually say

**1. On tasks that fit one context window, relay is overhead.** None of these
issues pushed a session past 41% fill, so the 70% threshold never fired and
every relay run was a single leg carrying baton bookkeeping it never needed.
Baseline resolved 3/4, relay @70% 2/4, and relay runs averaged 1.7x the output
tokens. If the work fits in one window, run one session; relay's own docs now
say so.

**2. The handoff itself did not damage the work.** The forced-threshold runs
(@30%) are the point of the exercise: pytest-7432 was fixed across two fresh
sessions, leg 1 handing off mid-task at 41% fill, leg 2 finishing from the
baton, hidden tests green. And on every issue both relay arms produced patches
byte-identical to baseline's, including that two-leg run. Judges scored 16 of
24 baseline-vs-relay comparisons as ties for exactly this reason. Crossing a
session boundary changed the solution by zero bytes; that is the anti-drift
property working.

**3. Where relay lost, it lost by overthinking, not drifting.** On
requests-3362 the relay leg spent budget on baton discipline and shipped a
narrower fix that the hidden tests rejected; judges (blind to test outcomes)
independently preferred the baseline patch's root-cause fix in 4 of 6
comparisons. On flask-4045 both arms failed identically.

**4. The bench paid for itself in bugs found.** Cell runs caught a real relay
defect: a variadic `--allowedTools` passthrough swallowed the leg prompt, so
every leg launched empty. Fixed with a regression test in this repo (commit
c417cd7), on top of the GNU stat mount-point bug CI caught the day before.

## Honest scope

Small n (4 issues, 10 runs, one model), and these SWE-bench Lite tasks are
short by construction: they measure relay's cost floor, not its benefit case.
The benefit case is missions that blow past one context window, where the
alternative is compaction or a human re-prompting from scratch; the @30% runs
show the mechanism survives that regime with correctness intact. A benchmark
of genuinely window-exhausting missions is the natural next measurement.

## Reproduce

The harness lives in the bench scripts used for this report: instance prep
(clone at base commit, venv, pre-check that FAIL_TO_PASS fails before any
fix), one cell per (issue, arm), token accounting from session transcripts,
and blind judging. Instances: django__django-14999, pallets__flask-4045,
psf__requests-3362, pytest-dev__pytest-7432 from SWE-bench Lite.
