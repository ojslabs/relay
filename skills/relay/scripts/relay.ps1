# relay: run one goal across many fresh Claude Code sessions. Windows runner.
# Usage mirrors relay.sh:
#   .\relay.ps1 start "mission" [-Verify "cmd"] [-MaxLegs 20] [-Threshold 70]
#                [-Window 200000] [-Model name] [-Budget 5]
#   .\relay.ps1 resume | status | stop | init | leg-begin "mission" | leg-next
# RELAY_CLAUDE_CMD env var overrides the claude binary (used by tests).
param(
  [Parameter(Position = 0)] [string]$Command = "",
  [Parameter(Position = 1)] [string]$Mission = "",
  [string]$Verify = "",
  [int]$MaxLegs = 20,
  [int]$Threshold = 70,
  [int]$Window = 200000,
  [string]$Model = "",
  [string]$Budget = ""
)
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RelayDir = if ($env:RELAY_DIR) { $env:RELAY_DIR } else { ".relay" }
$ClaudeCmd = if ($env:RELAY_CLAUDE_CMD) { $env:RELAY_CLAUDE_CMD } else { "claude" }

function Read-State {
  if (Test-Path "$RelayDir/state.json") { Get-Content "$RelayDir/state.json" -Raw | ConvertFrom-Json } else { $null }
}
function Write-State($Status, $Leg, $Thr, $Win, $Max, $Ver, $LegStartedAt) {
  @{ status = $Status; leg = $Leg; threshold = $Thr; window = $Win;
     max_legs = $Max; verify = $Ver; leg_started_at = $LegStartedAt } |
    ConvertTo-Json | Set-Content "$RelayDir/state.json"
}
function Get-ContextTokens($Transcript) {
  if (-not $Transcript -or -not (Test-Path $Transcript)) { return 0 }
  $last = 0
  foreach ($line in (Get-Content $Transcript -Tail 400)) {
    try { $o = $line | ConvertFrom-Json } catch { continue }
    $u = $o.message.usage
    if ($null -ne $u -and $null -ne $u.input_tokens) {
      $cr = 0; if ($u.cache_read_input_tokens) { $cr = [int]$u.cache_read_input_tokens }
      $cc = 0; if ($u.cache_creation_input_tokens) { $cc = [int]$u.cache_creation_input_tokens }
      $last = [int]$u.input_tokens + $cr + $cc
    }
  }
  return $last
}
function Install-Hooks {
  New-Item -ItemType Directory -Force -Path ".claude" | Out-Null
  $path = ".claude/settings.json"
  if ((Test-Path $path) -and $PSVersionTable.PSVersion.Major -lt 6) {
    Write-Host "relay: merging hooks into an existing settings.json needs PowerShell 7 (pwsh)."
    Write-Host "relay: install pwsh, or add the hooks manually (see docs/install.md)."
    return
  }
  $settings = if (Test-Path $path) { Get-Content $path -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
  if (-not $settings.ContainsKey("hooks")) { $settings["hooks"] = @{} }
  $hooks = $settings["hooks"]
  foreach ($pair in @(
      @{ ev = "PostToolUse"; script = "check-context.ps1"; matcher = $true },
      @{ ev = "Stop"; script = "on-stop.ps1"; matcher = $false },
      @{ ev = "SessionStart"; script = "on-session-start.ps1"; matcher = $false })) {
    $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$ScriptDir\$($pair.script)`""
    if (-not $hooks.ContainsKey($pair.ev)) { $hooks[$pair.ev] = @() }
    $already = $false
    foreach ($m in $hooks[$pair.ev]) {
      foreach ($h in $m.hooks) { if ("$($h.command)" -like "*$($pair.script)*") { $already = $true } }
    }
    if (-not $already) {
      $entry = if ($pair.matcher) { @{ matcher = "*"; hooks = @(@{ type = "command"; command = $cmd }) } }
               else { @{ hooks = @(@{ type = "command"; command = $cmd }) } }
      $hooks[$pair.ev] = @($hooks[$pair.ev]) + @($entry)
    }
  }
  $settings | ConvertTo-Json -Depth 10 | Set-Content $path
  Write-Host "relay: hooks installed in .claude/settings.json"
}
function Get-LegPrompt($Leg) {
  (Get-Content "$ScriptDir\..\assets\leg-prompt.md" -Raw) -replace "{{LEG}}", $Leg
}
function Write-LegLog($Leg, $SessionId, $Tokens, $Fill, $Reason) {
  $line = @{ leg = $Leg; session_id = $SessionId; ended = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ");
             context_tokens = $Tokens; fill_pct = $Fill; stop_reason = $Reason } | ConvertTo-Json -Compress
  Add-Content "$RelayDir/log.jsonl" $line
}

function Invoke-RelayLoop {
  $st = Read-State
  $leg = [int]$st.leg; $Threshold = [int]$st.threshold; $Window = [int]$st.window
  $MaxLegs = [int]$st.max_legs; $Verify = "$($st.verify)"
  while ($true) {
    if (Test-Path "$RelayDir/DONE.md") {
      if (-not $Verify) {
        Write-Host "relay: mission complete after $leg leg(s) (no verify command set)."
        Write-State done $leg $Threshold $Window $MaxLegs $Verify 0; break
      }
      Write-Host "relay: DONE claimed by leg $leg, running verify: $Verify"
      cmd /c $Verify *> "$RelayDir/verify-output.txt"
      if ($LASTEXITCODE -eq 0) {
        Write-Host "relay: verify passed. Mission complete after $leg leg(s)."
        Write-State done $leg $Threshold $Window $MaxLegs $Verify 0; break
      }
      Write-Host "relay: verify FAILED. Removing DONE.md and continuing."
      $tail = (Get-Content "$RelayDir/verify-output.txt" -Tail 40) -join "`n"
      Add-Content "$RelayDir/baton.md" "`n## Verification failure (leg $leg)`nThe DONE claim was rejected. `` $Verify `` exited nonzero:`n``````n$tail`n``````nDo not write DONE.md again until this passes."
      Remove-Item "$RelayDir/DONE.md" -Force
    }
    if ($leg -ge $MaxLegs) {
      Write-Host "relay: hit max legs ($MaxLegs) without completion. 'relay.ps1 resume' to continue."
      Write-State stopped $leg $Threshold $Window $MaxLegs $Verify 0; break
    }
    $leg += 1
    Remove-Item "$RelayDir/handoff-armed" -Force -ErrorAction SilentlyContinue
    Write-State running $leg $Threshold $Window $MaxLegs $Verify ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    Write-Host "relay: leg $leg starting"
    $args = @("-p", "--output-format", "json")
    if ($Model) { $args += @("--model", $Model) }
    if ($Budget) { $args += @("--max-budget-usd", $Budget) }
    $env:RELAY_RUNNER = "1"; $env:RELAY_CONTEXT_WINDOW = "$Window"
    $out = & $ClaudeCmd @args (Get-LegPrompt $leg) 2>> "$RelayDir/runner-errors.log"
    $code = $LASTEXITCODE
    $sessionId = ""
    try { $sessionId = ("$out" | ConvertFrom-Json).session_id } catch {}
    $transcript = $null
    if ($sessionId) {
      $transcript = Get-ChildItem "$env:USERPROFILE\.claude\projects\*\$sessionId.jsonl" -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    }
    $tokens = Get-ContextTokens $transcript
    $fill = [math]::Floor($tokens * 100 / $Window)
    $reason = if (Test-Path "$RelayDir/DONE.md") { "done-claimed" } elseif ($code -ne 0) { "error($code)" } else { "handoff" }
    Write-LegLog $leg $sessionId $tokens $fill $reason
    Write-Host "relay: leg $leg ended: $reason, context $fill% ($tokens tokens)"
    if ($code -ne 0 -and -not (Test-Path "$RelayDir/DONE.md")) {
      $fails = (Select-String -Path "$RelayDir/log.jsonl" -Pattern '"stop_reason":"error' -AllMatches -ErrorAction SilentlyContinue).Count
      if ($fails -ge 3) {
        Write-Host "relay: three legs have errored; stopping. See $RelayDir/runner-errors.log"
        Write-State stopped $leg $Threshold $Window $MaxLegs $Verify 0; break
      }
    }
  }
}

