<#
.SYNOPSIS
  台本 script.md から YouTube 用 MP4（1920x1080）を組み立てる。

.DESCRIPTION
  PC04 の PoC（Documents\ks04\youtube-video-poc\build.ps1）を本番用に拡張したもの。
  1. script.md を `## Sxx` 単位に分解（ナレーション／【テロップ】／しば研究員）
  2. 各シーンの音声：episodes/<ep>/audio/Sxx.(wav|mp3) があればそれを使う（ElevenLabs 等の本番音声）。
     無ければ Windows 標準 TTS（Haruka）で仮音声を作る。
  3. 各シーンの画面：episodes/<ep>/assets/Sxx.(png|jpg) を背景に、テロップを重ねる。無ければ無地背景。
  4. FFmpeg でシーン動画化 → 連結 → ラウドネス -14 LUFS に正規化。
  出力は build/<ep>/（Git 管理外）。外部サービスへの通信はしない。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/video/build-episode.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/video/build-episode.ps1 -Only S01,S02
#>
param(
  [string]$EpisodeDir = 'episodes/001-sms-ai-check',
  [string]$ScriptFile = 'script.md',
  [string[]]$Only = @(),
  [int]$TtsRate = 0,
  [double]$LeadSec = 0.4,
  [double]$TailSec = 0.8,
  # 公開用：仮音声（TTS）・〔差し替え〕・一部シーンだけの書き出しが残っていたら失敗させる
  [switch]$Release
)
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $RepoRoot
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Speech

$Ep = Resolve-Path $EpisodeDir
$EpName = Split-Path $Ep -Leaf
$Out = Join-Path $RepoRoot "build\$EpName"
New-Item -ItemType Directory -Force (Join-Path $Out 'scenes') | Out-Null

# ---------- 1. 台本の解析 ----------
$lines = Get-Content (Join-Path $Ep $ScriptFile) -Encoding UTF8
$scenes = New-Object System.Collections.ArrayList
$dict = @{}
$cur = $null; $mode = ''
foreach ($raw in $lines) {
  $line = $raw.TrimEnd()
  if ($line -match '^## (S\d{2})\s+(.+?)\s*(（.*）)?$') {
    $cur = [ordered]@{ Id = $Matches[1]; Title = $Matches[2]; Telops = @(); Shiba = @(); Narration = @(); Materials = @(); Placeholder = $false }
    [void]$scenes.Add($cur); $mode = ''; continue
  }
  if ($line -match '^## ') { $cur = $null; $mode = ($(if ($line -match '読み替え') { 'dict' } else { '' })); continue }
  if ($mode -eq 'dict') {
    if ($line -match '^\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|$' -and $Matches[1] -ne '表記' -and $Matches[1] -notmatch '^-+$') { $dict[$Matches[1]] = $Matches[2] }
    continue
  }
  if (-not $cur) { continue }
  if ($line -match '^---') { $mode = ''; continue }
  if ($line -match '^【テロップ（しば研究員）】(.+)$') { $cur.Shiba += $Matches[1]; continue }
  if ($line -match '^【テロップ】(.+)$') { $cur.Telops += $Matches[1]; continue }
  if ($line -match '^【素材】(.+)$') { $cur.Materials += $Matches[1]; continue }
  if ($line -match '^ナレーション：') { $mode = 'nar'; continue }
  if ($mode -eq 'nar' -and $line -ne '' -and $line -notmatch '^【') {
    if ($line -match '〔') { $cur.Placeholder = $true } else { $cur.Narration += $line }
  }
}
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })  # -File 経由では "S01,S02" が1文字列になる
if ($Only.Count -gt 0) { $scenes = @($scenes | Where-Object { $Only -contains $_.Id }) }
if ($scenes.Count -eq 0) { throw 'シーンが見つかりません（## Sxx 見出しを確認）' }

function Find-SceneFile([string]$sub, [string]$id, [string]$extPattern) {
  Get-ChildItem (Join-Path $Ep $sub) -File -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -eq $id -and $_.Extension -match $extPattern } | Select-Object -First 1
}
$AudioExt = '^\.(wav|mp3|m4a)$'; $ImageExt = '^\.(png|jpe?g)$'; $VideoExt = '^\.(mp4|mov)$'

