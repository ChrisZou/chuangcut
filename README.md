# ChuangCut

A native macOS editor for removing pauses, fillers, and earlier takes from spoken video. Processing stays on your Mac. The editor window is AppKit; Settings and the Export sheet are SwiftUI forms. It uses AVFoundation, whisper.cpp, and ffmpeg.

## Build and run

Requires macOS 14+, Xcode, Swift 5.9+, ffmpeg/ffprobe, and whisper-cli. No third-party Swift dependencies.

```sh
cd Packages/ChuangCutCore
swift build
swift test
cd ../..
xcodegen generate
xcodebuild -project ChuangCut.xcodeproj -scheme ChuangCut \
  -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/ChuangCut.app
```

The generated `ChuangCut.xcodeproj` is committed; open it directly if you do not need to regenerate. This development build uses **ad-hoc signing**, no sandbox, and no hardened runtime, as requested for V1. It is not a notarized distribution build.

For automated launch:

```sh
build/DerivedData/Build/Products/Debug/ChuangCut.app/Contents/MacOS/ChuangCut \
  --open /absolute/path/video.mp4 --auto-transcribe --select-segment 2 --zoom 60
```

The app opens the video, reuses a matching cached transcript, and detects cuts. Opening without `--auto-transcribe` restores saved candidate toggles and manual edits. Transcribe/Detect intentionally recompute detected candidates but keep manual cuts and splits; both can be undone. Transcribing a project that already has a transcript asks for confirmation first.

Screenshot hooks run after loading/analysis: `--seek <sourceSeconds>`, `--select-segment <zeroBasedIndex>`, repeatable `--trim <index>:<left|right>:<sourceSeconds>`, `--zoom <pointsPerSecond>`, `--show-export`, and `--show-settings`. `--appearance light|dark` changes only this app instance for screenshot testing. Opening and auto-transcription always start paused at zero unless `--seek` is supplied.

To test dragging an **unselected** clip edge, launch with `--select-segment 0 --zoom 60`, then drag clip 3's right edge without clicking its body first. CLI/app `--trim` indices are zero-based; times in `--trim` and `--seek` are source seconds. Keyboard controls are Space (play/pause), ←/→ (±5 s), ⌘B (split), Delete (remove selected clip), Escape (deselect), ⌘Z / ⇧⌘Z (undo/redo). Space and the arrows work whenever the editor window is key; Delete and Escape act on the timeline only while it has focus, so they still edit text in the transcript, the Export sheet and Settings.

## Editing

- Drop a video into the window or use **File → Open** (`⌘O`).
- Choose **Transcribe**, then review color-coded cuts in the transcript and sidebar.
- Click a word or candidate to seek. Option-click cut text, click a pause pill, or use a checkbox to toggle a cut. Right-click provides the same actions.
- Select transcript text and press Delete to create a manual cut. `⌘Z` undoes cut changes.
- Each kind has an enable/disable-all icon. The toolbar and sidebar show the union of enabled cuts, so overlaps are never counted twice.
- The edited timeline shows consecutive kept clips with cached thumbnail strips and audio waveforms. **Show removed** switches to source time with colored hatches; Option-click a removed range to toggle it.
- Click a clip to select it and highlight its transcript words. Drag either solid yellow edge handle to remove or restore source material, with live frame preview and ripple reflow. Handles are 12 pt wide with dark grips and 16 pt hit areas; hovering an unselected clip edge shows the resize cursor, and dragging it selects the clip automatically. Edges snap to words, playhead and neighboring boundaries within 8 px; hold `⌘` or turn off **Snap** to bypass.
- A trim updates candidate ranges and shows **Adjusted** in the sidebar. Pause labels always show the actual removed duration, including adjustments, consistently in the sidebar, transcript and CLI. Overlapping candidates are adjusted together when restoring material. Clips cannot grow past the neighboring kept source range or shrink below 0.1 s.
- Double-click a clip to play, Delete removes the selected clip, Escape deselects, and `⌘B` splits at the playhead. Splits persist without deleting material. `⌘Z` / `⇧⌘Z` undo/redo trims, toggles, splits and manual cuts.
- Drag the ruler or clip body to scrub. Pinch or `⌘`-scroll to zoom around the cursor; the logarithmic slider/buttons zoom around the playhead (0.05–300 pt/s). Fit shows the whole edit, including multi-hour recordings; playback follows the playhead automatically.
- **Preview cuts** skips enabled intervals using exact AVPlayer seeks. Space plays/pauses.
- **Export** (`⇧⌘E`) chooses the destination, encoding quality, SRT output, subtitle burn-in and style. The green checkmark reveals the completed export.
- Import, transcription, detection, and export have cancellation. Partial video exports are staged and only replace the destination after success.

