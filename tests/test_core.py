import subprocess
import time
from pathlib import Path

import numpy as np
import soundfile as sf

from meeting_agent import clean
from meeting_agent import audio
from meeting_agent.audio import level_percent
from meeting_agent.cli import RecordingClock, build_parser, mic_label, session_dir, take_notes, title_of, write_atomic
from meeting_agent.export import export_m4a
from meeting_agent.summarize import build_user_message
from meeting_agent.transcribe import Progress, _bar_for, format_time, is_bleed, is_silent, merge_regions, merge_segments


def test_format_time():
    assert format_time(0) == "00:00:00"
    assert format_time(3725.9) == "01:02:05"


def test_merge_segments_orders_by_time_and_drops_empty():
    out = merge_segments([(5.0, "Others", "ok"), (1.0, "Me", "PROJ-123 เสร็จแล้ว"), (3.0, "Me", "")])
    assert out == "[00:00:01] Me: PROJ-123 เสร็จแล้ว\n[00:00:05] Others: ok\n"


def test_title_of_keeps_thai():
    assert title_of(Path("2026-11-12_1015_Sprint-ประชุมทีม")) == "Sprint ประชุมทีม"


def test_build_user_message_contains_only_title_and_transcript():
    msg = build_user_message("Daily", "[00:00:01] Me: PROJ-1 deploy แล้ว")
    assert msg == "Meeting title: Daily\n\n<transcript>\n[00:00:01] Me: PROJ-1 deploy แล้ว\n</transcript>"


def test_clock_excludes_paused_time():
    clock = RecordingClock()
    time.sleep(0.2)
    clock.pause()
    frozen = clock.elapsed()
    time.sleep(0.3)
    assert clock.paused
    assert clock.elapsed() == frozen  # frozen while paused
    clock.resume()
    time.sleep(0.1)
    # ~0.3s recorded; the 0.3s pause is excluded (wall time would be ~0.6s)
    assert 0.25 < clock.elapsed() < 0.45


def test_clock_pause_resume_are_idempotent():
    clock = RecordingClock()
    clock.resume()  # not paused: no-op
    clock.pause()
    clock.pause()  # second pause must not reset the pause start
    time.sleep(0.1)
    clock.resume()
    assert clock.elapsed() < 0.05


def _duration(path: Path) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
        capture_output=True, text=True, check=True,
    )
    return float(out.stdout)


def test_export_m4a_mixes_two_tracks(tmp_path):
    sr = 48000
    t = np.arange(sr * 2) / sr
    sf.write(tmp_path / "a.flac", (0.3 * np.sin(2 * np.pi * 440 * t)).astype("float32"), sr)
    sf.write(tmp_path / "b.flac", (0.3 * np.sin(2 * np.pi * 880 * t)).astype("float32"), sr)
    out = tmp_path / "meeting.m4a"
    export_m4a([tmp_path / "a.flac", tmp_path / "b.flac"], out)
    assert out.stat().st_size > 0
    assert 1.8 < _duration(out) < 2.3


def test_export_m4a_single_track(tmp_path):
    sr = 16000
    sf.write(tmp_path / "a.flac", np.zeros(sr, dtype="float32"), sr)
    out = tmp_path / "meeting.m4a"
    export_m4a([tmp_path / "a.flac"], out)
    assert 0.8 < _duration(out) < 1.3


def test_is_silent_only_for_digital_silence():
    rate = 16000
    audio = np.concatenate([
        np.zeros(rate * 2, dtype="float32"),                                   # 0-2s muted
        (0.01 * np.sin(2 * np.pi * 300 * np.arange(rate * 2) / rate)).astype("float32"),  # 2-4s quiet speech
    ])
    assert is_silent(audio, 0.0, 2.0)
    assert not is_silent(audio, 2.0, 4.0)
    assert is_silent(audio, 10.0, 11.0)  # past the end: empty slice


def test_progress_is_overall_across_tracks_and_throttled():
    lines = []
    progress = Progress(2, emit=lines.append, step=10)
    progress.update(0)      # track 0 start
    progress.update(0.04)   # 2% -> below the step, not printed
    progress.update(0.5)    # 25%
    progress.update(1.0)    # 50%
    progress.index = 1
    progress.update(0)      # 50% again -> not printed
    progress.update(1.0)    # 100%
    assert lines == ["[progress] 0", "[progress] 25", "[progress] 50", "[progress] 100"]