# Ordered shots are optional in previews, but required for multi-shot scenes in release.
# shots.json example: { "S04": [{"file":"S04_01.png","seconds":8}, ...] }
$ShotMap = @{}
$ShotManifest = Join-Path $Ep 'shots.json'
$RequiredMultiShot = @{}
if ($EpName -eq '001-sms-ai-check') { $RequiredMultiShot = @{ S04 = 3; S06 = 3; S07 = 3; S08 = 3; S10 = 3; S11 = 2 } }
if (Test-Path $ShotManifest) {
  $shotData = Get-Content $ShotManifest -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($entry in $shotData.PSObject.Properties) {
    $id = $entry.Name
    if ($id -notmatch '^S\d{2}$') { throw "Invalid shot scene: $id" }
    $items = @($entry.Value)
    if ($items.Count -eq 0) { throw "Empty shot list: $id" }
    foreach ($shot in $items) {
      if ($shot.file -notmatch "^$($id)_\d{2}\.(png|jpe?g|mp4|mov)$") { throw "Invalid shot filename for ${id}: $($shot.file)" }
      $seconds = 0.0
      if (-not [double]::TryParse([string]$shot.seconds, [ref]$seconds) -or $seconds -le 0 -or $seconds -gt 300) {
        throw "Invalid shot duration for ${id}: $($shot.seconds)"
      }
    }
    $ShotMap[$id] = $items
  }
}

if ($Release) {
  $problems = @()
  if ($Only.Count -gt 0) { $problems += '-Only と -Release は併用できません（全シーンを書き出してください）' }
  # Do not allow a missing/reordered scene to silently bypass the audio/footage guards.
  if ($EpName -eq '001-sms-ai-check') {
    $expectedSceneIds = @(1..14 | ForEach-Object { 'S{0:00}' -f $_ })
    $actualSceneIds = @($scenes | ForEach-Object { $_.Id })
    if (($actualSceneIds -join ',') -ne ($expectedSceneIds -join ',')) {
      $problems += "Episode 001 scene list mismatch: expected $($expectedSceneIds -join ','); got $($actualSceneIds -join ',')"
    }
  }
  foreach ($s in $scenes) {
    if ($s.Placeholder) { $problems += "$($s.Id): 〔差し替え〕が残っています" }
    if (-not (Find-SceneFile 'audio' $s.Id $AudioExt)) { $problems += "$($s.Id): 本番音声 audio/$($s.Id).(wav|mp3|m4a) がありません（仮音声のまま）" }
    # 【素材】のあるシーンは、実素材（画像または画面録画）が無ければ公開しない
    $hasShots = $ShotMap.ContainsKey($s.Id)
    if ($RequiredMultiShot.ContainsKey($s.Id) -and (-not $hasShots -or @($ShotMap[$s.Id]).Count -lt $RequiredMultiShot[$s.Id])) {
      $problems += "$($s.Id): ordered shots.json requires at least $($RequiredMultiShot[$s.Id]) shots"
    }
    if ($hasShots) {
      foreach ($shot in $ShotMap[$s.Id]) {
        $shotPath = Join-Path (Join-Path $Ep 'assets') $shot.file
        if (-not (Test-Path -LiteralPath $shotPath -PathType Leaf)) { $problems += "$($s.Id): missing shot assets/$($shot.file)" }
      }
    }
    if ($s.Materials.Count -gt 0 -and -not $hasShots -and -not (Find-SceneFile 'assets' $s.Id "$ImageExt|$VideoExt")) { $problems += "$($s.Id): 素材 assets/$($s.Id).(png|jpg|mp4|mov) がありません（台本の【素材】：$($s.Materials[0])）" }
  }
  if ($problems.Count -gt 0) { throw ("公開用の書き出しを中止しました:`n - " + ($problems -join "`n - ")) }
}

function Get-ReadingText([string]$text) {
  # 長い表記から順に置換（「シャープ9110番」を「9110」より先に）
  foreach ($k in ($dict.Keys | Sort-Object Length -Descending)) { $text = $text.Replace($k, $dict[$k]) }
  return $text
}

# ---------- 2. 画面（スライド）生成 ----------
# 枠に収まるまでフォントを縮める（テロップのはみ出し防止）
function Get-FitFont($g, [string]$text, [string]$family, [float]$size, [float]$min, [float]$w, [float]$h) {
  for ($sz = $size; $sz -ge $min; $sz -= 2) {
    $f = New-Object System.Drawing.Font($family, $sz, [System.Drawing.FontStyle]::Bold)
    $m = $g.MeasureString($text, $f, [int]$w)
    if ($m.Height -le $h -and $m.Width -le $w) { return $f }
    $f.Dispose()
  }
  return New-Object System.Drawing.Font($family, $min, [System.Drawing.FontStyle]::Bold)
}

