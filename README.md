# <img src="Resources/icons/app-icon.png" alt="Managerie icon" width="34" align="center" /> Managerie

Managerie is a macOS menu bar app that acts as a local voice hub.

It's great with Pi, but it's not Pi-only any app can send text to Managerie's local broker and have it spoken through the same centralized queue + playback system.

| Managerie macOS menu bar app | Managerie iOS companion app |
|---|---|
| <img src="docs/managerie-screenshot.png" alt="Managerie macOS screenshot" width="100%" /> | <img src="docs/managerie-ios-screenshot.png" alt="Managerie iOS screenshot" width="100%" /> |

For the iPhone companion app docs, see:

- `apps/managerie-ios/README.md`
- `apps/managerie-ios/SETUP.md`

## Install with Homebrew

```bash
brew tap swairshah/tap
brew install --cask managerie
```

Then launch Managerie from Applications (or via Spotlight) and start sending broker requests.

### Pi extensions

To use Managerie with Pi, install the managerie and [`pi-telemetry`](https://github.com/jademind/pi-telemetry) extensions:

```bash
pi install npm:@swairshah/managerie
pi install npm:@jademind/pi-telemetry
```

## What this app does

- Runs a local speech broker on `127.0.0.1:18091` (NDJSON over TCP)
- Accepts `speak`, `health`, and `stop` commands from any local client
- Queues and coordinates playback so multiple sources can share one voice pipeline
- Streams low-latency TTS audio
- Supports cloud providers (ElevenLabs / Google / Deepgram) and optional on-device local TTS
- Shows live status in the menu bar
- Supports instant stop (including global **Cmd+.**)
- Keeps request history (queued / playing / played / interrupted / failed)
- Optional remote WebSocket control API for iOS/phone clients (`ws://<host>:18092/ws`)

## Use it as a voice hub (from any app)

Example broker call:

```bash
echo '{"type":"speak","text":"Hello from another app","sourceApp":"my-app","sessionId":"abc-123"}' | nc 127.0.0.1 18091
```

Health check:

```bash
echo '{"type":"health"}' | nc 127.0.0.1 18091
```

Stop all speech:

```bash
echo '{"type":"stop"}' | nc 127.0.0.1 18091
```

## Remote control API (WebSocket)

Managerie also includes a WebSocket remote API intended for an iPhone companion app.

Default endpoint:

```text
ws://127.0.0.1:18092/ws
```

Use these env vars for tailnet exposure:

```bash
MANAGERIE_REMOTE_BIND=0.0.0.0
MANAGERIE_REMOTE_PORT=18092
MANAGERIE_REMOTE_TOKEN=<strong-shared-token>
```

Dev-only no-token override:

```bash
MANAGERIE_REMOTE_BIND=0.0.0.0
MANAGERIE_REMOTE_PORT=18092
MANAGERIE_REMOTE_ALLOW_INSECURE_NO_AUTH=1
```

Protocol docs:

- `docs/REMOTE_WS_PROTOCOL.md`
- `docs/IOS_REMOTE_PLAN.md`

## Pi-specific pieces in this repo

- **`Extensions/managerie`** - extracts `<voice>` tags from Pi responses and sends them to Managerie
- **`Sources/Managerie`** - menu bar app + broker + playback coordinator
- **`Sources/mnote`** - CLI client for enqueueing/stopping speech
- **`Sources/ManagerieClient`** - shared client helpers
- **`apps/managerie-ios`** - iPhone companion app scaffold (WebSocket client + session UI)

## Quick start (dev)

```bash
./run-dev.sh
```

## Build app bundle

```bash
./scripts/build-app.sh
open .build/Managerie.app
```

## Requirements

- macOS 13+
- `ffplay` for playback (`brew install ffmpeg`)
- For cloud mode: ElevenLabs API key (`ELEVEN_API_KEY` / `ELEVENLABS_API_KEY`), Google TTS API key (`GOOGLE_TTS_API_KEY`), or Deepgram API key (`DEEPGRAM_API_KEY` / `DEEPGRAM_TTS_API_KEY`)
- For local mode: `pocket-tts-cli` runtime plus model files (either bundled in full builds or downloaded on first use from the matching Managerie GitHub release model asset)

## Related projects

- [`pi-telemetry`](https://github.com/jademind/pi-telemetry) — structured runtime telemetry for Pi. Managerie reads telemetry heartbeats to show live agent state in the menu bar.
- [`pi-statusbar`](https://github.com/jademind/pi-statusbar) — a free macOS status bar app for Pi built on top of `pi-telemetry`. The menu bar status UX in Managerie was directly inspired by this project.

## Acknowledgements

- The menu bar status UX was inspired by [`pi-statusbar`](https://github.com/jademind/pi-statusbar).
- In our Pi workflow, we use both the [`pi-statusbar` extension](https://github.com/jademind/pi-statusbar) and this repo's **managerie extension** together.