def test_whisper_bar_shim_converts_frames_to_fraction():
    seen = []
    progress = Progress(1, emit=seen.append, step=1)
    with _bar_for(progress)(total=200, unit="frames", disable=False) as bar:
        bar.update(50)
        bar.update(150)
    assert seen == ["[progress] 25", "[progress] 100"]


def test_language_defaults_to_english_and_auto_means_detect():
    parse = build_parser().parse_args
    assert parse(["record", "x"]).language == "en"
    assert parse(["record", "x", "--language", "th"]).language == "th"
    assert parse(["record", "x", "--language", "auto"]).language is None
    assert parse(["process", "somedir"]).language == "en"


def test_level_percent_is_a_db_scale():
    assert level_percent(0.0) == 0
    assert level_percent(1.0) == 100
    assert level_percent(0.5) == 90      # -6 dBFS
    assert level_percent(0.02) == 43     # quiet speech, about -34 dBFS, still clearly visible
    assert level_percent(0.0005) == 0    # below the -60 dBFS floor
    assert level_percent(3.0) == 100     # clipped input can't overflow the meter


def _feed(monkeypatch, *lines):
    it = iter(lines)
    monkeypatch.setattr("builtins.input", lambda _prompt="": next(it))


def test_take_notes_reports_which_command_ended_it(monkeypatch, tmp_path):
    _feed(monkeypatch, "hello", "/cancel")
    assert take_notes(tmp_path / "n.md", {"/pause": lambda: None}) == "/cancel"
    assert (tmp_path / "n.md").read_text() == "hello\n"

    _feed(monkeypatch, "/end")
    assert take_notes(tmp_path / "n2.md", {"/pause": lambda: None}) == "/end"


def test_cancel_is_only_a_command_in_record_mode(monkeypatch, tmp_path):
    _feed(monkeypatch, "/cancel", "/end")  # note-only mode has no commands: "/cancel" is just text
    assert take_notes(tmp_path / "n.md") == "/end"
    assert (tmp_path / "n.md").read_text() == "/cancel\n"


def test_write_atomic_leaves_no_partial_file(tmp_path):
    write_atomic(tmp_path / "t.txt", "สวัสดี")
    assert (tmp_path / "t.txt").read_text() == "สวัสดี"
    assert not (tmp_path / "t.txt.part").exists()


def test_export_failure_leaves_no_partial_m4a(tmp_path):
    import pytest
    bad = tmp_path / "broken.flac"
    bad.write_bytes(b"not audio")
    with pytest.raises(subprocess.CalledProcessError):
        export_m4a([bad], tmp_path / "meeting.m4a")
    assert not (tmp_path / "meeting.m4a").exists()
    assert not (tmp_path / "meeting.part.m4a").exists()


def test_merge_regions_pads_clamps_and_joins_close_regions():
    regions = [(0.1, 2.0), (2.5, 4.0), (10.0, 12.0), (29.9, 30.5)]
    got = merge_regions(regions, duration=30.0, pad=0.3, gap=1.0)
    assert np.allclose(got, [(0.0, 4.3), (9.7, 12.3), (29.6, 30.0)])
    assert merge_regions([], duration=10.0) == []


def test_bleed_is_a_near_duplicate_of_an_overlapping_others_line():
    others = [{"start": 10.0, "end": 14.0, "text": "Ticket PROJ-456 is still blocked, waiting for the API spec."}]
    echo = {"start": 10.4, "end": 14.3, "text": "ticket PROJ 456 is still blocked waiting for the API spec"}
    part = {"start": 12.0, "end": 13.5, "text": "waiting for the API spec"}
    mine = {"start": 11.0, "end": 13.0, "text": "ผมจะตาม spec กับ Anna ให้ครับ"}
    later = {"start": 40.0, "end": 43.0, "text": "Ticket PROJ-456 is still blocked, waiting for the API spec."}
    assert is_bleed(echo, others)
    assert is_bleed(part, others)
    assert not is_bleed(mine, others)      # the user talking over someone: kept
    assert not is_bleed(later, others)     # same words much later = the user repeating it: kept
    assert not is_bleed({"start": 0, "end": 1, "text": "OK"}, [{"start": 0, "end": 1, "text": "OK so next ticket"}])