# $bg：背景画像（無ければ無地）。$overlay：画面録画に重ねる透明PNGとして描く
function New-Slide($s, [int]$index, [int]$total, [string]$path, $bg, [bool]$overlay) {
  $W = 1920; $H = 1080
  $bmp = New-Object System.Drawing.Bitmap($W, $H)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
  $navy = [System.Drawing.Color]::FromArgb(13, 25, 48)
  if ($overlay) { $g.Clear([System.Drawing.Color]::Transparent) }
  elseif ($bg) {
    $img = [System.Drawing.Image]::FromFile($bg.FullName)
    $scale = [Math]::Max($W / $img.Width, $H / $img.Height)
    $w = $img.Width * $scale; $h = $img.Height * $scale
    $g.DrawImage($img, ($W - $w) / 2, ($H - $h) / 2, $w, $h); $img.Dispose()
  } else { $g.Clear($navy) }
  $font = 'Yu Gothic'
  if ($overlay) {
    # 画面録画は y=170〜800 に表示される（Get-VideoFilter）。上下の帯だけ不透明に描く
    $navyBrush = New-Object System.Drawing.SolidBrush($navy)
    $blueB = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(49, 176, 233))
    $grayB = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(194, 215, 234))
    $g.FillRectangle($navyBrush, 0, 0, $W, 170); $g.FillRectangle($navyBrush, 0, 800, $W, 280)
    $fS = New-Object System.Drawing.Font($font, 26)
    $g.DrawString('大人のスマホAI生活', $fS, $grayB, 110, 20)
    $g.DrawString(('{0} / {1}' -f $index, $total), $fS, $blueB, 1700, 20)
    $fT = Get-FitFont $g $s.Title $font 56 32 1500 100
    $g.FillRectangle($blueB, 90, 70, 12, 80)
    $g.DrawString($s.Title, $fT, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(120, 65, 1500, 100)))
    $lines = @($s.Telops | Select-Object -First 1) # one concise caption during screen footage
    if ($lines.Count -eq 0 -and $s.Shiba.Count -gt 0) { $lines += ('しば研究員：' + $s.Shiba[0]) }
    $txt = ($lines | ForEach-Object { $_ -replace '\s+(?=[①-⑳])', "`n" }) -join "`n"
    $fB = Get-FitFont $g $txt $font 44 24 1680 250
    $g.DrawString($txt, $fB, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(120, 815, 1680, 250)))
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $pt = $fB.Size
    foreach ($o in $g, $bmp, $navyBrush, $blueB, $grayB, $fS, $fT, $fB) { $o.Dispose() }
    return $pt
  }
  $white = [System.Drawing.Brushes]::White
  $blue = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(49, 176, 233))
  $gray = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(194, 215, 234))
  $panel = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(($(if ($bg) { 200 } else { 0 })), 13, 25, 48))
  $fSmall = New-Object System.Drawing.Font($font, 30)
  $fTitle = Get-FitFont $g $s.Title $font 72 44 1680 200
  # 「①… ②… ③…」は番号ごとに改行して、単語の途中で折り返さないようにする
  $telop = (($s.Telops | Select-Object -First 4) | ForEach-Object { $_ -replace '\s+(?=[①-⑳])', "`n" }) -join "`n"
  $hasShiba = $s.Shiba.Count -gt 0
  $telopH = $(if ($hasShiba) { 430 } else { 560 })
  $fTelop = Get-FitFont $g $telop $font 54 30 1680 $telopH
  if ($bg) { $g.FillRectangle($panel, 0, 0, $W, 170); $g.FillRectangle($panel, 0, 380, $W, 700) }
  $g.DrawString('大人のスマホAI生活', $fSmall, $gray, 110, 50)
  $g.DrawString(('{0} / {1}' -f $index, $total), $fSmall, $blue, 1700, 50)
  if ($s.Placeholder) { $g.DrawString('〔実機撮影後に差し替え〕', $fSmall, $blue, 1250, 50) }
  $g.FillRectangle($blue, 90, 130, 16, 200)
  $g.DrawString($s.Title, $fTitle, $white, (New-Object System.Drawing.RectangleF(130, 130, 1680, 200)))
  $g.DrawString($telop, $fTelop, $white, (New-Object System.Drawing.RectangleF(130, 400, 1680, $telopH)))
  $fShiba = $null
  if ($hasShiba) {
    $shibaText = 'しば研究員：' + $s.Shiba[0]
    $fShiba = Get-FitFont $g $shibaText $font 44 28 1640 150
    $shibaBg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(245, 255, 214, 102))
    $navyBrush = New-Object System.Drawing.SolidBrush($navy)
    $g.FillRectangle($shibaBg, 110, 870, 1700, 170)
    $g.DrawString($shibaText, $fShiba, $navyBrush, (New-Object System.Drawing.RectangleF(140, 885, 1640, 150)))
    $shibaBg.Dispose(); $navyBrush.Dispose(); $fShiba.Dispose()
  }
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $pt = $fTelop.Size
  foreach ($o in $g, $bmp, $blue, $gray, $panel, $fSmall, $fTitle, $fTelop) { $o.Dispose() }
  return $pt
}

