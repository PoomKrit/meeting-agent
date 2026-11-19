"""meeting-agent: record + transcribe + note + summarize meetings."""

import argparse
import json
import re
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

from .export import export_m4a

DEFAULT_OUT = Path.home() / "meeting-notes"
LEVEL_INTERVAL = 0.1  # seconds between "[level]" lines
_print_lock = threading.Lock()


def emit(line: str) -> None:
    """One status line, written atomically: the level thread prints at the same time as the
    main thread, and the Mac app splits stdout on newlines."""
    with _print_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()
TRACKS = {"Me": "mic.flac", "Others": "system.flac"}


def session_dir(out: Path, title: str) -> Path:
    slug = re.sub(r'[\s/\\:*?"<>|]+', "-", title.strip()).strip("-") or "meeting"
    path = out / f"{datetime.now():%Y-%m-%d_%H%M}_{slug}"
    path.mkdir(parents=True, exist_ok=False)
    return path


def title_of(path: Path) -> str:
    return path.name.split("_", 2)[-1].replace("-", " ")


class RecordingClock:
    """Elapsed recorded time: wall time minus time spent paused."""

    def __init__(self):
        self._start = time.monotonic()
        self._paused_at: float | None = None
        self._paused_total = 0.0

    def elapsed(self) -> float:
        now = self._paused_at if self._paused_at is not None else time.monotonic()
        return now - self._start - self._paused_total

    @property
    def paused(self) -> bool:
        return self._paused_at is not None

    def pause(self) -> None:
        if self._paused_at is None:
            self._paused_at = time.monotonic()

    def resume(self) -> None:
        if self._paused_at is not None:
            self._paused_total += time.monotonic() - self._paused_at
            self._paused_at = None


def take_notes(notes_path: Path, commands: dict | None = None) -> str | None:
    """Read lines from stdin until /end, /cancel, Ctrl+D or Ctrl+C; append each line as written.
    Returns "/end" or "/cancel" (record mode only), or None on Ctrl+D / Ctrl+C.

    `commands` maps slash-commands (record mode: /pause /resume /mute /unmute) to callbacks;
    without it those lines are saved as ordinary notes. The file is only created once a note is
    written: the Mac app keeps its own notes.rtfd and sends commands only, so a recording made
    from the app must not leave an empty notes.md behind."""
    commands = commands or {}
    hint = ", /pause /resume พักและอัดต่อ, /mute /unmute ปิด/เปิดเสียงฝั่งพี่, /cancel หยุดอัดโดยไม่ถอดเสียง" if commands else ""
    print(f"พิมพ์ note แล้วกด Enter{hint}, /end หรือ Ctrl+D เพื่อจบ")
    while True:
        try:
            line = input("note> ").rstrip("\n")
        except (EOFError, KeyboardInterrupt):
            print()
            return None
        if line.strip() == "/end" or (line.strip() == "/cancel" and commands):
            return line.strip()
        if line.strip() in commands:
            commands[line.strip()]()
        else:
            with notes_path.open("a", encoding="utf-8") as notes:
                notes.write(f"{line}\n")


def cmd_devices(args) -> None:
    from .audio import input_devices, list_input_devices

    if args.json:  # for the Mac app's microphone picker
        print(json.dumps(input_devices(), ensure_ascii=False))
    else:
        print("\n".join(list_input_devices()))


