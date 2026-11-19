"""Mix the recorded tracks into one .m4a file with ffmpeg."""

import os
import subprocess
from pathlib import Path


def export_m4a(tracks: list[Path], out: Path) -> None:
    """tracks: existing FLAC files recorded in parallel (same timeline)."""
    cmd = ["ffmpeg", "-y", "-loglevel", "error"]
    for track in tracks:
        cmd += ["-i", str(track)]
    if len(tracks) > 1:
        # Bring every input to one rate first (mic.clean.flac is 16 kHz, system.flac 48 kHz), or
        # amix would run the whole mix at the first input's rate. normalize=0 keeps each side at
        # full volume; the limiter stops clipping when both talk.
        inputs = "".join(f"[{i}:a]aresample=48000[a{i}];" for i in range(len(tracks)))
        labels = "".join(f"[a{i}]" for i in range(len(tracks)))
        cmd += ["-filter_complex", f"{inputs}{labels}amix=inputs={len(tracks)}:duration=longest:normalize=0,alimiter=limit=0.95"]
    # Encode to a ".part.m4a" next to the target and rename when done, so a cancelled run never
    # leaves a half-written meeting.m4a that looks finished.
    partial = out.with_suffix(".part.m4a")
    cmd += ["-c:a", "aac", "-b:a", "96k", str(partial)]
    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True)
        os.replace(partial, out)
    finally:
        partial.unlink(missing_ok=True)