# ---------- 3. 音声 ----------
$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$ja = @($synth.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo } | Where-Object { $_.Culture.Name -eq 'ja-JP' })
if ($ja.Count -gt 0) { $synth.SelectVoice($ja[0].Name) }
$synth.Rate = $TtsRate

function Get-Duration([string]$file) {
  [double](& ffprobe -v error -show_entries format=duration -of csv=p=0 $file)
}

# Render the ordered shots to a silent 1920x630 strip, then use the existing
# overlay+voice path for the scene. This preserves original audio isolation.
function Build-ShotVideo($s) {
  if (-not $ShotMap.ContainsKey($s.Id)) { return $null }
  $items = @($ShotMap[$s.Id])
  $assetDir = Join-Path $Ep 'assets'
  foreach ($shot in $items) {
    $src = Join-Path $assetDir $shot.file
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
      if ($Release) { throw "Missing ordered shot: $src" }
      Write-Warning "Draft fallback: missing ordered shot $src"
      return $null
    }
  }
  $clipList = @()
  $n = 0
  foreach ($shot in $items) {
    $n++
    $src = Join-Path $assetDir $shot.file
    $clipName = ('{0}_shot{1:00}.mp4' -f $s.Id, $n)
    $clip = Join-Path (Join-Path $Out 'scenes') $clipName
    $duration = ([double]$shot.seconds).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
    $filter = 'scale=1920:630:force_original_aspect_ratio=decrease,pad=1920:630:(ow-iw)/2:(oh-ih)/2:color=0x0D1930,fps=30,setsar=1'
    if ($shot.file -match '\.(png|jpe?g)$') {
      & ffmpeg -hide_banner -loglevel error -y -loop 1 -framerate 30 -i $src -t $duration -vf $filter -an -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p -r 30 $clip
    } else {
      # Do not replay smartphone gestures when a recording is shorter than its allocated shot.
      # Hold the final frame instead; -t still trims clips longer than the shot.
      & ffmpeg -hide_banner -loglevel error -y -i $src -t $duration -vf "$filter,tpad=stop_mode=clone:stop_duration=300" -an -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p -r 30 $clip
    }
    if ($LASTEXITCODE -ne 0) { throw "Ordered shot encoding failed: $($s.Id) $($shot.file)" }
    $clipList += "file '$clipName'"
  }
  $scenesDir = Join-Path $Out 'scenes'
  $listName = "$($s.Id)_shots.txt"
  [IO.File]::WriteAllLines((Join-Path $scenesDir $listName), $clipList, [Text.Encoding]::ASCII)
  $combined = Join-Path $scenesDir "$($s.Id)_shots.mp4"
  Push-Location $scenesDir
  try {
    & ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i $listName -c copy $combined
    if ($LASTEXITCODE -ne 0) { throw "Ordered shot concatenation failed: $($s.Id)" }
  } finally { Pop-Location }
  return Get-Item -LiteralPath $combined
}