# ---- echo cancellation -------------------------------------------------------------------------

def _speechlike(seconds: float, seed: int) -> np.ndarray:
    """Band-limited noise with a ~4 Hz syllable-like envelope, 16 kHz, peak about 0.5."""
    rng = np.random.default_rng(seed)
    n = int(seconds * clean.RATE)
    spectrum = np.fft.rfft(rng.standard_normal(n))
    freqs = np.fft.rfftfreq(n, 1 / clean.RATE)
    spectrum[(freqs < 200) | (freqs > 3500)] = 0
    x = np.fft.irfft(spectrum, n)
    envelope = np.abs(np.convolve(rng.standard_normal(n), np.ones(2000) / 2000, mode="same"))
    x = x * (envelope / envelope.max()) ** 0.7
    return (0.5 * x / np.abs(x).max()).astype("float32")


def _echo_of(ref: np.ndarray, delay_s: float, gain: float = 0.35, drift: float = 0.0) -> np.ndarray:
    """What the mic hears of `ref`: delayed, quieter, one early reflection; optionally on a clock
    that runs `drift` (fraction) faster than the reference's."""
    pos = np.arange(len(ref)) * (1 + drift) - delay_s * clean.RATE
    out = clean._sample(ref, pos)
    return gain * (out + 0.3 * np.roll(out, int(0.008 * clean.RATE)))


def _db(x: np.ndarray) -> float:
    return 20 * np.log10(clean._rms(x) + 1e-12)


def test_gcc_phat_finds_the_delay():
    ref = _speechlike(10, seed=1)
    mic = _echo_of(ref, 0.137) + 0.002 * np.random.default_rng(2).standard_normal(len(ref)).astype("float32")
    delay, confidence = clean.gcc_phat(mic, ref, -2 * clean.RATE, 2 * clean.RATE)
    assert abs(delay - round(0.137 * clean.RATE)) <= 2
    assert confidence > clean.MIN_CONFIDENCE
    _, noise_confidence = clean.gcc_phat(0.01 * np.random.default_rng(3).standard_normal(len(ref)).astype("float32"), ref, -2 * clean.RATE, 2 * clean.RATE)
    assert noise_confidence < clean.MIN_CONFIDENCE


def test_clean_removes_the_meeting_echo_and_keeps_the_users_voice():
    ref = _speechlike(40, seed=4)
    me = np.zeros_like(ref)
    me[22 * clean.RATE: 30 * clean.RATE] = _speechlike(8, seed=5)       # the user speaks 22-30 s
    mic = _echo_of(ref, 0.12) + me + 0.002 * np.random.default_rng(6).standard_normal(len(ref)).astype("float32")
    cleaned, info = clean.clean_arrays(mic, ref)
    echo_only = slice(8 * clean.RATE, 20 * clean.RATE)                  # after the filter converged
    voice = slice(22 * clean.RATE, 30 * clean.RATE)
    echo_removed = _db(mic[echo_only]) - _db(cleaned[echo_only])
    voice_kept = _db(cleaned[voice]) - _db(me[voice] + _echo_of(ref, 0.12)[voice])
    assert echo_removed > 15, f"echo only {echo_removed:.1f} dB quieter"
    assert voice_kept > -8, f"voice changed by {voice_kept:.1f} dB"
    assert info["blocks"] >= 1 and abs(info["delay_min"] - 0.12) < 0.01


def test_clean_follows_a_drifting_clock():
    # The mic's clock runs 0.1 % fast: the delay shrinks by 0.36 s over 6 minutes (a 94-minute
    # meeting was measured at 3.8 s, about 0.07 %). A single delay for the whole file can't follow that.
    ref = _speechlike(360, seed=7)
    mic = _echo_of(ref, 0.1, drift=0.001) + 0.002 * np.random.default_rng(8).standard_normal(len(ref)).astype("float32")
    late = slice(300 * clean.RATE, 350 * clean.RATE)
    tracked, info = clean.clean_arrays(mic, ref)
    assert _db(mic[late]) - _db(tracked[late]) > 12
    assert 0.25 < info["delay_max"] - info["delay_min"] < 0.45   # it measured the drift (about 0.34 s)

    saved = clean.BLOCK
    clean.BLOCK = len(mic)                                   # control: one delay for the whole file
    try:
        fixed, _ = clean.clean_arrays(mic, ref)
    finally:
        clean.BLOCK = saved
    assert _db(tracked[late]) < _db(fixed[late]) - 5, "per-block tracking should clearly beat one fixed delay"


