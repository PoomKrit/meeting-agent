"""Summarize the Whisper transcript with Claude Code (headless `claude -p`).

Whisper does speech-to-text only; all analysis and next actions come from Claude Code.
"""

import json
import os
import shutil
import subprocess
from pathlib import Path

# Alias resolved by Claude Code settings (ANTHROPIC_DEFAULT_SONNET_MODEL → Bedrock Sonnet 5.5).
MODEL = os.environ.get("MEETING_AGENT_MODEL", "sonnet")
PROMPT_FILE = Path(__file__).with_name("minutes_prompt.md")


def build_user_message(title: str, transcript: str) -> str:
    return f"Meeting title: {title}\n\n<transcript>\n{transcript.strip()}\n</transcript>"


def find_claude() -> str:
    path = shutil.which("claude") or str(Path.home() / ".local/bin/claude")
    if not Path(path).exists():
        raise RuntimeError("ไม่พบคำสั่ง `claude` (Claude Code) — ติดตั้งก่อน หรือเพิ่มเข้า PATH")
    return path


def summarize(title: str, transcript: str, cwd: Path) -> str:
    # --bare: skip the user's hooks/plugins/CLAUDE.md so they don't change the output format.
    # Bedrock credentials still come from ~/.claude/settings.json.
    # --tools "": pure text generation, no file or shell access.
    cmd = [
        find_claude(), "-p", "--bare",
        "--tools", "",
        "--model", MODEL,
        "--no-session-persistence",
        "--system-prompt", PROMPT_FILE.read_text(encoding="utf-8"),
        "--output-format", "json",
    ]
    result = subprocess.run(
        cmd,
        input=build_user_message(title, transcript),
        capture_output=True,
        text=True,
        cwd=cwd,
        timeout=1800,  # detailed minutes of a long meeting can take several minutes to generate
    )
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise RuntimeError(f"Claude Code ล้มเหลว (exit {result.returncode}): {result.stderr.strip() or result.stdout.strip()}")
    if data.get("is_error"):
        raise RuntimeError(f"Claude Code error: {data.get('result')}")
    return data["result"].strip() + "\n"
