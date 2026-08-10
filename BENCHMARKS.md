# relay A/B benchmarks

Two rounds, run 2026-08-09 and 2026-08-10, followed by an audit that
invalidated round 2's headline. Read the retraction first.

## Retraction (2026-08-10)

Round 2 originally claimed relay resolved 7 of 8 issues against a baseline's 6
"because the baseline degraded deep in its context window." That claim does not
survive its own data, and three errors caused it.

**1. Neither arm ever approached context rot.** The runs used claude-sonnet-5,
whose context window is 1,000,000 tokens (`modelUsage.contextWindow` in the run
output). The baseline peaked at 158,391 tokens: **15.8% of its window**, with
zero compactions, ending on `end_turn` because it finished. The reported "79%
peak fill" came from relay's own hardcoded assumption of a 200,000-token window.
The benchmark never entered the regime the skill exists for.

**2. The one issue that decided the result was decided by an oracle, not by
freshness.** Both arms' outcomes on psf/requests-3362 trace to what each found
in the checkout's git history: the relay leg ran `git log --all` and surfaced
the upstream commit, producing a patch byte-identical to the SWE-bench gold
patch; the baseline ran only `git log --oneline -3`, was denied a WebSearch at
the decision point, fell back to a modern release where the fix had since been
reverted upstream, and followed that. Different information, not different
context health.

**3. The control was contaminated.** The claim "the same model solves requests
easily standalone" is void: that run's working directory was
`runs/psf__requests-3362__baseline/`, and the session ran `gh pr diff 3362`.
The PR number appears nowhere in the issue text; it came from the path. The
marathon runs carry no such leak (verified: zero such calls).

**What the audit found instead of degradation:** effort *increased* with
position. Per-issue tool calls in mission order ran 10, 13, 21, 8, 10, 8, 13,
**38**; the last issue was the maximum on tool calls, test runs, verification
depth, output tokens and wall time. A technique learned at issue 3 was reused
at issues 6 and 8. No re-derivation of settled facts anywhere in the session.

**Status of the claim:** untested, not disproven. What follows is the measured
data, with only the conclusions the data actually supports.

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

| arm | resolved | wall | sessions | turns | output tokens | peak fill (of 1M) |
|---|---|---|---|---|---|---|
| baseline | 6/8 | 996s | 1 | 228 | 99.9k | 15.8% |
| relay @70% | 7/8 | 790s | 2 | 263 | 106.7k | 12.1% |

The 7-vs-6 difference is retracted as evidence for relay (see the retraction:
it was an oracle asymmetry on one issue, at n=1). Blind judging of the
differing patches, 30 comparisons across 3 lenses and both presentation
orders, scored quality even: Elo baseline 1006, relay 994, record 12-11-16.

**What the run does support is a cost structure, and it is not the one the
skill assumed.** Measured from the transcripts:

| | baseline | relay |
|---|---|---|
| input tokens processed | 24.05M | 21.60M |
| per turn | 105.5k | 82.1k |
| per tool call | 193.9k | 154.3k |
| context carried, Q1 to Q4 | 63k to 147k (x2.3) | 63k to 92k (x1.4) |
| cache reads | 23.69M ($2.78) | 21.08M ($2.48) |
| cache writes | 0.36M ($1.33) | 0.51M ($1.93) |
| total | $5.62 | $6.01 |

A relay leg carries 22% less context per turn, exactly as designed. It still
costs 7% more in dollars, and the reason is prompt caching: re-reading an
accumulated context bills at roughly $0.118 per million tokens, while a fresh
session rebuilding its cache bills at $3.75 per million, about 32x. Caching
already solves the *billing* half of context bloat. Only the *quality* half is
left for a relay to win, and this benchmark never reached a depth where
quality was in question.

Two things the run does demonstrate, independent of the retraction:

- **Ungraceful leg death is recoverable.** Relay's leg 1 was killed mid-flight
  by its own per-leg budget cap (error exit, no clean handoff, below its own
  threshold). Leg 2 started from the on-disk mission, baton and work products,
  recovered, and finished. The state on disk, not any single session, carries
  the mission. This is a real property, and it is crash recovery rather than
  rot avoidance.
- **A handoff costs about 55k tokens.** Measured on leg 2: 55,115 prompt
  tokens before its first productive tool call. Only 5,101 of that was reading
  the handoff itself; 50,014 was session bootstrap (system prompt, tool
  schemas, re-orientation) paid a second time. The baton compressed leg 1's
  context about 33:1 and lost nothing needed to keep solving, only the
  evidence, which cost 9 tool calls to regenerate.

## What is actually established, and what is not

Established: relay flattens context growth per turn (x1.4 vs x2.3); a handoff
costs roughly 55k tokens, mostly session bootstrap rather than the baton; a
crashed leg is recoverable from disk; and under prompt caching a relay is not
cheaper in dollars than one long session.

Not established, by this benchmark or any other we have run: that a long
session degrades, or that relay prevents it. The runs topped out at 15.8% of
the window. The task shape (8 independent issues, each re-readable from disk)
also removes almost every channel drift could travel through, and the three
constraints that existed only in the prompt were never scored. n=1 per arm.

Testing the actual claim needs a different experiment: a mission that fills
the window, a task whose constraints live only in the conversation and are
mechanically checkable at the end, oracle access equalized across arms
(truncate checkout history at the base commit), identical budgets, and enough
paired seeds to see past single-issue noise.

## Reproduce

The harness lives in the bench scripts used for this report: instance prep
(clone at base commit, venv, pre-check that FAIL_TO_PASS fails before any
fix), one cell per (issue, arm), token accounting from session transcripts,
and blind judging. Instances: django__django-14999, pallets__flask-4045,
psf__requests-3362, pytest-dev__pytest-7432 from SWE-bench Lite.
