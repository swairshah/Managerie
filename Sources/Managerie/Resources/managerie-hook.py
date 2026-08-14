#!/usr/bin/env python3
"""Managerie agent hook — forwards agent events to the Managerie broker.

Usage:
  managerie-hook.py claude-stop          Claude Code Stop hook (JSON on stdin)
  managerie-hook.py claude-notification  Claude Code Notification hook (JSON on stdin)
  managerie-hook.py codex [json]         Codex notify program (JSON as final arg)

Sends NDJSON `speak` commands to the Managerie broker on 127.0.0.1:18091.
Managerie surfaces them as macOS notifications (and optional TTS).
"""
import json
import os
import socket
import sys

PORT = 18091


def send(obj):
    try:
        s = socket.create_connection(("127.0.0.1", PORT), timeout=1.5)
        s.sendall((json.dumps(obj) + "\n").encode())
        try:
            s.recv(4096)
        except Exception:
            pass
        s.close()
    except Exception:
        pass  # Managerie not running — never block the agent


def clip(text, limit=400):
    text = " ".join((text or "").split())
    return text[:limit]


def claude_stop():
    try:
        data = json.load(sys.stdin)
    except Exception:
        data = {}
    text = ""
    transcript = data.get("transcript_path")
    if transcript and os.path.exists(transcript):
        try:
            with open(transcript) as f:
                lines = f.readlines()[-80:]
            for line in reversed(lines):
                try:
                    entry = json.loads(line)
                except Exception:
                    continue
                if entry.get("type") == "assistant":
                    content = (entry.get("message") or {}).get("content") or []
                    texts = [
                        part.get("text", "")
                        for part in content
                        if isinstance(part, dict) and part.get("type") == "text"
                    ]
                    if texts and texts[-1].strip():
                        text = texts[-1]
                        break
        except Exception:
            pass
    send({
        "type": "speak",
        "text": clip(text) or "Finished a turn — waiting for you",
        "sourceApp": "claude-code",
        "sessionId": data.get("session_id"),
        "pid": os.getppid(),
    })


def claude_notification():
    try:
        data = json.load(sys.stdin)
    except Exception:
        data = {}
    send({
        "type": "speak",
        "text": clip(data.get("message")) or "Claude needs your attention",
        "sourceApp": "claude-code",
        "sessionId": data.get("session_id"),
        "pid": os.getppid(),
    })


def codex():
    payload = {}
    if len(sys.argv) > 2:
        try:
            payload = json.loads(sys.argv[-1])
        except Exception:
            payload = {}
    event_type = payload.get("type")
    if event_type not in (None, "", "agent-turn-complete"):
        return
    text = payload.get("last-assistant-message") or "Codex finished a turn"
    send({
        "type": "speak",
        "text": clip(text),
        "sourceApp": "codex",
        "sessionId": str(payload.get("turn-id") or "") or None,
        "pid": os.getppid(),
    })


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    handler = {
        "claude-stop": claude_stop,
        "claude-notification": claude_notification,
        "codex": codex,
    }.get(mode)
    if handler:
        handler()


if __name__ == "__main__":
    main()