## Settings and models

The default language is Chinese. Auto, English, Japanese, Korean, French, German, and Spanish are available. Pause threshold defaults to 0.6 s; each side retains 0.10 s of padding.

Settings persist model/tool paths, language, fillers, thresholds, and subtitle style. The default tool lookup checks `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, then `which`; a GUI process does not depend on a shell's PATH.

Model discovery checks:

- `~/Library/Application Support/ChuangCut/models`
- `/opt/homebrew/share/whisper-cpp`
- `~/.cache/whisper`
- `~/models`
- `~/Downloads` (Settings refresh; the CLI includes it automatically)

Search is shallow and restricted to ggml `.bin` files. The app avoids scanning protected Downloads during startup. Settings refresh includes Downloads in a background task; macOS may request normal folder access. Choose also accepts a model at any other location.

Download buttons use URLSession with progress and cancellation for `ggml-large-v3-turbo-q5_0.bin`, `ggml-medium.bin`, and `ggml-small.bin` from the ggerganov/whisper.cpp Hugging Face repository. Downloads need network access; editing and transcription do not.

The recommended installed model is selected automatically from the application support models folder. DTW alignment is enabled with Flash Attention disabled for turbo/medium/small models; other models use normal token offsets. Multi-character Chinese tokens are distributed into character words. Invalid byte-token fragments are reconstructed from segment text, and Latin subwords are joined by leading-space boundaries.

## CLI

```sh
Packages/ChuangCutCore/.build/debug/chuangcut-cli input.mp4 \
  --out /tmp/chuangcut-output \
  --model "$HOME/Library/Application Support/ChuangCut/models/ggml-large-v3-turbo-q5_0.bin" \
  --lang zh --pause 0.6 --burn
```

Only the input and `--out` are required. `--model` defaults to the first discovered recommended model. `--lang auto` enables automatic language detection. Ctrl-C terminates the active subprocess.

Apply edge adjustments after detection (indices are zero-based and resolve after preceding trims):

```sh
Packages/ChuangCutCore/.build/debug/chuangcut-cli input.mp4 \
  --out /tmp/chuangcut-trimmed --burn \
  --trim 1:right:12.9 --trim 2:left:14.5
```

The CLI prints kept source ranges before/after trims and marks each candidate `[x]` enabled or `[ ]` disabled, plus `(adjusted)` for edited bounds. Fully restored candidates become disabled while retaining valid bounds; re-enabling them deliberately reinstates their cut.

Outputs:

- `transcript.json`: normalized segments and timed words
- `cuts.json`: candidate kinds, adjusted bounds, text, reasons, and enabled state
- `project.json`: complete analyzed/adjusted project
- `cut.mp4`, `cut.srt`, `cut.ass`
- With `--burn`: `cut_burned.mp4`, plus its SRT and ASS sidecars

## Pipeline and architecture

```text
ChuangCut/                         Native app
  AppDelegate.swift                App entry, main menu, Settings window
  EditorWindowController.swift     Window, toolbar, split layout, alerts, export sheet, drop target
  AppKitSupport.swift              Observer (model → AppKit updates) and small view helpers
  EditorModel.swift                Main-actor @Observable editor and playback coordination
  PlayerPanel.swift                AVPlayerView stage and transport controls
  MediaSidebar.swift               Media card and NSTableView of grouped cuts
  TranscriptView.swift             NSTextView range/word interactions
  TimelineView.swift               AppKit clip strips, trim handles, ruler and zoom
  ThumbnailStore.swift             Async AVAssetImageGenerator + bounded cache
  SubtitlePreview.swift            SwiftUI subtitle raster over a video frame
  SettingsView.swift               SwiftUI Settings tabs: models, detection, subtitles
  ExportView.swift                 SwiftUI export configuration and live preview
  AppSettings.swift                Persisted UI preferences
