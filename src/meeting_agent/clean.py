"""Echo cancellation for the user's own mic ("Me").

Without headphones the mic also hears the meeting coming out of the speakers. system.flac holds
exactly that audio, so it is the reference: it is subtracted from mic.flac with the Speex echo
canceller, whose built-in preprocessor also removes residual echo and background noise.

mic.flac is never modified. The result is written to mic.clean.flac (16 kHz mono).

Two clocks (the mic and BlackHole) run at slightly different speeds, so the delay between the two
tracks is not constant: up to ~4 s over a 94-minute meeting was measured. The delay is therefore
re-measured every BLOCK samples, and the reference is time-warped to follow it, which leaves the
echo canceller with a constant delay to track.
"""

import os
from pathlib import Path

import numpy as np
import soundfile as sf

RATE = 16000
FRAME = 320                 # 20 ms per echo-canceller step
TAIL = 4096                 # echo tail the filter covers: 256 ms
LEAD = 160                  # keep the echo 10 ms after the aligned reference: the filter is causal
BLOCK = 20 * RATE           # precise delay measurement every 20 s
COARSE_BLOCK = 5 * RATE     # first, rough pass in short blocks: the delay moves less inside one
FIRST_SEARCH = 2 * RATE     # first block: delay anywhere within ±2 s
NEXT_SEARCH = RATE // 10    # later blocks: within ±100 ms of the previous one
MIN_CONFIDENCE = 10.0       # GCC-PHAT peak / median of the search window. Measured: pure noise
                            # scores 5-9, an echo on a drifting clock 7-15 (the delay moving inside
                            # the block smears the peak), a steady echo in the hundreds. A stray
                            # false lock is thrown out later by the line fit.
MIN_COVERAGE = 0.25         # share of blocks (that carry meeting audio) that must show an echo,
                            # or there is no echo to remove and the mic is left alone
MIN_LOCKS = 2
PREROLL = 10 * RATE         # opening seconds the echo canceller learns from before the real pass
REFINE_PASSES = 2           # re-measure on the warped reference (see _refine)
REFINE_SEARCH = RATE // 50  # ±20 ms is enough once the coarse delays are applied
LINE_MAX_RMS = 160          # samples (10 ms): scatter beyond this means the delay is not a line
MIN_RMS = 1e-4              # reference quieter than this (about -80 dBFS) carries no meeting audio


def _rms(x: np.ndarray) -> float:
    return float(np.sqrt(np.mean(x.astype("float64") ** 2))) if len(x) else 0.0


def gcc_phat(mic: np.ndarray, ref: np.ndarray, lo: int, hi: int) -> tuple[int, float]:
    """Delay d in [lo, hi] samples such that mic[n] ≈ ref[n - d], plus a confidence ratio
    (correlation peak over the median of the window)."""
    n = len(mic) + len(ref)
    spec = np.fft.rfft(mic, n) * np.conj(np.fft.rfft(ref, n))
    spec /= np.abs(spec) + 1e-12
    cc = np.abs(np.fft.irfft(spec, n))
    lags = np.arange(lo, hi + 1)
    window = cc[lags % n]  # negative lags wrap around
    best = int(np.argmax(window))
    return int(lags[best]), float(window[best] / (np.median(window) + 1e-12))


