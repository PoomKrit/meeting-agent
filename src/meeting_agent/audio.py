"""Record one input device to a mono FLAC file."""

import math
import queue
import threading
from pathlib import Path

import numpy as np
import sounddevice as sd
import soundfile as sf


def find_input_device(name_part: str) -> int | None:
    """Index of the input device called `name_part` (exact name wins), else the first whose name
    contains it. Exact first: the Mac app passes full names, and "USB Audio" must not pick
    "USB Audio Pro" just because that one is listed earlier."""
    wanted = name_part.lower()
    inputs = [(i, d["name"].lower()) for i, d in enumerate(sd.query_devices()) if d["max_input_channels"] > 0]
    for index, name in inputs:
        if name == wanted:
            return index
    for index, name in inputs:
        if wanted in name:
            return index
    return None


def input_devices() -> list[dict]:
    """Every input device: name, channels, and which one macOS currently uses as its default."""
    try:
        default_name = sd.query_devices(kind="input")["name"]
    except Exception:  # no input device at all
        default_name = None
    return [
        {"name": d["name"], "channels": d["max_input_channels"], "default": d["name"] == default_name}
        for d in sd.query_devices()
        if d["max_input_channels"] > 0
    ]


def list_input_devices() -> list[str]:
    return [
        f"[{i}] {d['name']} ({d['max_input_channels']} ch)"
        for i, d in enumerate(sd.query_devices())
        if d["max_input_channels"] > 0
    ]


def level_percent(peak: float, floor_db: float = -60.0) -> int:
    """Linear peak (0..1) → 0..100 on a dBFS scale, so quiet speech still moves the meter."""
    if peak <= 0:
        return 0
    db = 20 * math.log10(min(peak, 1.0))
    return max(0, min(100, round((db - floor_db) / -floor_db * 100)))


class Track:
    """Capture a device in a background stream; downmix to mono and write FLAC."""

    def __init__(self, path: Path, device: int | None):
        info = sd.query_devices(device, "input")
        self.name = info["name"]
        samplerate = int(info["default_samplerate"])
        channels = min(2, info["max_input_channels"])
        self._queue: queue.Queue = queue.Queue()
        self._file = sf.SoundFile(path, "w", samplerate=samplerate, channels=1, format="FLAC")
        self._stream = sd.InputStream(
            device=device, channels=channels, samplerate=samplerate, callback=self._callback
        )
        self._writer = threading.Thread(target=self._write, daemon=True)
        self.paused = False
        self.muted = False
        self._peak = 0.0

    def _callback(self, indata, frames, time, status):
        # Paused: drop frames. Every track skips the same stretch, so they stay aligned.
        if self.paused:
            return
        # Muted: write silence instead of dropping, or this track would end up shorter than
        # the others and every timestamp after the mute would drift.
        block = np.zeros(frames, dtype="float32") if self.muted else indata.mean(axis=1)
        self._peak = max(self._peak, float(np.abs(block).max(initial=0.0)))
        self._queue.put(block)

    def take_peak(self) -> float:
        """Loudest sample written since the last call (0 while paused or muted). Resets it."""
        peak, self._peak = self._peak, 0.0
        return peak

    def _write(self):
        while (block := self._queue.get()) is not None:
            self._file.write(block)
        self._file.close()

    def start(self):
        self._writer.start()
        self._stream.start()

    def stop(self):
        self._stream.stop()
        self._stream.close()
        self._queue.put(None)
        self._writer.join()
