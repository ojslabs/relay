# Example relays

## A migration that outlives any single context window

```bash
cd my-app
~/.claude/skills/relay/scripts/relay.sh start \
  "Replace every use of the legacy http client in src/ with lib/api-client.ts. \
   Update imports, keep behavior identical, and keep the test suite green throughout." \
  --verify "npm test" \
  --threshold 70 --max-legs 25 --budget 5
```

Each leg picks up the baton, migrates as many call sites as its window allows,
records the ones that resisted (and why) in the failed-approaches ledger, and
hands off. The relay only ends when `npm test` passes after a DONE claim.

## An audit with a written trail

```bash
relay.sh start \
  "Audit every route handler in server/routes for missing input validation. \
   Write findings to AUDIT.md as you go: file, line, risk, suggested fix." \
  --verify "test -s AUDIT.md" \
  --threshold 65
```

## The two-minute smoke test (no API cost)

```bash
cd "$(mktemp -d)"
RELAY_CLAUDE_CMD=/path/to/relay/tests/fake-claude/claude FAKE_PLAN="work,work,done" \
  /path/to/relay/skills/relay/scripts/relay.sh start "toy" --verify "test -f proof.txt"
cat .relay/log.jsonl
```

Three fake legs run, the third claims DONE with proof, verify accepts it. Swap
`FAKE_PLAN="done-lie,done"` to watch a false completion get caught and cost
exactly one extra leg.