def cmd_record(args) -> None:
    from .audio import Track, find_input_device, level_percent
    from .transcribe import format_time

    system_device = None
    if not args.mic_only:  # mic-only needs no BlackHole: it records just the mic
        system_device = find_input_device(args.system)
        if system_device is None:
            sys.exit(
                f"ไม่พบ input device ที่ชื่อมี '{args.system}' — ติดตั้ง BlackHole หรือดูชื่อด้วย `meeting-agent devices`"
            )
    mic_device = find_input_device(args.mic) if args.mic else None
    if args.mic and mic_device is None:
        sys.exit(f"ไม่พบไมค์ที่ชื่อมี '{args.mic}' — ดูชื่อด้วย `meeting-agent devices`")

    path = session_dir(args.out, args.title)
    tracks = [Track(path / TRACKS["Me"], mic_device)]
    if not args.mic_only:
        tracks.append(Track(path / TRACKS["Others"], system_device))
    clock = RecordingClock()

    def pause():
        for track in tracks:
            track.paused = True
        clock.pause()
        emit("⏸ พักการอัดแล้ว")

    def resume():
        for track in tracks:
            track.paused = False
        clock.resume()
        emit("▶ อัดต่อแล้ว")

    def mute():
        tracks[0].muted = True  # only "Me"; the meeting side keeps recording
        emit("🔇 mic muted — ไม่อัดเสียงฝั่งพี่")

    def unmute():
        tracks[0].muted = False
        emit("🎙 mic unmuted — อัดเสียงฝั่งพี่ต่อ")

    stop_levels = threading.Event()

    def report_levels():
        # "[level] <me> <others>", each 0..100. A paused or muted track reads 0. Mic-only has no
        # second track: it reports 0 for it.
        while not stop_levels.wait(LEVEL_INTERVAL):
            levels = [level_percent(t.take_peak()) for t in tracks] + [0] * (2 - len(tracks))
            emit("[level] " + " ".join(map(str, levels)))

    for track in tracks:
        track.start()
    if args.mic_only:
        emit(f"● กำลังอัด  Mic: {tracks[0].name}")
    else:
        emit(f"● กำลังอัด  Me: {tracks[0].name}  |  Others: {tracks[1].name}")
    emit(f"  เก็บที่ {path}")
    if args.levels:
        threading.Thread(target=report_levels, daemon=True).start()
    commands = {"/pause": pause, "/resume": resume, "/mute": mute, "/unmute": unmute}
    try:
        ended_by = take_notes(path / "notes.md", commands)
    finally:
        stop_levels.set()
        for track in tracks:  # closes the FLAC files properly, whatever ended the run
            track.stop()
    emit(f"■ หยุดอัดแล้ว ({format_time(clock.elapsed())})")
    if ended_by == "/cancel":
        emit("✗ ยกเลิกแล้ว — ไม่ถอดเสียงและไม่สรุป (ไฟล์เสียงที่อัดไว้ยังอยู่)")
        return
    process(path, args.whisper_model, args.language, clean=not args.no_clean)


def cmd_note(args) -> None:
    # Notes are the user's own writing: saved as-is, never sent to the LLM.
    # With no audio there is no transcript, so there is nothing to analyse either.
    path = session_dir(args.out, args.title)
    print(f"โหมด manual note — เก็บที่ {path}")
    notes_path = path / "notes.md"
    take_notes(notes_path)
    print(f"✓ {notes_path}" if notes_path.exists() else "ไม่ได้จด note — ไม่มีไฟล์")


def cmd_process(args) -> None:
    process(args.dir, args.whisper_model, args.language, clean=not args.no_clean)


def mic_label(audio: dict) -> str:
    """Speaker label for mic.flac: "Me" next to a meeting track, "Mic" when it is the only one."""
    return "Me" if "Others" in audio else "Mic"


def write_atomic(path: Path, text: str) -> None:
    """Write via a ".part" file so a run killed mid-write can't leave a truncated result."""
    partial = path.with_name(path.name + ".part")
    partial.write_text(text, encoding="utf-8")
    partial.replace(path)


def process(path: Path, whisper_model: str, language: str | None, clean: bool = True) -> None:
    from .summarize import summarize
    from .transcribe import transcribe

    transcript_path = path / "transcript.txt"
    audio = {speaker: path / name for speaker, name in TRACKS.items() if (path / name).exists()}

    # "Me" = the mic. Remove the meeting audio the mic picked up from the speakers, using the
    # meeting track as reference. mic.flac stays as recorded; the cleaned copy feeds the .m4a,
    # VAD and Whisper. Never fatal: on any problem the original mic is used.
    mic_clean = path / "mic.clean.flac"
    if clean and "Me" in audio and "Others" in audio and not mic_clean.exists():
        try:
            from .clean import clean_mic

            print("กำลังล้างเสียงสะท้อนในไมค์ ...", flush=True)
            info = clean_mic(audio["Me"], audio["Others"], mic_clean)
            if info is None:
                print("ข้ามการล้างเสียงสะท้อน: ไม่มีเสียงประชุมใน system.flac หรือวัดดีเลย์ไม่ได้ ใช้เสียงไมค์เดิม")
            else:
                print(f"✓ {mic_clean} (ดีเลย์ {info['delay_min']:.2f}-{info['delay_max']:.2f} วินาที, {info['blocks']} ช่วง)")
        except Exception as error:  # echo cancellation must never block the minutes
            print(f"ล้างเสียงสะท้อนไม่สำเร็จ ใช้เสียงไมค์เดิม: {error}")
    if clean and "Me" in audio and mic_clean.exists():
        audio["Me"] = mic_clean
    # With a meeting track, the mic is "Me" (and the other side "Others"). Alone it can be anyone
    # in the room, so it is just "Mic".
    audio = {mic_label(audio) if speaker == "Me" else speaker: file for speaker, file in audio.items()}
    m4a_path = path / "meeting.m4a"
    if audio and not m4a_path.exists():
        try:
            export_m4a(list(audio.values()), m4a_path)
            print(f"✓ {m4a_path}")
        except (subprocess.CalledProcessError, FileNotFoundError) as error:
            # Not fatal: the transcript and summary don't depend on the .m4a.
            print(f"ส่งออก .m4a ไม่สำเร็จ: {getattr(error, 'stderr', None) or error}")
    if audio and not transcript_path.exists():
        write_atomic(transcript_path, transcribe(audio, whisper_model, language))
        print(f"✓ {transcript_path}")

    # The LLM sees the Whisper transcript only. notes.md is never read here.
    transcript = transcript_path.read_text(encoding="utf-8") if transcript_path.exists() else ""
    if not transcript.strip():
        print("ไม่มี transcript — ข้ามการสรุป (note ที่จดไว้ยังอยู่ใน notes.md)")
        return

    print("กำลังสรุปด้วย Claude Code ...")
    summary_path = path / "summary.md"
    write_atomic(summary_path, f"# {title_of(path)}\n\n{summarize(title_of(path), transcript, cwd=path)}")
    print(f"✓ {summary_path}")


