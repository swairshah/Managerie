# Managerie IPC Design (Broker)

Managerie ingests agent events through two transports:

- **File spool (primary)** — NDJSON files dropped into `~/.pi/agent/managerie/events/`.
  No ports, no races. Events written while the app is closed are delivered on
  its next launch.
- **TCP broker (compat)** — `127.0.0.1:18091`, NDJSON over TCP (one JSON object
  per line), for existing clients.

For remote iOS/WebSocket control, see `docs/REMOTE_WS_PROTOCOL.md`.

## Commands

### speak

Delivers an agent message: it's recorded in history and surfaced as a macOS
notification. Clicking the notification jumps to that agent's session.

> The verb is named `speak` for historical reasons — Managerie used to speak
> messages aloud. Text-to-speech has been removed; the name is retained so
> already-installed hooks and extensions keep working.

```json
{"type":"speak","text":"Hello","sourceApp":"pi","sessionId":"abc","pid":12345}
```

Fields:
- `text` (required)
- `sourceApp` (optional)
- `sessionId` (optional)
- `pid` (optional) — used to jump to the originating terminal session

### health

```json
{"type":"health"}
```

### stop

Accepted and acknowledged, but a no-op — retained so older clients don't error.

```json
{"type":"stop"}
```

### status

Reports agent activity status (sent by the managerie extension).

```json
{"type":"status","pid":12345,"project":"my-app","cwd":"/Users/me/my-app","status":"editing","detail":"App.swift","contextPercent":42}
```

Fields:
- `pid` (required) — process ID of the pi agent
- `status` (required) — one of: `starting`, `thinking`, `reading`, `editing`, `running`, `searching`, `done`, `error`, `remove`
- `project` (optional) — project/directory name
- `cwd` (optional) — working directory path
- `detail` (optional) — extra context (filename, command, etc.)
- `contextPercent` (optional) — context window usage percentage

To remove an agent (e.g. on shutdown):
```json
{"type":"status","pid":12345,"status":"remove"}
```

## Response shape

Responses are JSON lines and can include:
- `ok`
- `error`

## Notification behavior

Every `speak` becomes a history entry. Whether it also raises a banner depends
on settings:

- **Show Notifications** — master switch for banners.
- **Only When Idle** — suppresses mid-turn messages; only the final message of
  a turn raises a banner. Sessions reporting live status (pi) are checked
  against that status; hook-based sessions (claude-code, codex) only send at
  turn end, so they always qualify.
- **Notification Sound** — the idle chime, independent of banners. It fires on
  the working→idle transition for status-tracked sessions, and on message
  arrival for hook-based ones (debounced per session).
