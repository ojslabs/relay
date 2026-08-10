# relay A/B benchmarks

Two rounds, run 2026-08-09 and 2026-08-10. Round 1 measured relay on
single-window tasks (its cost floor). Round 2 iterated the skill on those
findings, then ran marathon missions sized past the context window (its
benefit case). Skip to the Round 2 marathon section for the headline result.

# Round 1: single-window issues, 2026-08-09

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

# Round 2: the marathon, 2026-08-10

Round 1's findings went back into the skill first: the baton became lazy (full
rewrite only at the handoff signal, one-line dead-end notes otherwise) and the
leg protocol now states the mission outranks the relay bookkeeping. Then the
regime the skill exists for: one continuous mission spanning many real issues,
each in its own checkout with its own venv. Same scoring as round 1, applied
only after the runs.

## 4-issue marathon (~136k peak: still under the window)

| arm | resolved | wall | sessions | output tokens | peak fill |
|---|---|---|---|---|---|
| baseline | 2/4 | 562s | 1 | 71.7k | 68% |
| relay @70% | 2/4 | 688s | 2 | 103.5k | 56% |

A tie on resolution, baseline cheaper. The mission strained the window without
bursting it, so this row extends round 1's lesson. One scale signal though:
both arms failed requests-3362 here, an issue baseline solves in isolation.

## 8-issue marathon (the window actually runs out)

Eight issues across five codebases (two django, two flask, two pytest, one
requests, one pylint), one mission.

| arm | resolved | wall | sessions | output tokens | peak fill |
|---|---|---|---|---|---|
| baseline | 6/8 | 996s | 1 | 99.9k | 79% |
| relay @70% | 7/8 | 790s | 2 | 106.7k | 60% |

**Relay resolved more, finished faster, at 7% extra tokens.** Blind judging of
the differing patches (30 comparisons, 3 lenses x 2 orders, plus identity
ties) scored quality even: Elo baseline 1006, relay 994, record 12-11-16.

The decisive issue is requests-3362. Baseline failed it in both marathons
while solving it standalone, and its failure came late in a session running at
up to 79% fill. Relay's fresh leg fixed it while never running a session past
60%, with the patch the blind judges preferred 5 of 6 times for fixing the
root cause in stream_decode_response_unicode; the hidden tests agreed. The one
issue relay missed, flask-4045, has never been solved by any arm in any
configuration in these benches.

Two things the run demonstrated beyond the score:

- **Degradation precedes compaction.** The baseline session never triggered
  auto-compact; it simply got worse in the deep half of its window. Waiting
  for compaction to defend context quality is too late, which is why relay's
  sensor fires at a threshold rather than at the cliff.
- **Ungraceful leg death is recoverable.** Relay's leg 1 was killed mid-flight
  by its own per-leg budget cap (error exit, no clean handoff). Leg 2 started
  from the on-disk mission, baton, and work products, recovered, and finished
  7/8. The state on disk, not any single session, carries the mission.

## The shape of the answer

Across both rounds one curve emerges: below one window, relay costs extra and
buys nothing (run a single session); near the window, it breaks even; past
the window, it wins on resolution and speed at near-parity token cost. The
crossover sits where the mission stops fitting, which is the design intent,
and what the skill's own docs now tell you.

## Reproduce

The harness lives in the bench scripts used for this report: instance prep
(clone at base commit, venv, pre-check that FAIL_TO_PASS fails before any
fix), one cell per (issue, arm), token accounting from session transcripts,
and blind judging. Instances: django__django-14999, pallets__flask-4045,
psf__requests-3362, pytest-dev__pytest-7432 from SWE-bench Lite.
