# Offline release preflight regression: missing S07 must not bypass release checks.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $root
$tempRoot = Join-Path $env:TEMP ("ep001-release-guard-" + $PID)
$tempEp = Join-Path $tempRoot '001-sms-ai-check'
try {
  New-Item -ItemType Directory -Force $tempEp | Out-Null
  $script = Get-Content 'episodes\001-sms-ai-check\script.md' -Raw -Encoding UTF8
  $tampered = [regex]::Replace($script, '(?ms)^## S07 .*?(?=^## S08 )', '')
  if ($tampered -eq $script) { throw 'Test setup failed to remove S07' }
  [IO.File]::WriteAllText((Join-Path $tempEp 'script.md'), $tampered, (New-Object Text.UTF8Encoding($false)))
  # Windows PowerShell treats the child process's expected stderr as an error record.
  $ErrorActionPreference = 'Continue'
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File tools\video\build-episode.ps1 -EpisodeDir $tempEp -Release 2>&1 | Out-String
  $exitCode = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  if ($exitCode -eq 0) { throw 'Release accepted a missing S07 scene' }
  if ($out -notmatch 'scene list mismatch') { throw 'Missing-scene guard did not fire' }
  Write-Output 'PASS: release rejects omitted S07 before rendering'
} finally {
  if (Test-Path $tempRoot) { Remove-Item $tempRoot -Recurse -Force }
}
