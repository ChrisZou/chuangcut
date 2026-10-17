# V1 verification — 2026-10-17

Environment: Apple M2 Pro / arm64, macOS 26.3, Xcode 26.6, Swift 6.3 compiler in Swift 5 language mode, deployment target macOS 14. ffmpeg 9.0.1 and local whisper.cpp; no libass filters.

## Build and tests

- `cd Packages/ChuangCutCore && swift build`: **passed**.
- `swift test`: **22 tests, 0 failures**. Coverage includes word-level merged-segment retakes, contextual/repeated fillers, stutters, acoustic boundary joins, leading/trailing silence, overlapping/disabled/clamped cuts, subtitle lengths/timing/Latin boundaries, damaged UTF-8 token recovery, running-process cancellation, and native subtitle PNG sequences.
- `xcodegen generate`: **passed**; generated project committed.
- `xcodebuild -project ChuangCut.xcodeproj -scheme ChuangCut -configuration Debug -derivedDataPath build/DerivedData build`: **BUILD SUCCEEDED**.
- Only the standard “No AppIntents.framework dependency found” metadata warning appeared. No Swift build warnings/errors.

## Real media pipeline

Executed the required headless pipeline with the installed `ggml-large-v3-turbo-q5_0.bin` and `--burn`, including a fresh transcription followed by cached reruns. DTW with `-nfa` corrected severely collapsed filler timestamps from the ordinary Whisper output.

```sh
Packages/ChuangCutCore/.build/debug/chuangcut-cli \
  ~/code/ai/chuangcut-testdata/test_zh.mp4 \
  --out ~/code/ai/chuangcut-testdata/out --burn

python3 Scripts/verify_fixture.py \
  ~/code/ai/chuangcut-testdata/test_zh.mp4 \
  --out ~/code/ai/chuangcut-testdata/out
```

Final result:

- Original: **25.186 s**.
- Edited continuous timeline: **16.057 s**; **9.129 s removed**.
- ffprobe MP4 duration: **16.067 s** for both plain and burned outputs.
- Both outputs contain **H.264 video + AAC audio** and pass a full ffmpeg decode without errors.
- Seven enabled candidates; overlapping ranges merge to three removed intervals.

| Kind | Source interval (s) | Content |
|---|---:|---|
| Pause | 2.844–4.400 | 1.756 s acoustic gap, minus padding |
| Retake | 4.400–7.367 | First 今天我们来聊医疗视频剪辑 |
| Pause | 7.367–8.096 | 0.929 s acoustic gap, minus padding |
| Filler | 8.096–8.825 | 嗯 |
| Filler | 8.795–9.585 | 那个 |
| Pause | 12.370–13.710 | 1.539 s acoustic gap, minus padding |
| Pause | 21.313–22.361 | 1.249 s acoustic gap, minus padding |

The second take starts around **9.57 s** and is kept. Retake boundaries join neighboring acoustic pauses to avoid residual syllables.

Five subtitle cues are monotonic, non-overlapping, within the edited duration, at most 16 CJK characters per line, and have no trailing punctuation. The repeated sentence appears once; 嗯/那个 are absent. Final cue text:

```text
大家好 欢迎来到我的频道
今天我们来聊医疗视频剪辑
首先 我们需要导入一段视频 然后
软件会自动识别停顿和重复的句子
最后 导出剪辑好的视频
```

CoreText/CoreGraphics PNG → ffconcat → overlay burn-in succeeded on the installed ffmpeg without libass. Frames at 1.8 s and 8.5 s were extracted and visually inspected; Chinese subtitles are visible and correctly positioned. The verifier writes `verification-summary.txt` and `burned-1.png` / `burned-2.png` beside the outputs.

## Native app checks

Verified the running app through native accessibility and screenshots:

- `--open … --auto-transcribe` loads the fixture and cached transcript; final toolbar shows **25.2s → 16.1s**, with waveform and seven candidates.
- Transcript renders red retake strikethrough, orange filler strikethrough, blue inline pause pills, timestamp prefixes and current-word highlighting.
- Disabling a retake updates edited duration and changes its text to a faint dotted underline; enabling restores the cut.
- Selecting 欢迎来到我的频道 and pressing Delete creates a purple manual cut and updates duration. `⌘Z` removes it and restores the original candidates.
- Seeking into the enabled earlier take and starting playback advances beyond it through Preview cuts.
- Export sheet offers hardware/software quality, SRT, burn-in, and all font/size/color/outline/margin/line-length controls. Expanded controls and readable live PNG preview were inspected.
- A burned export initiated from the app completed, returned to the editor with the Finder reveal checkmark, and had both audio/video streams.
- Settings show the existing local model, explicit tool paths, Chinese default, 0.60 s threshold, 0.10 s padding, and configured filler list.
- Fixed a first-launch blocking directory scan by deferring model discovery to the background and excluding protected Downloads from startup.

## Verification scope

The existing model was used; a multi-gigabyte model was not re-downloaded solely for verification. Downloads use URLSession delegates with progress, cancellation and HTTP/file validation but their full network completion was not exercised. The tested media is the supplied SDR Mandarin fixture; HDR, unusual rotation/aspect metadata, multi-hour inputs and other languages need further real-media coverage. Heuristic and timing limitations are documented in README.md.

## Timeline and polish verification

- New pure tests cover inward/outward left/right trims, overlapping merged gaps, full-gap restoration/clamping, minimum duration, manual edge cuts, snapping, persistent split boundaries, and subtitle exclusion/retiming after trims. Chinese punctuation, legacy JSON decoding, inner punctuation preference and balanced line examples also pass.
- `Scripts/verify_fixture.py … --out ~/code/ai/chuangcut-testdata/polish-base --trim-out ~/code/ai/chuangcut-testdata/polish-trim` passed. Both runs used `--burn`; all four videos have video/audio and fully decode.
- Baseline continuous timeline **16.057356 s**, MP4 **16.067 s**. Repeated trims `1:right:12.9` and `2:left:14.5` produce **15.796772 s**, MP4 **15.800 s**. Exact expected continuous delta: **−0.260584 s**. Newly cut “首先” disappears from the SRT; later cues are retimed monotonically.
- Native UI: dragged selected clip 2's right handle inward by 0.5 s; sidebar range changed to 20.81–22.36 with Adjusted badge, edited duration decreased by 0.5 s and transcript “句子” became struck through. Undo and redo restored/reapplied both ranges and text.
- Native UI: Delete created a manual cut for the selected clip; Cmd-B split then Delete removed only the selected half. Undo restored each operation. Sidebar retake toggle changed duration to 19.0 s and restored the take's text; undo returned 16.1 s. Escape deselected the clip.
- Launch hooks selected clip 2, set 60 points/s zoom, applied both trims, sought to 14.5 s and opened Export after detection. Fresh launches stayed paused at 0 s. Light/dark layouts, fixed timestamp gutter, rounded pause pills, thumbnail strips and media-card metadata were visually inspected.
- `--show-settings` opened the native Settings window after load; the Subtitles tab showed the video-backed preview and enabled inner-punctuation preference. Compact Export sheet was checked with the filename preserved in the parent window title.
- Screenshot artifacts are in `~/code/ai/chuangcut-testdata/shots/` (`polish-*.png`), outside the repository.
