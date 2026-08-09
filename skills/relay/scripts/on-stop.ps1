# Stop hook (Windows): handoff gate. Mirror of on-stop.sh.
$ErrorActionPreference = "SilentlyContinue"
$input_ = [Console]::In.ReadToEnd()
try { $hook = $input_ | ConvertFrom-Json } catch { exit 0 }
if ($hook.cwd) { Set-Location $hook.cwd }
$RelayDir = if ($env:RELAY_DIR) { $env:RELAY_DIR } else { ".relay" }
if (-not (Test-Path "$RelayDir/state.json")) { exit 0 }
$st = Get-Content "$RelayDir/state.json" -Raw | ConvertFrom-Json
if ($st.status -ne "running") { exit 0 }
if ($hook.stop_hook_active) { exit 0 }
if (Test-Path "$RelayDir/DONE.md") { exit 0 }

$legStarted = 0
if ($st.leg_started_at) { $legStarted = [long]$st.leg_started_at }
$batonMtime = 0
if (Test-Path "$RelayDir/baton.md") {
  $batonMtime = [DateTimeOffset]::new((Get-Item "$RelayDir/baton.md").LastWriteTimeUtc).ToUnixTimeSeconds()
}
if ($batonMtime -gt 0 -and $batonMtime -ge $legStarted) { exit 0 }

@{ decision = "block"; reason = "Relay: this session is an active relay leg and .relay/baton.md has not been updated since the leg started. Before ending, rewrite the baton so the next session can continue without you: what is done (with file paths), what is in flight, ranked next steps, failed approaches that must not be retried, and a one-paragraph drift check tying the next steps back to .relay/mission.md. If the mission is fully complete, write .relay/DONE.md with the evidence instead." } | ConvertTo-Json -Compress
exit 0