# ---------- 4. シーン動画化 ----------
$report = @(); $chapters = @(); $t = 0.0; $i = 0
$concat = @()
foreach ($s in $scenes) {
  $i++
  $slide = Join-Path $Out "scenes\$($s.Id).png"
  $rec = Build-ShotVideo $s
  $shotCount = $(if ($rec) { @($ShotMap[$s.Id]).Count } else { 0 })
  if (-not $rec) { $rec = Find-SceneFile 'assets' $s.Id $VideoExt }
  $telopPt = New-Slide $s $i $scenes.Count $slide (Find-SceneFile 'assets' $s.Id $ImageExt) ([bool]$rec)
  if ($Release -and $telopPt -lt 36) { throw "Release blocked: unreadable caption size $telopPt pt in $($s.Id)" }
  $voice = Find-SceneFile 'audio' $s.Id $AudioExt
  if ($voice) { $voicePath = $voice.FullName; $src = 'file' }
  else {
    $voicePath = Join-Path $Out "scenes\$($s.Id)_tts.wav"; $src = 'tts'
    $synth.SetOutputToWaveFile($voicePath)
    $synth.Speak((Get-ReadingText (($s.Narration) -join "`n")))
    $synth.SetOutputToNull()
  }
  $part = Join-Path $Out "scenes\$($s.Id).mp4"
  $leadMs = [int]($LeadSec * 1000)
  $af = "[1:a]aresample=48000,aformat=channel_layouts=stereo,adelay=${leadMs}|${leadMs},apad=pad_dur=$TailSec[a]"
  if ($rec) {
    # 画面録画：録画の音は使わない。シーン長は「録画」と「ナレーション＋前後の間」の長い方。
    # 録画が短い場合は最後のコマで止め、長い場合はナレーションの後を無音で続ける。
    $dur = [Math]::Max((Get-Duration $rec.FullName), (Get-Duration $voicePath) + $LeadSec + $TailSec)
    $vf = "[0:v]fps=30,scale=1920:630:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:170+(630-ih)/2:color=0x0D1930,tpad=stop_mode=clone:stop_duration=3600[bgv];[bgv][2:v]overlay=0:0[v];[1:a]aresample=48000,aformat=channel_layouts=stereo,adelay=${leadMs}|${leadMs},apad[a]"
    & ffmpeg -hide_banner -loglevel error -y -i $rec.FullName -i $voicePath -loop 1 -framerate 30 -i $slide -filter_complex $vf -map '[v]' -map '[a]' -t $dur -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p -r 30 -c:a aac -b:a 192k -ar 48000 $part
    $src = $(if ($shotCount -gt 0) { "${src}+shots:$shotCount" } else { "${src}+rec" })
  } else {
    & ffmpeg -hide_banner -loglevel error -y -loop 1 -framerate 30 -i $slide -i $voicePath -filter_complex $af -map 0:v -map '[a]' -shortest -c:v libx264 -preset veryfast -tune stillimage -crf 20 -pix_fmt yuv420p -r 30 -c:a aac -b:a 192k -ar 48000 $part
  }
  if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed: $($s.Id)" }
  $d = Get-Duration $part
  $chapters += ('{0}:{1:00} {2}' -f [int][Math]::Floor($t / 60), [int][Math]::Floor($t % 60), $s.Title)
  # TelopPt：テロップが枠に収まるよう縮めた後の大きさ。36未満は読みにくいので文言を減らす目安
  $report += [pscustomobject]@{ Scene = $s.Id; Title = $s.Title; Sec = [Math]::Round($d, 1); Chars = (($s.Narration) -join '').Length; Audio = $src; Placeholder = $s.Placeholder; TelopPt = $telopPt; Small = $(if ($telopPt -lt 36) { '!' } else { '' }) }
  $t += $d
  $concat += "file 'scenes/$($s.Id).mp4'"
}

# ---------- 5. 連結とラウドネス正規化 ----------
[IO.File]::WriteAllLines((Join-Path $Out 'concat.txt'), $concat, [Text.Encoding]::ASCII)
Push-Location $Out
& ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i concat.txt -c copy joined.mp4
if ($LASTEXITCODE -ne 0) { Pop-Location; throw 'concat failed' }
& ffmpeg -hide_banner -loglevel error -y -i joined.mp4 -c:v copy -af 'loudnorm=I=-14:TP=-1.5:LRA=11' -c:a aac -b:a 192k -ar 48000 -movflags +faststart "$EpName.mp4"
if ($LASTEXITCODE -ne 0) { Pop-Location; throw 'loudnorm failed' }
Remove-Item joined.mp4
Pop-Location

$final = Join-Path $Out "$EpName.mp4"
$total = Get-Duration $final
[IO.File]::WriteAllLines((Join-Path $Out 'chapters.txt'), $chapters, (New-Object Text.UTF8Encoding($true)))
$report | Format-Table -AutoSize | Out-String -Width 200 | Out-File (Join-Path $Out 'report.txt') -Encoding utf8
$report | Format-Table -AutoSize | Out-String -Width 200
'TOTAL={0}:{1:00} ({2:N1}s)  OUTPUT={3}' -f [int][Math]::Floor($total / 60), [int][Math]::Floor($total % 60), $total, $final