switch ($Command) {
  "init" {
    New-Item -ItemType Directory -Force -Path $RelayDir | Out-Null
    Install-Hooks
    Write-Host "relay: initialized. Start with: relay.ps1 start `"your mission`""
  }
  "start" {
    if (-not $Mission) { throw "start needs a mission" }
    $st = Read-State
    if ($st -and $st.status -eq "running") { throw "a relay is already running here" }
    New-Item -ItemType Directory -Force -Path $RelayDir | Out-Null
    Install-Hooks
    Set-Content "$RelayDir/mission.md" $Mission
    Copy-Item "$ScriptDir\..\assets\baton-template.md" "$RelayDir/baton.md" -Force
    Set-Content "$RelayDir/log.jsonl" ""
    Remove-Item "$RelayDir/DONE.md", "$RelayDir/handoff-armed" -Force -ErrorAction SilentlyContinue
    Write-State running 0 $Threshold $Window $MaxLegs $Verify 0
    Invoke-RelayLoop
  }
  "resume" {
    $st = Read-State
    if (-not $st) { throw "no relay here; use start" }
    if ($st.status -eq "done") { throw "this relay already completed" }
    Write-State running $st.leg $st.threshold $st.window $st.max_legs "$($st.verify)" 0
    Invoke-RelayLoop
  }
  "leg-begin" {
    if (-not $Mission) { throw "leg-begin needs a mission" }
    New-Item -ItemType Directory -Force -Path $RelayDir | Out-Null
    Install-Hooks
    Set-Content "$RelayDir/mission.md" $Mission
    if (-not (Test-Path "$RelayDir/baton.md")) { Copy-Item "$ScriptDir\..\assets\baton-template.md" "$RelayDir/baton.md" }
    Write-State running 1 $Threshold $Window $MaxLegs $Verify ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    Write-Host "relay: this session is now leg 1."
  }
  "leg-next" {
    $st = Read-State
    if (-not $st) { throw "no relay here" }
    Write-State running ([int]$st.leg + 1) $st.threshold $st.window $st.max_legs "$($st.verify)" ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    Remove-Item "$RelayDir/handoff-armed" -Force -ErrorAction SilentlyContinue
    Write-Host "relay: leg $([int]$st.leg + 1) armed"
  }
  "status" {
    Get-Content "$RelayDir/state.json"
    Write-Host "--- legs ---"
    if (Test-Path "$RelayDir/log.jsonl") { Get-Content "$RelayDir/log.jsonl" }
  }
  "stop" {
    $st = Read-State
    if (-not $st) { throw "no relay here" }
    Write-State stopped $st.leg $st.threshold $st.window $st.max_legs "$($st.verify)" 0
    Write-Host "relay: stopped. Baton and log kept in $RelayDir/"
  }
  default { Get-Content $MyInvocation.MyCommand.Path | Select-Object -First 8 }
}
