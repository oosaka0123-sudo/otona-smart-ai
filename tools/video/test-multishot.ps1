# Offline regression test: synthetic footage and silent audio only.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $root
$testName = "_multishot-test-$PID"
$testEp = Join-Path 'episodes' $testName
$outDir = Join-Path 'build' $testName
try {
  New-Item -ItemType Directory -Force "$testEp\assets", "$testEp\audio" | Out-Null
  Copy-Item 'episodes\001-sms-ai-check\script.md' "$testEp\script.md"
  $shots = Get-Content 'episodes\001-sms-ai-check\shots.json' -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($prop in $shots.PSObject.Properties) {
    foreach ($shot in $prop.Value) { $shot.seconds = 1 }
  }
  $shots | ConvertTo-Json -Depth 5 | Set-Content "$testEp\shots.json" -Encoding UTF8
  Add-Type -AssemblyName System.Drawing
  $images = @('S04_01.png','S04_02.png','S04_03.png','S06_03.png',
              'S10_01.png','S10_02.png','S10_03.png')
  $n = 0
  foreach ($name in $images) {
    $n++
    $bmp = New-Object System.Drawing.Bitmap(480,800)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb((30*$n)%255, (50*$n)%255, (70*$n)%255))
    $bmp.Save((Join-Path (Resolve-Path "$testEp\assets").Path $name), [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
  }
  foreach ($name in @('S06_01.mp4','S06_02.mp4')) {
    & ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=c=blue:s=480x800:r=30:d=1' -an -c:v libx264 -pix_fmt yuv420p "$testEp\assets\$name"
    if ($LASTEXITCODE -ne 0) { throw "Test video failed: $name" }
  }
  foreach ($id in @('S04','S06','S10')) {
    & ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'anullsrc=r=48000:cl=stereo' -t 2 -c:a pcm_s16le "$testEp\audio\$id.wav"
    if ($LASTEXITCODE -ne 0) { throw "Test audio failed: $id" }
  }
  & powershell -NoProfile -ExecutionPolicy Bypass -File tools\video\build-episode.ps1 -EpisodeDir $testEp -Only S04,S06,S10
  if ($LASTEXITCODE -ne 0) { throw "Multi-shot build failed: exit $LASTEXITCODE" }
  $report = Get-Content "$outDir\report.txt" -Raw -Encoding UTF8
  foreach ($id in @('S04','S06','S10')) {
    if ($report -notmatch "$id\s+.+?file\+shots:3") { throw "Missing 3-shot report entry for $id" }
  }
  $duration = [double](& ffprobe -v error -show_entries format=duration -of csv=p=0 "$outDir\$testName.mp4")
  if ($duration -lt 9 -or $duration -gt 15) { throw "Unexpected test duration: $duration" }
  Write-Output "PASS: 3 ordered-shot scenes; 9 synthetic shots; duration=$duration seconds"
} finally {
  if (Test-Path $testEp) { Remove-Item $testEp -Recurse -Force }
  if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
}
