# tools/video — 台本から動画を組み立てる

`build-episode.ps1` は、`episodes/<回>/script.md` から YouTube 用の MP4（1920×1080・30fps・AAC 48kHz・-14 LUFS）を組み立てます。
PC04 の PoC（`Documents\ks04\youtube-video-poc\build.ps1`）を本番用に拡張したものです。

## 必要なもの（PC04 で確認済み）

- Windows PowerShell 5.1（System.Drawing／System.Speech）
- FFmpeg / ffprobe（PATH 上にあること）
- フォント：Yu Gothic

外部サービスへの通信や課金は発生しません。

## 使い方

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/video/build-episode.ps1
# 一部のシーンだけ試す
powershell -NoProfile -ExecutionPolicy Bypass -File tools/video/build-episode.ps1 -Only S01,S09
```

出力先は `build/<回>/` です（Git 管理外）。

- `<回>.mp4`：完成動画
- `chapters.txt`：概要欄用のチャプター
- `report.txt`：シーンごとの秒数・字数・音声の種類
- `scenes/`：シーン画像・シーン動画

## 素材の差し替え

| 置く場所 | 使われ方 |
|---|---|
| `episodes/<回>/audio/Sxx.mp3`（.wav/.m4a） | そのシーンの本番ナレーション（ElevenLabs など）。無ければ Windows TTS の仮音声 |
| `episodes/<回>/assets/Sxx.png`（.jpg） | そのシーンの背景（実機スクショ・生成画像）。テロップは上に重ねる |
| `episodes/<回>/assets/Sxx.mp4`（.mov） | そのシーンの画面録画（画像より優先）。上下の帯（タイトル／テロップ）の間に表示し、録画の音は使わない。シーンの長さは「録画」と「ナレーション＋前後の間」の長い方。録画が短いときは最後のコマで止める |

## 下書きと公開用

- 通常（下書き）：仮音声・〔差し替え〕が残っていても書き出す。プレビュー用。
- `-Release`（公開用）：全シーンに本番音声があり、〔差し替え〕が無いときだけ書き出す。1つでも残っていれば中止し、足りないものを一覧で表示する。`-Only` とは併用できない。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/video/build-episode.ps1 -Release
```

公開前は、`-Release` で書き出した MP4 を通しで見て、発音・音と画面のずれ・テロップの読みやすさを確認すること（自動では確認できない）。

台本の書式（`## Sxx`、`【テロップ】`、`【テロップ（しば研究員）】`、`ナレーション：`、`〔差し替え…〕`）は `episodes/001-sms-ai-check/script.md` を参照してください。`〔差し替え…〕` の行は読み上げず、画面に「実機撮影後に差し替え」と表示します。
