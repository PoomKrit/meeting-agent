"""Speech-to-text with openai-whisper; merge tracks into one timeline."""

import importlib
import re
import types
from difflib import SequenceMatcher
from pathlib import Path

import numpy as np

WHISPER_RATE = 16000  # whisper.load_audio resamples to this
SILENCE_RMS = 1e-4  # about -80 dBFS: digital silence, far below any real room noise


def is_silent(audio: np.ndarray, start: float, end: float) -> bool:
    chunk = audio[int(start * WHISPER_RATE) : int(end * WHISPER_RATE)]
    return chunk.size == 0 or float(np.sqrt(np.mean(chunk**2))) < SILENCE_RMS


# --- Voice activity detection for the user's own mic ("Me") -----------------------------------
# The mic records the whole meeting, so most of it is the user listening: room noise, typing,
# and (without headphones) the other speakers coming out of the laptop speakers. Whisper is only
# run on the stretches Silero VAD marks as speech; mic.flac itself is kept complete.

VAD_PAD = 0.3   # seconds added on each side of a speech region so first/last words aren't clipped
VAD_GAP = 1.0   # regions closer than this are merged (a pause inside a sentence isn't a new clip)


def merge_regions(regions: list[tuple[float, float]], duration: float,
                  pad: float = VAD_PAD, gap: float = VAD_GAP) -> list[tuple[float, float]]:
    """Pad each (start, end) region, clamp to [0, duration], and merge ones that touch or are
    less than `gap` apart."""
    merged: list[tuple[float, float]] = []
    for start, end in sorted(regions):
        start, end = max(0.0, start - pad), min(duration, end + pad)
        if merged and start - merged[-1][1] < gap:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def speech_regions(audio: np.ndarray) -> list[tuple[float, float]]:
    from silero_vad import get_speech_timestamps, load_silero_vad  # model ships inside the package

    found = get_speech_timestamps(audio, load_silero_vad(), sampling_rate=WHISPER_RATE, return_seconds=True)
    return merge_regions([(r["start"], r["end"]) for r in found], len(audio) / WHISPER_RATE)


# --- Speaker bleed: without headphones the mic also hears the meeting ------------------------
# Those words then show up twice: once as "Others" (BlackHole) and once as "Me" (mic). A "Me" line
# that overlaps an "Others" line in time and says nearly the same thing is dropped.

BLEED_WINDOW = 2.0      # seconds of slack around an Others segment (speaker → mic latency, Whisper drift)
BLEED_SIMILARITY = 0.6


def _normalize(text: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s]", "", text.lower())).strip()


def is_bleed(me: dict, others: list[dict]) -> bool:
    mine = _normalize(me["text"])
    if not mine:
        return True
    for o in others:
        if o["end"] + BLEED_WINDOW < me["start"] or o["start"] - BLEED_WINDOW > me["end"]:
            continue
        theirs = _normalize(o["text"])
        if SequenceMatcher(None, mine, theirs).ratio() >= BLEED_SIMILARITY:
            return True
        # A bleed line is often only part of what Others said (Whisper splits the tracks differently).
        if len(mine) >= 8 and mine in theirs:
            return True
    return False


def format_time(seconds: float) -> str:
    seconds = int(seconds)
    return f"{seconds // 3600:02d}:{seconds % 3600 // 60:02d}:{seconds % 60:02d}"


def merge_segments(segments: list[tuple[float, str, str]]) -> str:
    """segments: (start_seconds, speaker, text). Returns plain text, ordered by time."""
    lines = [
        f"[{format_time(start)}] {speaker}: {text}"
        for start, speaker, text in sorted(segments)
        if text
    ]
    return "\n".join(lines) + "\n"


