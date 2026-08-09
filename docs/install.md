# Installing relay

## The short way

`npx skills add ojslabs/relay` installs the skill (SKILL.md plus its scripts)
into your skills directory. The first `relay.sh start` or `relay.sh init` in a
project then installs the three hooks into that project's
`.claude/settings.json` automatically.

The plugin route wires hooks globally instead, so every project is
relay-ready with no per-project init:

```bash
claude plugin marketplace add ojslabs/relay
claude plugin install relay@relay
```

The hooks are inert outside an active relay: each one exits immediately unless
`.relay/state.json` exists in the working directory with status "running".

## Manual hook setup (unix)

If you prefer to write settings yourself, add this to the project's
`.claude/settings.json`, with SKILL_DIR replaced by the absolute path to the
installed skill:

```json
{
  "hooks": {
    "PostToolUse": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "\"SKILL_DIR/scripts/check-context.sh\"" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "\"SKILL_DIR/scripts/on-stop.sh\"" }] }
    ],
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "\"SKILL_DIR/scripts/on-session-start.sh\"" }] }
    ]
  }
}
```

## Manual hook setup (native Windows)

Same structure, PowerShell commands instead:

```json
{
  "hooks": {
    "PostToolUse": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"SKILL_DIR\\scripts\\check-context.ps1\"" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"SKILL_DIR\\scripts\\on-stop.ps1\"" }] }
    ],
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"SKILL_DIR\\scripts\\on-session-start.ps1\"" }] }
    ]
  }
}
```

`relay.ps1 init` writes this for you when it can (merging into an existing
settings.json needs PowerShell 7; a fresh settings.json works everywhere).

## Requirements

- Claude Code 2.x with the `claude` CLI on PATH
- unix: bash, and either jq or python3 (macOS and most Linux ship python3)
- Windows: PowerShell 5.1+ for the hooks and runner, PowerShell 7 to merge
  hooks into an existing settings.json
- No API key is needed for the logic tests: `bash tests/run.sh` / `pwsh tests/run.ps1`