Packages/ChuangCutCore/
  Sources/ChuangCutCore/
    Models.swift                  Codable project, words, segments, cuts, style
    ProcessRunner.swift           Drained stdout/stderr, tool lookup, cancellation
    WhisperRunner.swift           whisper.cpp, progress, token normalization
    FFmpegRunner.swift            Probe, WAV, silence, peaks, single-pass export
    CutDetector.swift             Pure pause/filler/retake heuristics
    TimelineMapper.swift          Cut union, kept ranges, source/edit mapping
    TimelineEditor.swift          Pure edge edits and snapping
    TextNormalization.swift       CJK-dominant punctuation normalization
    SubtitleBuilder.swift         Timed, length-limited SRT and ASS
    SubtitleRenderer.swift        CoreText/CoreGraphics transparent PNG cues
    ModelManager.swift            Shallow discovery and streamed model download
    Pipeline.swift                Cached analysis and project persistence
  Sources/chuangcut-cli/           Headless pipeline
  Tests/ChuangCutCoreTests/        Pure logic and runner/renderer regression tests
Scripts/verify_fixture.py          Baseline + trimmed real-media regression
Scripts/generate_icon.swift        CoreGraphics app icon asset generation
project.yml                       XcodeGen source
ChuangCut.xcodeproj/               Ready-to-open generated project
```

The package owns all media, detection, timeline and subtitle logic. Source identity (path, size, modification time) selects `~/Library/Application Support/ChuangCut/cache/<sha256>/`. Transcripts additionally key on model identity, language, and alignment version. Cache directories contain raw Whisper JSON, normalized transcripts and `project.json`; candidate edits are saved automatically. Whisper's 16 kHz WAV input is extracted to a temporary file and deleted after transcription; WAV copies left by earlier versions are removed at app launch. Transcripts are small and are not evicted. Moving or renaming a video changes its identity, so its cached project is not found at the new location.

Acoustic `silencedetect` results are authoritative when available, avoiding false pauses inside speech from inaccurate ASR offsets. Word-only detection is supported as a fallback. Before detection, word spans are aligned to those silences: Whisper segment boundaries often absorb neighbouring silence, so words are trimmed to speech and words lying wholly inside a silence move to the speech edge they belong to. This keeps audible words in subtitles and lets clauses split at real pauses. Clauses split on punctuation and long gaps, even inside a Whisper segment. Similarity/prefix matching compares up to three following meaningful clauses within ten seconds and removes the earlier take. Fillers are cut only where they open or close a sentence: after 。！？, a Whisper segment end or a pause long enough to be cut, or before one. A filler between two pieces of content is kept, because cutting inside continuous speech breaks its rhythm. At those edges, isolated/repeated contextual filler clauses (“嗯，” “那个那个，”) and standalone hesitation tokens without punctuation (嗯、呃、额、um、uh、er) are cut; normal phrases such as “那个视频” and “这个软件” are protected. Hesitation characters count only as standalone words, so 额度、金额、名额、额外 are kept. Immediate repeats skip deliberate reduplication (哈哈哈哈, verb forms such as 体验体验/研究研究); pronoun or conjunction stutters such as 我们我们 are cut. Parallel list items that differ by an ordinal (第一个…/第二个…, 首先…/其次…) are not retakes. The default list deliberately does not include ordinary connective “然后”.

Export runs **one ffmpeg encoding pass per video**: `trim/atrim → setpts/asetpts → concat → optional overlay`. Hardware presets use `h264_videotoolbox` with source-derived bitrates; the software option uses `libx264` CRF 20. Audio is AAC 192 kb/s and MP4 has fast-start metadata. Video-only imports can be exported with a silent audio track; transcription requires audio.

Transcript models normalize ASCII pause/question punctuation in CJK-dominant segments. Subtitle cues derive from the same adjusted kept ranges as playback and export, prefer punctuation near the middle, balance long clauses using system word segmentation, and avoid tiny CJK fragments and Latin mid-word breaks. Short connectives such as 然后、但是、所以 stay with the following text; other short clause tails are penalized when choosing a break. Defaults are 16 CJK / 42 Latin characters, terminal punctuation removal, and inner Chinese pause marks replaced by spaces (configurable). Cues do not overlap and are clamped to edited duration. Disabled/restored filler cuts restore both audio and subtitle words. Transcript styling, pause-pill placement and subtitle filtering share a duration-coverage rule: a word is removed when more than half its span is covered by the union of enabled cuts; exactly half is kept. Zero-duration ASR tokens use point membership. A pause pill precedes the first affected word, including when its cut starts inside that word. Removed sentence-ending punctuation still separates subtitle sentences, preventing a trimmed sentence from absorbing the next connective. Whisper segment ends and source pauses over 0.8 s also end subtitle sentences, because Whisper sometimes emits no Chinese sentence punctuation at all.

**Burn-in does not require libass, subtitles, ass, or drawtext filters.** CoreText/CoreGraphics renders video-sized transparent PNGs in the selected font (default PingFang SC), color, outline, size and bottom margin. One ffconcat input contains timed cue PNGs plus transparent gap frames and a final sentinel. ffmpeg overlays that stream onto the concatenated video in the same pass. ASS is also generated for external tools.

## Verification

```sh
python3 Scripts/verify_fixture.py \
  "$HOME/code/ai/chuangcut-testdata/test_zh.mp4" \
  --out "$HOME/code/ai/chuangcut-testdata/polish-base" \
  --trim-out "$HOME/code/ai/chuangcut-testdata/polish-trim"
