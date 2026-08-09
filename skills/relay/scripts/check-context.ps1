# PostToolUse hook (Windows): context sensor. Mirror of check-context.sh.
$ErrorActionPreference = "SilentlyContinue"
$input_ = [Console]::In.ReadToEnd()
try { $hook = $input_ | ConvertFrom-Json } catch { exit 0 }
if ($hook.cwd) { Set-Location $hook.cwd }
$RelayDir = if ($env:RELAY_DIR) { $env:RELAY_DIR } else { ".relay" }
if (-not (Test-Path "$RelayDir/state.json")) { exit 0 }
$st = Get-Content "$RelayDir/state.json" -Raw | ConvertFrom-Json
if ($st.status -ne "running") { exit 0 }
if (-not $hook.transcript_path -or -not (Test-Path $hook.transcript_path)) { exit 0 }

$last = 0
foreach ($line in (Get-Content $hook.transcript_path -Tail 400)) {
  try { $o = $line | ConvertFrom-Json } catch { continue }
  $u = $o.message.usage
  if ($null -ne $u -and $null -ne $u.input_tokens) {
    $cr = 0; if ($u.cache_read_input_tokens) { $cr = [int]$u.cache_read_input_tokens }
    $cc = 0; if ($u.cache_creation_input_tokens) { $cc = [int]$u.cache_creation_input_tokens }
    $last = [int]$u.input_tokens + $cr + $cc
  }
}
$window = if ($st.window) { [int]$st.window } else { 200000 }
$threshold = if ($st.threshold) { [int]$st.threshold } else { 70 }
$fill = [math]::Floor($last * 100 / $window)
if ($fill -lt $threshold) { exit 0 }

$armed = "$RelayDir/handoff-armed"
$lastFired = if (Test-Path $armed) { [int](Get-Content $armed) } else { 0 }
if ($lastFired -eq 0) {
  Set-Content $armed $fill
  @{ decision = "block"; reason = "Relay: context is at $fill% of the window (threshold $threshold%). Hand off now: stop starting new work, bring .relay/baton.md fully up to date (every section, including the failed-approaches ledger and the drift check), then end the leg. If the mission is already complete with evidence, write .relay/DONE.md instead." } | ConvertTo-Json -Compress
} elseif ($fill -ge ($lastFired + 10)) {
  Set-Content $armed $fill
  @{ decision = "block"; reason = "Relay: context is now at $fill%. Finish the handoff immediately: update .relay/baton.md and end the leg." } | ConvertTo-Json -Compress
}
exit 0
