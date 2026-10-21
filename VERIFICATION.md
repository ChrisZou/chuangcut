# V1 verification — 2026-10-17

Environment: Apple M2 Pro / arm64, macOS 26.3, Xcode 26.6, Swift 6.3 compiler in Swift 5 language mode, deployment target macOS 14. ffmpeg 9.0.1 and local whisper.cpp; no libass filters.

## Build and tests

- `cd Packages/ChuangCutCore && swift build`: **passed**.
- `swift test`: **26 tests, 0 failures**. Coverage includes word-level merged-segment retakes, contextual/repeated fillers, stutters, acoustic boundary joins, leading/trailing silence, overlapping/disabled/clamped cuts, subtitle lengths/timing/Latin boundaries, damaged UTF-8 token recovery, running-process cancellation, and native subtitle PNG sequences.
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

Six subtitle cues are monotonic, non-overlapping, within the edited duration, at most 16 CJK characters per line, and have no trailing punctuation. The repeated sentence appears once; 嗯/那个 are absent. Final cue text:

```text
大家好 欢迎来到我的频道
今天我们来聊医疗视频剪辑
首先 我们需要导入一段视频
然后 软件会自动识别
停顿和重复的句子
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

## Final refinements

- `swift test`: **26 tests, 0 failures**. Added coverage for all ten requested connectives, an unlisted short clause, strict majority coverage from either side, disjoint/overlapping cut unions, exact-half ties, zero-duration tokens, disabled cuts, shared transcript/subtitle classification, pause insertion before a partly covered word, live pause labels, legacy JSON label migration, and sentence boundaries whose punctuation is removed by a cut.
- Debug `xcodebuild`: **BUILD SUCCEEDED**, with only the standard AppIntents metadata warning.
- Re-ran `Scripts/verify_fixture.py … --out ~/code/ai/chuangcut-testdata/refine-base --trim-out ~/code/ai/chuangcut-testdata/refine-trim`. Both CLI runs use `--burn`. All four videos contain H.264 + AAC and fully decode. Baseline MP4 remains **16.067 s**; trimmed MP4 remains **15.800 s**, matching the exact continuous-time delta **−0.260584 s** within frame rounding.
- Six subtitle cues now keep “然后” with its following phrase. No trailing punctuation, filler/retake duplicates, stranded connectives, overlapping cue times, or out-of-duration cues. The trimmed SRT omits “首先” and retimes all later cues.
- CLI candidates now print `[x]` / `[ ]` and `(adjusted)`. Pause text is the current cut duration; for example the paired trims produce `[x] pause 12.900–14.500 ⏸ 1.6s (adjusted)`.
- Native test: launched paused with clip 0 selected at 60 pt/s, then dragged **unselected** clip 2's right edge. It auto-selected, snapped to **20.27 s**, and reduced the edited duration to **15.0 s**. The sidebar showed **20.27–22.36, ⏸ 2.1s, Adjusted**; the transcript placed the **⏸ 2.1s** capsule before struck-through “重复的句子”. The selected clip has solid 12 pt yellow bars, rounded outer corners, dark double grips and a matching 2 pt border. Handle cursor/hit areas cover unselected clips too.
- Screenshot: `~/code/ai/chuangcut-testdata/shots/refine-handles.png`.

Exact edge regression: `chuangcut-cli test_zh.mp4 --out ~/code/ai/chuangcut-testdata/refine-edge --burn --trim 2:right:20.27` also passed. The continuous timeline is **15.014627 s** and both MP4s are **15.033333 s**, contain video/audio and fully decode. CLI prints `[x] pause 20.270–22.361 ⏸ 2.1s (adjusted)`. SRT excludes “重复的句子” and preserves “最后 导出剪辑好的视频” as a separate cue even though the preceding sentence's punctuation was cut.

## Robustness and long-video fixes

- `swift test`: **35 tests, 0 failures**. New `RobustnessTests` cover 额度/金额 not being treated as the 额 filler, reduplicated words (体验体验, 研究研究, 哈哈哈哈), parallel clauses, rotated video display size, word-to-silence alignment for quiet audio, subtitles without sentence punctuation, and a long synthetic transcript with a time bound.
- The rewritten clause splitter and `TimelineMapper` binary search were compared against the previous implementations on 3,000 random transcripts; outputs were identical.
- `Scripts/verify_fixture.py` still passes with `--trim-out`: **16.057356 s → 15.796772 s**, delta **−0.260584 s**.
- A 28.5-minute synthetic Mandarin recording ran through the CLI with `--burn` in about 6 minutes: **1709.8 s → 1506.3 s**, 734 cues, both MP4s 1506.36 s. 额度 survives (70 cues), no isolated 嗯/那个 remain.
- Main-thread stalls on that recording, old build → fixed build: toggling one cut **189.9 s → 0.20 s**, undo **130.5 s → 0.25 s**, loading a cached project **87.8 s → 0.46 s**.
- A rotated phone recording now exports at its 720×1280 display size with subtitles placed for that frame. A quieter copy of the fixture now produces the same six subtitle cues as the original instead of dropping 今天 and 辑.

## Long-video responsiveness

Measured on the regenerated 28.5-minute recording (`~/code/ai/chuangcut-testdata/long/long.mp4`) with a temporary, uncommitted harness that reports the worst main-thread stall per action, plus Time Profiler traces.

| Action | Before | After |
|---|---:|---:|
| 30 trim-drag events at 60 Hz | 2.35 s | 0.77 s |
| Main thread busy during playback | ~100% | ~22% |
| Transcript rebuild + re-render | 212 ms | 28 ms |
| Toggle one cut | 124 ms | 94–148 ms |

- `EditorModel` uses Observation, so the 35 ms playhead tick only refreshes the time labels, timeline and transcript highlight instead of the sidebar, every visible row and the menu bar.
- Sidebar rows are equatable; the menu bar reads `hasProject` and undo state instead of the whole project.
- Transcript drawing looks up timestamps only for visible lines instead of laying out the whole transcript on every redraw.
- `pauseInsertionIndices` replaces a per-pause linear scan; it matched the single lookup on 1,800 random unsorted, overlapping and zero-length word sets.
- Project JSON is written on a serial background queue and flushed on quit. A relaunch restored the last toggle state.
- Fixed a pre-existing preview-cuts freeze: seeking to a cut end such as 13.709604 s rounds to 13.7096 s at the 1/60000 timescale, which still lies inside the cut and re-triggered the skip. Playing from that point stalled on the old build and plays immediately now.
- Native checks through accessibility: toggling a cut updated the sidebar count, duration, window subtitle and timeline; Edit showed **Undo Toggle cut** / **Redo Toggle cut**; one ⌘Z undid exactly one of two toggles; playback advanced the time labels, timeline playhead and transcript highlight; Export and Settings opened with the subtitle preview.

## AppKit editor window

The editor window (toolbar, split layout, sidebar, player, transcript, timeline, menus) is now AppKit; Settings and Export stay SwiftUI forms hosted in AppKit. Views subscribe to the `@Observable` model through a small `Observer` that reruns one update per main-loop turn, with separate observers per concern so the playhead tick never rebuilds clips, rows or text.

| 28.5-minute recording, worst main-thread stall | SwiftUI shell (93706e7) | AppKit |
|---|---:|---:|
| Toggle one cut | 94–148 ms | 46–55 ms |
| Undo | 109–118 ms | 52–70 ms |
| 30 trim-drag events at 60 Hz | 0.77 s, worst 81–91 ms | 0.69 s, worst 36–40 ms |
| Playback | worst 47–60 ms, ~22% main thread | worst 9–10 ms, ~16% main thread |

- `swift test`: 36 tests, 0 failures. Debug `xcodebuild`: BUILD SUCCEEDED with no Swift warnings.
- Native checks through accessibility on the fixture: toggling a cut updated the sidebar, durations, window subtitle and timeline; ⌘Z used the native Edit menu (**Redo Toggle cut**, **Undo Split clip**); Space, ←/→ and ⌘B worked; selecting a clip then Delete created a manual cut and Escape deselected it; dragging a clip edge trimmed a pause to 20.48 s with an **Adjusted** badge; selecting transcript text then Delete created a manual cut; sidebar row clicks seek, and the group checkbox toggles all fillers.
- Space and Delete typed into the Export sheet's Font field and the Settings Fillers field instead of playing or removing clips. Escape closed the Export sheet. The Transcribe-again confirmation and its Cancel worked. The empty state, the processing bar and timeline auto-scroll during playback were checked on screen.
- AVPlayerView's Live Text analysis of a paused frame used to take first responder from the timeline, which is why the old shell tracked timeline focus itself. It is now disabled (`allowsVideoFrameAnalysis = false`).

## Fillers only at sentence edges

- Fillers inside a sentence are no longer cut; only those opening or closing a sentence (after 。！？, a Whisper segment end or a pause of at least the threshold) are. `RobustnessTests.testFillersAreCutOnlyAtSentenceEdges` covers mid-sentence 额/嗯/那个, sentence-initial and final fillers, pause boundaries and unpunctuated segment ends.
- Re-running detection on every cached test project gave identical filler and retake cuts (28.5-minute recording: 48 fillers, 31 retakes; fixture: 2 fillers, 1 retake), because each of their fillers follows a sentence end or a cut pause.
- `swift test`: 37 tests, 0 failures. Debug `xcodebuild`: BUILD SUCCEEDED. `Scripts/verify_fixture.py` passed both the base and trimmed runs.

## Keeping only the last take

- A real retake-heavy recording (C5245.MP4, 4:51, ~80 Whisper segments of repeated attempts) kept 1:55.8 with the old rule, including two complete copies of the opening and five of 「我把我之前在字节面试过四五百号人」. With the new rule it keeps 43.5 s that read as one pass of the script. Remaining leftovers are reworded attempts (「里面有大量你意识」, 「你意想不到的事情」) and a Whisper hallucination (「请不吝点赞 订阅 转发…」) over real speech.
- `RobustnessTests` adds multi-sentence takes restarted from different points, a take split by a pause, a word-order rewording, distinct sentences sharing an opening, a legitimate 「所以，」, a repeat outside the 45-second window, a pause inside a word, and a word stretched over a pause. `swift test`: 41 tests, 0 failures.
- Detection on the 28.5-minute synthetic recording takes 1.8 s in a debug build. That script repeats near-identical paragraphs every 25 seconds, so it now loses most of them; it remains a performance fixture, not a false-positive check.
- In the app: Detect on C5245 gave 00:43.5 edited. Clicking a kept transcript word seeked to it (source 00:36.7); clicking a removed word seeked to its cut's start (00:00.1, inside a 32.5 s run of earlier takes). A pause pill toggled 43.5 → 44.0 → 43.5 s; dragging over text selected it without seeking, Delete cut it and ⌘Z restored it.

## Verbatim transcription with Doubao

- No whisper-cli setting makes Whisper verbatim. On the first minute of C5245 (225 characters as spoken, 我们都知道 nine times), large-v3-turbo gave 189 characters and six; beam vs greedy, no temperature fallback, a raised entropy threshold, `-mc 0` and Silero VAD segmentation gave 99–213 characters, the best of them with garbage tokens (furnit, AIA.I.). A disfluent `--prompt` either collapsed the repeats or looped 我们都知道 74 times. Per-pause chunks were closest (1035 characters for the whole file) but five times slower and with more typos.
- Doubao Seed-ASR returned 224 characters for that minute and 1109–1233 for the file, every restart included, with the correct idioms (报这一箭之仇, 以其道治其身) and no hallucinated ending. The flash endpoint took 3.8 s for 4:51 and 11.8 s for 28.5 minutes (10 MB MP3 inline); its per-character timestamps show real pauses.
- With the new restart rules C5245 keeps 35.9 s from either of two Doubao runs, reading as one pass of the script; the only leftover is the reworded 「里面有大量，你意思不，」. Word-less slivers between cuts had added 6.5 s before bridging.
- `swift test`: 45 tests, 0 failures (Doubao parsing, restarts within a clause, words glued to a restart, slivers, 一步一步). `Scripts/verify_fixture.py` passed base and trimmed runs with Whisper; with Doubao the fixture gives the same pauses, retake and fillers, and 一聊 instead of Whisper's 医疗. The 28.5-minute file: 2.7 s detection from cache (Whisper), 17 s transcription plus detection (Doubao).
- In the app: Settings › Transcription shows the engine picker, key and hotword table; Transcribe on C5245 finished in 6.6 s, and Detect gave 00:35.9 edited.

## Tighter clips and a seamless preview

- Kept clips used to start wherever a cut ended: 0.1 s before a silence ended, or at the end of a removed word, so 0.4–0.56 s of room tone could precede the first word. They now follow a 10 ms loudness envelope: on C5245 every clip starts 0.03–0.04 s before its first word crosses -45 dB and ends 0.06–0.07 s after its last word does. Clips with no words (0.1 s at either end, a 0.25 s burp between two pauses) are cut.
- The reworded 「里面有大量，你意思不，」 is now an earlier take. C5245 keeps 32.5 s in seven clips, the same for both Doubao transcripts. The fixture keeps 16.006 s; `Scripts/verify_fixture.py` passed base and trimmed runs. Detection on the 28.5-minute file takes 3.8 s in a debug build (loudness via vDSP; decoding the audio is 0.7 s of it).
- The transcript's text view had no maxSize, so it never grew and could not scroll; it now scrolls and follows playback.
- Preview: exact seeks on the 4K HEVC source stalled 121–141 ms at each join (measured with a standalone AVPlayer). With the composition, playing 12 s across two joins kept wall-clock minus edited time constant at 0.6–0.7 s (the start-up delay). Toggling Preview off and on, toggling a cut and undoing it kept the source position.
- `swift test`: 47 tests, 0 failures.

## Simpler editor window

- The toolbar holds only Import and Export; the media/cut sidebar is gone. Split moved to the timeline header; Transcribe Again…, Detect Cuts Again, Preview Cuts and Snap Trim Edges are in a new Clip menu (Playback keeps play and seek). A video without a transcript is transcribed when it opens.
- In the app: the window shows player, transcript and timeline only; the Clip menu lists its seven commands; Split at 00:05 made eight clips and ⌘Z restored seven.