def _blocks(length: int, size: int):
    for start in range(0, length, size):
        end = min(start + size, length)
        if end - start >= max(size // 4, 3 * RATE):  # a shorter tail just keeps the last delay
            yield start, end


def _coarse(mic: np.ndarray, ref: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """First measurement: one delay per short block. While the clocks drift the delay still moves
    inside a block and smears the correlation peak, so this is only accurate to a few ms."""
    centres: list[float] = []
    delays: list[int] = []
    previous: int | None = None
    with_audio = 0
    for start, end in _blocks(len(mic), COARSE_BLOCK):
        if _rms(ref[start:end]) < MIN_RMS:
            continue
        with_audio += 1
        lo, hi = (-FIRST_SEARCH, FIRST_SEARCH) if previous is None else (previous - NEXT_SEARCH, previous + NEXT_SEARCH)
        delay, confidence = gcc_phat(mic[start:end], ref[start:end], lo, hi)
        if confidence < MIN_CONFIDENCE:
            continue
        centres.append((start + end) / 2)
        delays.append(delay)
        previous = delay
    if len(delays) < MIN_LOCKS or len(delays) < MIN_COVERAGE * with_audio:
        return np.array([]), np.array([])  # the mic barely correlates with the meeting: no echo
    return np.array(centres), np.array(delays, dtype="float64")


def _refine(mic: np.ndarray, ref: np.ndarray, centres: np.ndarray, delays: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Measure again against the reference warped by the current delays. Only the small leftover
    delay remains inside each block, so the peak is sharp and the result exact to a sample."""
    new_centres: list[float] = []
    new_delays: list[float] = []
    for start, end in _blocks(len(mic), BLOCK):
        n = np.arange(start, end, dtype="float64")
        warped = _sample(ref, n - np.interp(n, centres, delays))
        if _rms(warped) < MIN_RMS:
            continue
        leftover, confidence = gcc_phat(mic[start:end], warped, -REFINE_SEARCH, REFINE_SEARCH)
        if confidence < MIN_CONFIDENCE:
            continue
        centre = (start + end) / 2
        new_centres.append(centre)
        new_delays.append(float(np.interp(centre, centres, delays)) + leftover)
    return np.array(new_centres), np.array(new_delays)


def _fit_line(centres: np.ndarray, delays: np.ndarray, length: int) -> tuple[np.ndarray, np.ndarray] | None:
    """Two clocks differ by a constant ratio, so the delay is a straight line in time. Fitting one
    averages out the error of every single block, which a piecewise curve would follow and which
    the echo canceller can't track (it adapts to a steady path, not to kinks). Outliers are
    dropped. None when the delays don't look like a line (a step, say): the caller then keeps
    the measured curve."""
    if len(delays) < 4:
        return None
    keep = np.ones(len(delays), dtype=bool)
    for _ in range(3):
        slope, intercept = np.polyfit(centres[keep], delays[keep], 1)
        residual = delays - (slope * centres + intercept)
        mad = np.median(np.abs(residual[keep] - np.median(residual[keep])))
        keep = np.abs(residual) <= max(3 * 1.4826 * mad, 8.0)  # never tighter than 0.5 ms
        if keep.sum() < 4:
            return None
    slope, intercept = np.polyfit(centres[keep], delays[keep], 1)
    rms = float(np.sqrt(np.mean((delays[keep] - (slope * centres[keep] + intercept)) ** 2)))
    if keep.mean() < 0.6 or rms > LINE_MAX_RMS:
        return None
    return np.array([0.0, float(length)]), np.array([intercept, slope * length + intercept])


def estimate_delays(mic: np.ndarray, ref: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """(time in samples, delay in samples): a line when the delays fit one (the usual case, a
    constant clock ratio), otherwise the measured value of every block."""
    centres, delays = _coarse(mic, ref)
    for step in range(REFINE_PASSES + 1):
        if len(delays) == 0:
            break
        line = _fit_line(centres, delays, len(mic))
        if line is not None:
            centres, delays = line
        if step < REFINE_PASSES:
            refined_centres, refined_delays = _refine(mic, ref, centres, delays)
            if len(refined_delays):
                centres, delays = refined_centres, refined_delays
    return centres, delays


def _sample(ref: np.ndarray, position: np.ndarray) -> np.ndarray:
    """ref at fractional sample positions (linear interpolation, zeros outside)."""
    index = np.floor(position).astype("int64")
    frac = (position - index).astype("float32")
    inside = (index >= 0) & (index < len(ref) - 1)
    safe = np.where(inside, index, 0)
    return np.where(inside, ref[safe] * (1 - frac) + ref[safe + 1] * frac, 0).astype("float32")


def _to_int16(x: np.ndarray) -> np.ndarray:
    return np.clip(x * 32768, -32768, 32767).astype(np.int16)


def clean_arrays(mic: np.ndarray, ref: np.ndarray) -> tuple[np.ndarray, dict] | None:
    """Echo-cancel `mic` against `ref` (both 16 kHz mono float). None when there is nothing to do
    or it can't be done: the reference holds no meeting audio, or the mic doesn't correlate with
    it (headphones: no echo), so no delay could be measured."""
    from pyaec import Aec

    ref = np.pad(ref, (0, max(0, len(mic) - len(ref))))[: len(mic)]
    if _rms(ref) < MIN_RMS:
        return None
    centres, delays = estimate_delays(mic, ref)
    if len(delays) == 0:
        return None

    aec = Aec(FRAME, TAIL, RATE, True)  # True: residual-echo suppression + noise suppression

    def run(start: int, end: int) -> np.ndarray:
        n = np.arange(start, end, dtype="float64")
        aligned = _sample(ref, n + LEAD - np.interp(n, centres, delays))  # constant outside the measured range
        mic_i, ref_i = _to_int16(mic[start:end]), _to_int16(aligned)
        cleaned = np.empty(len(mic_i), dtype=np.int16)
        for i in range(0, len(mic_i), FRAME):
            m, r = mic_i[i: i + FRAME], ref_i[i: i + FRAME]
            if len(m) < FRAME:  # last, partial frame: pad, then cut back
                pad = FRAME - len(m)
                cleaned[i:] = np.array(aec.cancel_echo(np.pad(m, (0, pad)), np.pad(r, (0, pad))), dtype=np.int16)[: len(m)]
            else:
                cleaned[i: i + FRAME] = aec.cancel_echo(m, r)
        return cleaned.astype("float32") / 32768

    # The filter starts knowing nothing and needs a few seconds to learn the echo path, so the first
    # seconds of the meeting would stay partly un-cleaned. We have the whole recording: let it learn
    # on the opening seconds first (output thrown away), then start again from the beginning.
    run(0, min(PREROLL, len(mic)) // FRAME * FRAME)
    out = np.empty(len(mic), dtype="float32")
    for start in range(0, len(mic), BLOCK):
        end = min(start + BLOCK, len(mic))
        out[start:end] = run(start, end)
    info = {"blocks": len(delays), "delay_min": float(delays.min()) / RATE, "delay_max": float(delays.max()) / RATE}
    return out, info


def clean_mic(mic_path: Path, ref_path: Path, out_path: Path) -> dict | None:
    """mic.flac + system.flac → mic.clean.flac. Returns measurements, or None if skipped."""
    import whisper  # load_audio: any input rate/channels → 16 kHz mono float32 (ffmpeg)

    result = clean_arrays(whisper.load_audio(str(mic_path)), whisper.load_audio(str(ref_path)))
    if result is None:
        return None
    audio, info = result
    partial = out_path.with_name(out_path.name + ".part")  # a killed run leaves no half-written result
    try:
        sf.write(partial, audio, RATE, format="FLAC", subtype="PCM_16")
        os.replace(partial, out_path)
    finally:
        partial.unlink(missing_ok=True)
    return info
