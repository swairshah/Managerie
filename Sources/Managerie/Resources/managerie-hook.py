#!/usr/bin/env python3
"""Managerie agent hook — forwards agent events to the Managerie app.

Usage:
  managerie-hook.py claude-stop          Claude Code Stop hook (JSON on stdin)
  managerie-hook.py claude-notification  Claude Code Notification hook (JSON on stdin)
  managerie-hook.py codex-hook           Codex lifecycle hook (JSON on stdin, ~/.codex/hooks.json)
  managerie-hook.py codex [json]         Codex notify program (JSON as final arg, legacy)

Drops NDJSON `speak` events into Managerie's file spool
(~/.pi/agent/managerie/events/) — no ports, no sockets. Managerie watches the
directory and surfaces events as macOS notifications.
Events written while the app is closed are delivered on its next launch.
"""
import json
import os
import sys
import time
import uuid

SPOOL_DIR = os.path.expanduser("~/.pi/agent/managerie/events")


def send(obj):
    try:
        os.makedirs(SPOOL_DIR, exist_ok=True)
        # Zero-padded ms timestamp keeps lexicographic order == arrival order.
        name = "%013d-%d-%s.json" % (
            time.time_ns() // 1_000_000,
            os.getpid(),
            uuid.uuid4().hex[:6],
        )
        tmp = os.path.join(SPOOL_DIR, ".%s.tmp" % name)
        with open(tmp, "w") as f:
            f.write(json.dumps(obj) + "\n")
        os.replace(tmp, os.path.join(SPOOL_DIR, name))  # atomic publish
    except Exception:
        pass  # never block the agent


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


def codex_hook():
    """Codex >= 0.14x lifecycle hook (hooks.json). JSON arrives on stdin with
    `hook_event_name`; the Stop payload carries the final assistant message.

    Unlike the legacy `notify` program (a single-value TOML key), hooks are a
    list per event, so Managerie coexists with other Codex tooling.
    """
    try:
        data = json.load(sys.stdin)
    except Exception:
        return

    event = data.get("hook_event_name", "")
    if event == "Stop":
        text = data.get("last_assistant_message") or "Codex finished a turn"
    elif event == "StopFailure":
        text = data.get("error") or data.get("message") or "Codex turn ended with an error"
    else:
        return  # only notify at turn end

    send({
        "type": "speak",
        "text": clip(text),
        "sourceApp": "codex",
        "sessionId": str(data.get("session_id") or "") or None,
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
        "codex-hook": codex_hook,
        "codex": codex,
    }.get(mode)
    if handler:
        handler()


if __name__ == "__main__":
    main()
