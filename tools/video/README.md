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
- `-Release`（公開用）：全シーンに本番音声があり、〔差し替え〕が無く、台本に【素材】があるシーンには `assets/Sxx.*` があるときだけ書き出す。1つでも残っていれば中止し、足りないものを一覧で表示する。`-Only` とは併用できない。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/video/build-episode.ps1 -Release
```

`report.txt` の `TelopPt` は、テロップを枠に収めるために縮めた後の文字の大きさです。36未満（`Small` 欄に `!`）のシーンは文言を減らしてください。

スマホアプリの実演シーンには、スマホ実機の撮影素材だけを使います。PC の画面録画で代用しません。

公開前は、`-Release` で書き出した MP4 を通しで見て、発音・音と画面のずれ・テロップの読みやすさを確認すること（自動では確認できない）。

台本の書式（`## Sxx`、`【テロップ】`、`【テロップ（しば研究員）】`、`ナレーション：`、`〔差し替え…〕`）は `episodes/001-sms-ai-check/script.md` を参照してください。`〔差し替え…〕` の行は読み上げず、画面に「実機撮影後に差し替え」と表示します。

## 1シーン内の複数カット（S04・S06・S07・S08・S10・S11）

`episodes/001-sms-ai-check/shots.json` でカットの順番・ファイル名・表示秒数を指定します。各カットは `assets/S04_01.png`、`assets/S06_01.mp4` などに保存してください。画像と動画を混在させられます。素材の音声は使わず、従来どおりシーン単位のナレーションを重ねます。

- S04：SMSの3例（3カット）
- S06：iPhone・Androidなどの準備操作（3カット）
- S07：ChatGPT実機の質問入力・送信・回答（3カット）
- S08：Gemini実機の同一質問・送信・回答（3カット）
- S10：公式窓口での確認方法（3カット）
- S11：iPhone・Androidの迷惑SMS設定（2カット）

S07・S08は**実際のスマホアプリで得た回答**を記録し、台本の〔差し替え〕を事実に合わせて更新してください。S07・S08・S11は単一の`Sxx.mp4`だけでは公開判定を通しません。`shots.json`の秒数は仮値であり、実映像と本番ナレーションを見て調整します。

カット素材が未配置の場合、通常のプレビューでは従来の静止画に戻ります。`-Release` は必要な全カットがないと失敗します。秒数は素材完成後にナレーションに合わせて調整してください。スマホ操作を示す素材はスマホ実機で撮影し、PC録画を代用しないでください。

外部通信・課金なしの回帰テスト：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/video/test-multishot.ps1
```

テストは合成画像・合成動画・無音音声を一時生成して6シーン（計17カット）を結合し、終了後に削除します。テロップの最小サイズを確保するため、画面録画の上下帯では原則1つの要点のみ表示します。詳細はナレーションと実機映像で伝えてください。
