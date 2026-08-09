# SessionStart hook (Windows): baton injection. Mirror of on-session-start.sh.
$ErrorActionPreference = "SilentlyContinue"
$input_ = [Console]::In.ReadToEnd()
try { $hook = $input_ | ConvertFrom-Json } catch { exit 0 }
if ($hook.cwd) { Set-Location $hook.cwd }
$RelayDir = if ($env:RELAY_DIR) { $env:RELAY_DIR } else { ".relay" }
if (-not (Test-Path "$RelayDir/state.json")) { exit 0 }
$st = Get-Content "$RelayDir/state.json" -Raw | ConvertFrom-Json
if ($st.status -ne "running") { exit 0 }

Remove-Item "$RelayDir/handoff-armed" -Force -ErrorAction SilentlyContinue
$mission = if (Test-Path "$RelayDir/mission.md") { Get-Content "$RelayDir/mission.md" -Raw } else { "" }
$baton = if (Test-Path "$RelayDir/baton.md") { Get-Content "$RelayDir/baton.md" -Raw } else { "" }
$context = "An active relay is running in this project. You are its next leg.`n`nThe mission (fixed, never edit .relay/mission.md):`n---`n$mission`n---`n`nThe baton from previous legs (.relay/baton.md):`n---`n$baton`n---`n`nContinue from the baton's next steps. Honor its failed-approaches list. Keep the baton current as you work; a hook will tell you when context fill requires a handoff."
@{ hookSpecificOutput = @{ hookEventName = "SessionStart"; additionalContext = $context } } | ConvertTo-Json -Compress
exit 0
