# managerie

Managerie connector extension for the [Pi coding agent](https://github.com/mariozechner/pi-coding-agent). Connects Pi sessions to the [Managerie](https://github.com/swairshah/Managerie) menu bar app — notifications, live agent status, reply injection, and optional voice output via `<voice>` tags.

## Features

- **Notification-first** - When a turn finishes, the agent's final message is forwarded to Managerie and surfaced as a macOS notification (click to jump back to the session)
- **Live status** - Streams agent state (thinking / reading / editing / running / done / error) plus project, cwd, and context usage to the Managerie menu bar
- **Reply injection** - Watches a per-PID inbox so Managerie (e.g. dictation) can inject messages back into the running Pi session
- **Port-free transport** - Events are written as files to Managerie's spool directory (`~/.pi/agent/managerie/events/`) — no sockets, no ports
- **Optional TTS** - Off by default. Enable with `/tts` to have Pi speak `<voice>` tagged summaries

## Requirements

**Managerie.app** must be installed and running (menu bar app):

```bash
brew tap swairshah/tap
brew install --cask swairshah/tap/managerie
```

Then launch Managerie from Applications — it runs in the menu bar.

## Installation

```bash
pi install npm:@swairshah/managerie
```

## Usage

Once installed, the extension automatically:

1. Shows the session PID in Pi's status bar (used by Managerie's jump handler to find the right terminal pane)
2. Sends live status events as the agent works
3. Forwards the final assistant message of each turn as a notification
4. Accepts injected replies (dictation) from Managerie

Voice output is opt-in — run `/tts` to enable it.

### Commands

| Command | Description |
|---------|-------------|
| `/tts` | Toggle TTS on/off (includes voice prompt injection) |
| `/tts-mute` | Mute audio (keeps voice tags in responses) |
| `/tts-voice <name>` | Change voice (`auto` = Managerie assigns per-session) |
| `/tts-style` | Toggle between succinct and verbose voice prompts |
| `/tts-say <text>` | Speak arbitrary text |
| `/tts-stop` | Stop current speech |
| `/tts-status` | Show current status |

### Global Shortcut

Press **Cmd+.** to stop speech at any time (requires Managerie.app running).

## How it works

1. The extension writes NDJSON event files (atomic tmp-write + rename) into `~/.pi/agent/managerie/events/`; Managerie watches and ingests them
2. Managerie's liveness is detected via a heartbeat file (`~/.pi/agent/managerie/app.alive`, touched every 10s by the app)
3. Agent messages become macOS notifications; clicking one jumps to the agent's terminal session
4. For replies, Managerie drops JSON files into `~/.pi/agent/managerie-inbox/<pid>/`; the extension watches this inbox and injects the text into the session
5. With `/tts` enabled, a system prompt teaches Pi to use `<voice>` tags; the extension extracts them from the stream and enqueues speech jobs with `sourceApp`, `sessionId`, and `pid` so Managerie can schedule per-session playback

## Publishing (maintainers)

From repo root:

```bash
./scripts/publish-managerie.sh --dry-run
./scripts/publish-managerie.sh --bump patch
```

Or from this directory:

```bash
npm run pack:preview
npm run publish:npm
```

## License

MIT