def test_clean_skips_when_the_reference_has_no_meeting_audio():
    mic = _speechlike(20, seed=9)
    assert clean.clean_arrays(mic, np.zeros_like(mic)) is None


def test_export_mixes_inputs_with_different_sample_rates(tmp_path):
    sf.write(tmp_path / "mic.clean.flac", 0.3 * np.sin(2 * np.pi * 440 * np.arange(16000 * 2) / 16000).astype("float32"), 16000)
    sf.write(tmp_path / "system.flac", 0.3 * np.sin(2 * np.pi * 880 * np.arange(48000 * 2) / 48000).astype("float32"), 48000)
    out = tmp_path / "meeting.m4a"
    export_m4a([tmp_path / "mic.clean.flac", tmp_path / "system.flac"], out)
    rate = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=sample_rate", "-of", "csv=p=0", str(out)],
                          capture_output=True, text=True, check=True).stdout.strip()
    assert rate == "48000" and 1.8 < _duration(out) < 2.3


def test_clean_leaves_the_mic_alone_when_there_is_no_echo():
    # Headphones: the mic hears the user and the room, not the meeting.
    ref = _speechlike(60, seed=11)
    mic = _speechlike(60, seed=12) + 0.002 * np.random.default_rng(13).standard_normal(len(ref)).astype("float32")
    assert clean.clean_arrays(mic, ref) is None


def _fake_devices(monkeypatch, names):
    devices = [{"name": n, "max_input_channels": 1 if inp else 0} for n, inp in names]
    monkeypatch.setattr(audio.sd, "query_devices", lambda device=None, kind=None: (
        devices if device is None and kind is None
        else {"name": "Studio Mic"} if kind == "input" else devices[device]))


def test_find_input_device_prefers_the_exact_name(monkeypatch):
    _fake_devices(monkeypatch, [("USB Audio Pro", True), ("USB Audio", True), ("Speakers", False)])
    assert audio.find_input_device("USB Audio") == 1        # exact, not the first substring hit
    assert audio.find_input_device("usb audio pro") == 0    # case-insensitive
    assert audio.find_input_device("Pro") == 0              # substring still works
    assert audio.find_input_device("Speakers") is None      # output-only devices don't count
    assert audio.find_input_device("nothing like this") is None


def test_input_devices_lists_inputs_and_marks_the_default(monkeypatch):
    _fake_devices(monkeypatch, [("MacBook Mic", True), ("Studio Mic", True), ("Speakers", False)])
    assert audio.input_devices() == [
        {"name": "MacBook Mic", "channels": 1, "default": False},
        {"name": "Studio Mic", "channels": 1, "default": True},
    ]


def test_mic_only_flag_and_labels():
    parse = build_parser().parse_args
    assert parse(["record", "x"]).mic_only is False
    assert parse(["record", "x", "--mic-only", "--mic", "Studio"]).mic_only is True
    assert parse(["devices", "--json"]).json is True
    assert mic_label({"Me": "mic.flac", "Others": "system.flac"}) == "Me"
    assert mic_label({"Me": "mic.flac"}) == "Mic"


def test_two_meetings_with_the_same_title_get_separate_folders(tmp_path):
    first = session_dir(tmp_path, "Daily")
    second = session_dir(tmp_path, "Daily")
    third = session_dir(tmp_path, "Daily")
    assert len({first, second, third}) == 3
    assert second.name.endswith("-2") and third.name.endswith("-3")
    assert title_of(second) == "Daily 2"


def test_record_can_skip_processing_for_the_app_queue():
    parse = build_parser().parse_args
    assert parse(["record", "x"]).no_process is False
    assert parse(["record", "x", "--no-process"]).no_process is True