def language_arg(value: str) -> str | None:
    """'auto' → None, which makes Whisper detect the language from the first 30 seconds."""
    return None if value == "auto" else value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="meeting-agent")
    sub = parser.add_subparsers(required=True)

    whisper = argparse.ArgumentParser(add_help=False)
    whisper.add_argument(
        "--no-clean", action="store_true",
        help="ไม่ล้างเสียงสะท้อนในไมค์ (ปกติใช้ system.flac เป็นเสียงอ้างอิงลบเสียงประชุมที่รั่วเข้าไมค์)",
    )
    whisper.add_argument("--whisper-model", default="turbo", help="whisper model: tiny|small|medium|large-v3|turbo (default: turbo)")
    whisper.add_argument(
        "--language", type=language_arg, default="en",
        help="ภาษาที่พูดในประชุม เช่น en, th (default: en) หรือ auto = ให้ Whisper เดาจาก 30 วินาทีแรก",
    )

    p = sub.add_parser("devices", help="แสดง input devices")
    p.add_argument("--json", action="store_true", help="พิมพ์เป็น JSON (ให้ Mac app ใช้ทำรายการไมค์)")
    p.set_defaults(func=cmd_devices)

    p = sub.add_parser("record", parents=[whisper], help="อัดเสียงประชุม (+ จด note เองระหว่างอัด) แล้วถอดเสียงและสรุปจาก transcript")
    p.add_argument("title")
    p.add_argument("--system", default="BlackHole", help="ชื่อ (บางส่วน) ของ device ที่รับเสียงจาก Teams/WebEx")
    p.add_argument("--mic", default=None, help="ชื่อ (บางส่วน) ของไมค์ (default: system default input)")
    p.add_argument("--out", type=Path, default=DEFAULT_OUT)
    p.add_argument("--mic-only", action="store_true", help="อัดจากไมค์อย่างเดียว (ไมค์เครื่องหรือไมค์ภายนอก) ไม่ต้องมี BlackHole/ประชุมออนไลน์ ป้ายใน transcript เป็น Mic")
    p.add_argument("--levels", action="store_true", help="พิมพ์ระดับเสียง '[level] me others' ทุก 0.1 วินาที (ให้ Mac app วาดแถบ)")
    p.set_defaults(func=cmd_record)

    p = sub.add_parser("note", help="โหมด note อย่างเดียว (ไม่อัดเสียง ไม่มีสรุป) เก็บแค่ notes.md")
    p.add_argument("title")
    p.add_argument("--out", type=Path, default=DEFAULT_OUT)
    p.set_defaults(func=cmd_note)

    p = sub.add_parser("process", parents=[whisper], help="ถอดเสียง (ถ้ายังไม่มี transcript) และสรุปใหม่ จากโฟลเดอร์ประชุม")
    p.add_argument("dir", type=Path)
    p.set_defaults(func=cmd_process)

    return parser


def main() -> None:
    # The Mac app cancels with SIGTERM. Turn it into a normal exit so `finally` blocks run (FLAC
    # files get closed) and subprocess.run() kills its ffmpeg / claude child instead of orphaning it.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    args = build_parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
