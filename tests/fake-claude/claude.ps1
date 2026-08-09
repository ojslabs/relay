# Fake claude for relay tests (Windows). Mirror of ./claude.
New-Item -ItemType Directory -Force -Path ".relay" | Out-Null
$countFile = ".relay/fake-calls"
$n = 0
if (Test-Path $countFile) { $n = [int](Get-Content $countFile) }
$n += 1
Set-Content $countFile $n
$plan = if ($env:FAKE_PLAN) { $env:FAKE_PLAN } else { "work,done" }
$actions = $plan -split ","
$action = if ($n -le $actions.Count) { $actions[$n - 1] } else { "done" }

Set-Content "out-$n.txt" "leg $n fake work"
Add-Content ".relay/baton.md" "`n## Leg $n`nfake claude leg $n ran action $action"

switch ($action) {
  "done" {
    Set-Content "proof.txt" "proof"
    Set-Content ".relay/DONE.md" "# DONE`nEvidence: created out files and proof.txt"
  }
  "done-lie" {
    Set-Content ".relay/DONE.md" "# DONE`nEvidence: trust me"
  }
}
Write-Output ('{"type":"result","session_id":"fake-' + $n + '","result":"leg ' + $n + ' ended"}')
exit 0