```

This fixture-specific verifier checks the expected pauses/fillers/earlier take, 14–17 s output, audio and video streams, full decoding, monotonic subtitle timings and punctuation/length rules, one surviving repeat, and two burned-subtitle frames.

See `VERIFICATION.md` for the final build, test and native UI results.

## V1 limitations

- Detection is heuristic. Review cuts: intentional repetition can resemble a retake, and ASR can misrecognize words. The fixture's “一聊” is transcribed as “医疗”.
- Word timing is approximate, especially within multi-character tokens or when a model lacks DTW support. Acoustic boundaries improve pause/retake cuts; this is not forced alignment.
- Single source video, first video/audio tracks; no multi-track editing, transitions, free-text correction, diarization, or project interchange format yet.
- Preview uses source seeks, so a join may briefly buffer. Export is decoded and re-encoded at frame boundaries; container duration may differ by one frame from the continuous-time mapping.
- No automatic audio crossfade at hard joins. Display rotation (phone portrait video) is honored for previews and burned subtitles; HDR/color-management and anamorphic (non-square pixel) sources have not been validated.
- Long projects create large filter graphs and subtitle image sequences. Model and temporary media storage are not quota-managed. Downloads do not resume across app restarts.
- The app does not bundle ffmpeg, whisper-cli, or model weights. No App Store sandbox, notarization, signing for distribution, or automatic updates in this development V1.