class Progress:
    """Overall % across all tracks, printed as '[progress] N' lines (the Mac app parses these)."""

    def __init__(self, tracks: int, emit=lambda line: print(line, flush=True), step: int = 2):
        self.tracks, self.emit, self.step = tracks, emit, step
        self.index = 0
        self.last = -step

    def update(self, fraction: float) -> None:
        pct = int((self.index + min(max(fraction, 0.0), 1.0)) / self.tracks * 100)
        if pct >= self.last + self.step or (pct == 100 and self.last != 100):
            self.last = pct
            self.emit(f"[progress] {pct}")


def _bar_for(progress: Progress):
    """Stand-in for tqdm.tqdm inside whisper.transcribe: whisper calls update() per ~30s window."""

    class Bar:
        def __init__(self, total=None, **_):
            self.total, self.n = max(total or 1, 1), 0

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

        def update(self, n=1):
            self.n += n
            progress.update(self.n / self.total)

    return Bar


def transcribe(tracks: dict[str, Path], model_name: str, language: str | None) -> str:
    import whisper

    # `whisper.transcribe` the attribute is the function; the module has to come from importlib.
    whisper_module = importlib.import_module("whisper.transcribe")
    progress = Progress(len(tracks))
    original_tqdm = whisper_module.tqdm
    whisper_module.tqdm = types.SimpleNamespace(tqdm=_bar_for(progress))
    try:
        return _transcribe(whisper, tracks, model_name, language, progress)
    finally:
        whisper_module.tqdm = original_tqdm


def _transcribe(whisper, tracks, model_name, language, progress) -> str:
    # Models cache in ~/.cache/whisper (downloads from openaipublic.azureedge.net;
    # huggingface.co is blocked by the corporate proxy, so faster-whisper can't fetch models).
    model = whisper.load_model(model_name)
    by_speaker: dict[str, list[dict]] = {}
    for index, (speaker, path) in enumerate(tracks.items()):
        print(f"Transcribing {speaker} ({path.name}) ...", flush=True)
        progress.index = index
        progress.update(0)
        audio = whisper.load_audio(str(path))
        options = {}
        if speaker in ("Me", "Mic"):  # the user's own mic, or the only mic in mic-only mode
            regions = speech_regions(audio)
            spoken = sum(end - start for start, end in regions)
            print(f"  VAD: {len(regions)} ช่วงที่พูด รวม {spoken:.0f} วินาที จาก {len(audio) / WHISPER_RATE:.0f} วินาที", flush=True)
            if not regions:
                by_speaker[speaker] = []
                progress.update(1)
                continue
            # Whisper decodes only these clips; timestamps stay on the full meeting timeline.
            options["clip_timestamps"] = [t for region in regions for t in region]
        # condition_on_previous_text=False: stops repeated-phrase loops on long, quiet tracks.
        result = model.transcribe(
            audio, language=language, fp16=False, condition_on_previous_text=False,
            verbose=False,  # False (not None) is what turns whisper's progress bar on
            **options,
        )
        progress.update(1)
        # Drop failed decodes (Whisper's own logprob_threshold). On near-silent tracks the
        # turbo model emits multilingual gibberish around -4.6 while real speech sits above -1.
        # Also drop segments over digital silence (muted mic, idle BlackHole): Whisper invents
        # text like "Thank you." there, with a good enough logprob to slip past the filter above.
        by_speaker[speaker] = [
            {"start": s["start"], "end": s["end"], "text": s["text"].strip()}
            for s in result["segments"]
            if s["avg_logprob"] >= -1.0 and not is_silent(audio, s["start"], s["end"])
        ]

    others = by_speaker.get("Others", [])
    if "Me" in by_speaker:
        kept = [seg for seg in by_speaker["Me"] if not is_bleed(seg, others)]
        if dropped := len(by_speaker["Me"]) - len(kept):
            print(f"  ตัด {dropped} บรรทัดของ Me ที่เป็นเสียงประชุมรั่วเข้าไมค์", flush=True)
        by_speaker["Me"] = kept
    return merge_segments([(seg["start"], spk, seg["text"]) for spk, segs in by_speaker.items() for seg in segs])
