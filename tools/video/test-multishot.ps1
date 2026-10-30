# Offline regression: six multi-shot scenes, synthetic footage, no external services.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $root
$testName = "_multishot-test-$PID"
$testEp = Join-Path 'episodes' $testName
$outDir = Join-Path 'build' $testName
$expected = @{ S04 = 3; S06 = 3; S07 = 3; S08 = 3; S10 = 3; S11 = 2 }
try {
  New-Item -ItemType Directory -Force "$testEp\assets", "$testEp\audio" | Out-Null
  Copy-Item 'episodes\001-sms-ai-check\script.md' "$testEp\script.md"
  $shots = Get-Content 'episodes\001-sms-ai-check\shots.json' -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($id in $expected.Keys) {
    $entry = $shots.PSObject.Properties[$id]
    if (-not $entry -or @($entry.Value).Count -ne $expected[$id]) {
      throw "Incorrect manifest shot count for $id"
    }
    foreach ($shot in $entry.Value) { $shot.seconds = 1 }
  }
  $shots | ConvertTo-Json -Depth 5 | Set-Content "$testEp\shots.json" -Encoding UTF8
  Add-Type -AssemblyName System.Drawing
  $n = 0
  foreach ($entry in $shots.PSObject.Properties) {
    foreach ($shot in $entry.Value) {
      $name = [string]$shot.file
      $dest = Join-Path (Resolve-Path "$testEp\assets").Path $name
      if ($name -match '\.(png|jpe?g)$') {
        $n++
        $bmp = New-Object System.Drawing.Bitmap(480,800)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::FromArgb((30*$n)%255, (50*$n)%255, (70*$n)%255))
        $bmp.Save($dest, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
      } else {
        if ($name -eq 'S06_01.mp4') {
          # A short red-to-blue recording: when extended to one second, it must freeze on blue, not replay red.
          & ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=c=red:s=480x800:r=30:d=0.267' -f lavfi -i 'color=c=blue:s=480x800:r=30:d=0.267' -filter_complex '[0:v][1:v]concat=n=2:v=1:a=0[v]' -map '[v]' -an -c:v libx264 -pix_fmt yuv420p $dest
        } else {
          & ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=c=blue:s=480x800:r=30:d=1' -an -c:v libx264 -pix_fmt yuv420p $dest
        }
        if ($LASTEXITCODE -ne 0) { throw "Synthetic video failed: $name" }
      }
    }
  }
  foreach ($id in $expected.Keys) {
    & ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'anullsrc=r=48000:cl=stereo' -t 2 -c:a pcm_s16le "$testEp\audio\$id.wav"
    if ($LASTEXITCODE -ne 0) { throw "Synthetic audio failed: $id" }
  }
  & powershell -NoProfile -ExecutionPolicy Bypass -File tools\video\build-episode.ps1 -EpisodeDir $testEp -Only S04,S06,S07,S08,S10,S11
  if ($LASTEXITCODE -ne 0) { throw "Multi-shot build failed: exit $LASTEXITCODE" }
  # Check a frame after the short S06_01 recording ends. It must remain blue.
  $sample = Join-Path $outDir 'freeze-check.png'
  & ffmpeg -hide_banner -loglevel error -y -ss 0.70 -i "$outDir\scenes\S06_shot01.mp4" -frames:v 1 $sample
  if ($LASTEXITCODE -ne 0) { throw 'Freeze-frame extraction failed' }
  $frame = [System.Drawing.Bitmap]::FromFile((Resolve-Path $sample).Path)
  try { $pixel = $frame.GetPixel(960,315) } finally { $frame.Dispose() }
  if ($pixel.B -le ($pixel.R + 30)) { throw "Short recording was replayed instead of frozen (R=$($pixel.R), B=$($pixel.B))" }
  $report = Get-Content "$outDir\report.txt" -Raw -Encoding UTF8
  foreach ($id in $expected.Keys) {
    $count = $expected[$id]
    if ($report -notmatch "$id\s+.+?file\+shots:$count") { throw "Missing $count-shot report entry for $id" }
  }
  $duration = [double](& ffprobe -v error -show_entries format=duration -of csv=p=0 "$outDir\$testName.mp4")
  if ($duration -lt 18 -or $duration -gt 25) { throw "Unexpected test duration: $duration" }
  Write-Output "PASS: 6 ordered-shot scenes; 17 synthetic shots; duration=$duration seconds"
} finally {
  if (Test-Path $testEp) { Remove-Item $testEp -Recurse -Force }
  if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
}
