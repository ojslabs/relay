# Relay logic tests, Windows/PowerShell twin of run.sh. No API calls.
$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Scripts = Join-Path $Root "skills/relay/scripts"
$Fixture = Join-Path $Root "tests/fixtures/transcript.jsonl"
$Fake = Join-Path $Root "tests/fake-claude/claude.ps1"
$script:Pass = 0; $script:Fail = 0

function Check($desc, $cond) {
  if ($cond) { Write-Host "  ok: $desc"; $script:Pass++ }
  else { Write-Host "  FAIL: $desc"; $script:Fail++ }
}
function Fresh-Dir {
  $d = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
  New-Item -ItemType Directory -Path $d | Out-Null
  Set-Location $d
}
function Invoke-Hook($script, $json) {
  $json | & (Get-Command pwsh, powershell -ErrorAction SilentlyContinue | Select-Object -First 1).Source `
    -NoProfile -ExecutionPolicy Bypass -File $script
}

Write-Host "1. context math (check-context.ps1 end to end)"
Fresh-Dir
New-Item -ItemType Directory -Path ".relay" | Out-Null
Set-Content ".relay/state.json" '{"status":"running","threshold":5,"window":200000}'
$hookJson = '{"transcript_path":' + ($Fixture | ConvertTo-Json) + ',"cwd":' + ($PWD.Path | ConvertTo-Json) + '}'
$out = Invoke-Hook (Join-Path $Scripts "check-context.ps1") $hookJson
Check "fires past threshold with exact fill (37%)" ("$out" -match "context is at 37%")
Check "arms the per-leg marker" ((Get-Content ".relay/handoff-armed") -eq "37")
$out = Invoke-Hook (Join-Path $Scripts "check-context.ps1") $hookJson
Check "silent at same fill after firing" (-not "$out")
Set-Content ".relay/state.json" '{"status":"running","threshold":90,"window":200000}'
Remove-Item ".relay/handoff-armed" -Force
$out = Invoke-Hook (Join-Path $Scripts "check-context.ps1") $hookJson
Check "silent below threshold" (-not "$out")

Write-Host "2. handoff gate (on-stop.ps1)"
Fresh-Dir
New-Item -ItemType Directory -Path ".relay" | Out-Null
Set-Content ".relay/baton.md" "baton"
$future = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 500
Set-Content ".relay/state.json" ('{"status":"running","leg_started_at":' + $future + '}')
$cwdJson = $PWD.Path | ConvertTo-Json
$out = Invoke-Hook (Join-Path $Scripts "on-stop.ps1") ('{"cwd":' + $cwdJson + '}')
Check "blocks a leg ending with a stale baton" ("$out" -match "has not been updated")
Set-Content ".relay/state.json" '{"status":"running","leg_started_at":10}'
$out = Invoke-Hook (Join-Path $Scripts "on-stop.ps1") ('{"cwd":' + $cwdJson + '}')
Check "allows a leg with a fresh baton" (-not "$out")
Set-Content ".relay/state.json" ('{"status":"running","leg_started_at":' + $future + '}')
$out = Invoke-Hook (Join-Path $Scripts "on-stop.ps1") ('{"cwd":' + $cwdJson + ',"stop_hook_active":true}')
Check "never blocks twice in a row" (-not "$out")

Write-Host "3. runner completes an honest mission"
Fresh-Dir
$env:RELAY_CLAUDE_CMD = $Fake
$env:FAKE_PLAN = "work,work,done"
& (Join-Path $Scripts "relay.ps1") start "toy mission" -Verify "if not exist proof.txt exit 1" -MaxLegs 5 *> $null
$state = Get-Content ".relay/state.json" -Raw | ConvertFrom-Json
Check "state is done" ($state.status -eq "done")
Check "took exactly 3 legs" ((Get-Content ".relay/log.jsonl" | Where-Object { $_ -match '"leg"' }).Count -eq 3)
Check "legs produced work" ((Test-Path "out-1.txt") -and (Test-Path "out-3.txt"))

Write-Host "4. false DONE is caught by verify"
Fresh-Dir
$env:FAKE_PLAN = "done-lie,done"
& (Join-Path $Scripts "relay.ps1") start "toy mission" -Verify "if not exist proof.txt exit 1" -MaxLegs 5 *> $null
$state = Get-Content ".relay/state.json" -Raw | ConvertFrom-Json
Check "eventually done" ($state.status -eq "done")
Check "the lie cost exactly one extra leg" ((Get-Content ".relay/log.jsonl" | Where-Object { $_ -match '"leg"' }).Count -eq 2)
Check "rejection recorded in the baton" ((Get-Content ".relay/baton.md" -Raw) -match "Verification failure")

Write-Host "5. max-legs cap"
Fresh-Dir
$env:FAKE_PLAN = "work,work,work,work"
& (Join-Path $Scripts "relay.ps1") start "toy mission" -Verify "exit 1" -MaxLegs 2 *> $null
$state = Get-Content ".relay/state.json" -Raw | ConvertFrom-Json
Check "stops at the cap" ($state.status -eq "stopped")
Check "ran exactly max legs" ((Get-Content ".relay/log.jsonl" | Where-Object { $_ -match '"leg"' }).Count -eq 2)

Write-Host ""
Write-Host "passed $script:Pass, failed $script:Fail"
if ($script:Fail -gt 0) { exit 1 }
exit 0
