#!/usr/bin/env python3
"""End-to-end regression for the supplied 25-second Mandarin fixture."""
import argparse
import json
import pathlib
import re
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("input", type=pathlib.Path)
parser.add_argument("--out", type=pathlib.Path, required=True)
parser.add_argument("--model", type=pathlib.Path)
parser.add_argument("--trim-out", type=pathlib.Path, help="Also verify two edge trims in a separate output directory")
args = parser.parse_args()
ffmpeg = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
ffprobe = str(pathlib.Path(ffmpeg).with_name("ffprobe"))
cli = root / "Packages/ChuangCutCore/.build/debug/chuangcut-cli"
command = [str(cli), str(args.input.expanduser()), "--out", str(args.out.expanduser()), "--burn"]
if args.model:
    command += ["--model", str(args.model.expanduser())]
result = subprocess.run(command, check=True, text=True, capture_output=True)
print(result.stdout)
out = args.out.expanduser()
(out / "verification-summary.txt").write_text(result.stdout)
cuts = json.loads((out / "cuts.json").read_text())
pauses = [cut for cut in cuts if cut["kind"] == "pause"]
for center in (3.5, 12.9, 21.8):
    assert any(cut["sourceStart"] < center < cut["sourceEnd"] for cut in pauses), center
fillers = "".join(cut["text"] for cut in cuts if cut["kind"] == "filler")
assert "嗯" in fillers and "那个" in fillers
retakes = [cut for cut in cuts if cut["kind"] == "retake"]
assert len(retakes) == 1 and 4.2 < retakes[0]["sourceStart"] < 4.7 and 7 < retakes[0]["sourceEnd"] < 7.6

def probe(path):
    return json.loads(subprocess.check_output([ffprobe, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)]))

for name in ("cut.mp4", "cut_burned.mp4"):
    path = out / name
    data = probe(path)
    duration = float(data["format"]["duration"])
    assert 14 < duration < 17, duration
    assert {"video", "audio"} <= {s["codec_type"] for s in data["streams"]}
    subprocess.run([ffmpeg, "-v", "error", "-i", str(path), "-f", "null", "-"], check=True)
    print(f"{name}: {duration:.3f}s, video + audio, full decode passed")

srt = (out / "cut.srt").read_text()
assert srt.count("今天我们来聊") == 1
assert "嗯" not in srt and "那个" not in srt
previous_end = 0

def timestamp(value):
    h, m, s, ms = map(int, re.split(r"[:,]", value))
    return h * 3600 + m * 60 + s + ms / 1000

blocks = srt.strip().split("\n\n")
for block in blocks:
    _, times, *lines = block.splitlines()
    start, end = map(timestamp, times.split(" --> "))
    assert previous_end <= start < end <= duration
    assert end - start <= 5.6
    previous_end = end
    for line in lines:
        assert len(line) <= 16
        assert line[-1] not in "。，！？、,.!?，"
        assert line[0] not in "，,"
for i, second in enumerate((1.8, 8.5), 1):
    frame = out / f"burned-{i}.png"
    subprocess.run([ffmpeg, "-y", "-v", "error", "-ss", str(second), "-i", str(out / "cut_burned.mp4"), "-frames:v", "1", str(frame)], check=True)
    assert frame.stat().st_size > 1000
print(f"PASS: {len(cuts)} candidates, {len(blocks)} monotonic subtitle cues, two burned frames extracted")

if args.trim_out:
    trimmed_out = args.trim_out.expanduser()
    trimmed_command = command.copy()
    trimmed_command[trimmed_command.index("--out") + 1] = str(trimmed_out)
    trimmed_command += ["--trim", "1:right:12.9", "--trim", "2:left:14.5"]
    trimmed = subprocess.run(trimmed_command, check=True, text=True, capture_output=True)
    print(trimmed.stdout)
    (trimmed_out / "verification-summary.txt").write_text(trimmed.stdout)

    def kept_ranges(project):
        ranges = sorted((max(0, c["sourceStart"]), min(project["media"]["duration"], c["sourceEnd"]))
                        for c in project["candidates"] if c["enabled"])
        kept, cursor = [], 0.0
        for start, end in ranges:
            if start > cursor:
                kept.append((cursor, start))
            cursor = max(cursor, end)
        if cursor < project["media"]["duration"]:
            kept.append((cursor, project["media"]["duration"]))
        return kept

    baseline_project = json.loads((out / "project.json").read_text())
    trimmed_project = json.loads((trimmed_out / "project.json").read_text())
    before, after = kept_ranges(baseline_project), kept_ranges(trimmed_project)
    assert len(before) == len(after) == 4
    assert abs(after[1][1] - 12.9) < 1e-6 and abs(after[2][0] - 14.5) < 1e-6
    expected_delta = (12.9 - before[1][1]) - (14.5 - before[2][0])
    before_duration = sum(end - start for start, end in before)
    after_duration = sum(end - start for start, end in after)
    assert abs(after_duration - before_duration - expected_delta) < 1e-6
    assert any(c.get("isAdjusted") for c in trimmed_project["candidates"])
    for name in ("cut.mp4", "cut_burned.mp4"):
        actual = probe(trimmed_out / name)
        actual_duration = float(actual["format"]["duration"])
        assert abs(actual_duration - after_duration) <= 1 / 30 + 0.01
        assert {"video", "audio"} <= {s["codec_type"] for s in actual["streams"]}
        subprocess.run([ffmpeg, "-v", "error", "-i", str(trimmed_out / name), "-f", "null", "-"], check=True)
    trimmed_srt = (trimmed_out / "cut.srt").read_text()
    assert "首先" in srt and "首先" not in trimmed_srt
    assert "嗯" not in trimmed_srt and "那个" not in trimmed_srt
    previous_end = 0
    for block in trimmed_srt.strip().split("\n\n"):
        _, times, *lines = block.splitlines()
        start, end = map(timestamp, times.split(" --> "))
        assert previous_end <= start < end <= after_duration + .001
        previous_end = end
        assert all(line[-1] not in "。，！？、,.!?，" for line in lines)
    print(f"PASS: trim mapping {before_duration:.6f}s → {after_duration:.6f}s; delta {expected_delta:+.6f}s; newly removed words absent from SRT")
