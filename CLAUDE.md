# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Managerie is a macOS menu bar application that acts as a notification hub for local coding agents (Pi, Codex, Claude Code, …). Agents send messages/status to a local TCP broker; Managerie surfaces messages as macOS user notifications (click → jump to the agent's terminal session), shows live agent status, and supports dictation (speech→text) into sessions. Voice playback (TTS via ElevenLabs/Google/Deepgram/local, played through `ffplay`) still exists but is opt-in, gated by the `ttsEnabled` UserDefaults flag (default **off**).

## Build & Run Commands

```bash
swift build                          # Debug build
swift build -c release               # Release build
./run-dev.sh                         # Debug build + launch with MANAGERIE_DEBUG=1
./run.sh                             # Build + launch via open, with health checks
./scripts/build-app.sh               # Release build + create .app bundle
./scripts/build-app.sh --universal   # Universal binary (arm64 + x86_64)
./scripts/release.sh <version>       # Full release: build, notarize, staple, homebrew
```

There are no tests or linter configured.

## Architecture

**Swift Package Manager** (swift-tools-version: 5.9, macOS 13+). Three targets, zero external Swift dependencies:
- `Managerie` — main menu bar app (SwiftUI MenuBarExtra)
- `ManagerieClient` — shared HTTP client library for TTS server
- `mnote` — CLI tool (depends on ManagerieClient)

### Core Components (all in `ManagerieApp.swift` ~2600 lines)

- **ManagerieApp** (`@main`) — SwiftUI app entry point with MenuBarExtra
- **AppDelegate** — Sets up global Cmd+. hotkey (Carbon), owns the coordinator, broker, mic monitor, health server. Singleton via `AppDelegate.shared`
- **LocalSpeechBroker** — TCP server on port 18091 (NWListener). Accepts NDJSON commands: `speak`, `health`, `stop`, `status`
- **SpeechPlaybackCoordinator** — Central playback engine. Per-source queue buckets keyed by `sourceApp::sessionId`. Round-robin scheduling, auto voice assignment from pool. Streams ElevenLabs audio to temp MP3, plays via `ffplay`. Uses serial DispatchQueue for thread safety and UUID nonces for stale job detection
- **HealthHTTPServer** — HTTP server on port 18090, returns `{"ok":true}` at `/health`
- **MicrophoneActivityMonitor** — Polls CoreAudio input device state; interrupts speech when mic is active
- **RequestHistoryStore** — Singleton, persists to `~/Library/Application Support/Managerie/request-history.json` (max 250 entries)
- All SwiftUI views (Settings, Sessions, History, About) are also in this file

### Supporting Files

- **AgentStatusStore** (`AgentStatusStore.swift`) — Singleton, thread-safe store for real-time agent status events received from the managerie extension via the broker. Replaces telemetry file polling.
- **VoiceMonitor** (`VoiceMonitor.swift`) — `@MainActor ObservableObject`, push/event-driven via `AgentStatusStore` + `RequestHistoryStore` publishers (no polling timer), drives the UI
- **JumpHandler** (`JumpHandler.swift`) — Focuses terminal windows for a PID. Supports Ghostty (CGWindowList + Accessibility API), iTerm2/Terminal (AppleScript), tmux/zellij detection
- **SendHandler** (`SendHandler.swift`) — Sends text to terminal sessions via tmux `send-keys`, zellij `write-chars`, or Ghostty keystrokes
- **TTSClient** (`ManagerieClient/TTSClient.swift`) — HTTP client for TTS server (legacy local TTS voice names, not the current ElevenLabs voices)

### Pi Extension (`Extensions/managerie/`)

TypeScript npm package (`@swairshah/managerie`) for the Pi coding agent. Extracts `<voice>` tags from streaming responses and sends speech to the broker on port 18091.

## Key Patterns

- Debug logging gated by `MANAGERIE_DEBUG=1` env var (duplicated `fileprivate let debugEnabled` in multiple files)
- UserDefaults for settings (voice, API key, server enabled stored inverted as "serverDisabled", speech speed, dock icon, launch at login, `ttsEnabled` master TTS switch — default false, `notificationsEnabled` — default true)
- **AgentNotificationManager** (`NotificationManager.swift`) — posts UNUserNotifications for agent messages; notification tap / "Jump to Session" action calls `JumpHandler.jump(to:)`. Every `speak` request is notified; playback only happens when `ttsEnabled` is true (otherwise history entries get status `.notified`)
- `LSUIElement=true` — menu bar app, dock icon is toggleable
- App bundle ID: `com.managerie.app`
- Notification-first flow: broker `speak` → history + notification → (optional) TTS queue
- ElevenLabs voices: `ally` (default), `dorothy`, `lily`, `alice`, `dave`, `joseph` using `eleven_flash_v2_5` model
- Local Pocket TTS voices: `alba`, `vera`, `paul`, `charles`, `michael`, `anna`, `fantine`, `eponine`, `cosette`, `eve`, `george`, `mary`, `marius`, `javert`, `azelma`, `caro_davy`, `peter_yearsley`, `stuart_bell`
- Requires `ffplay` (ffmpeg) for audio playback and Accessibility permissions for terminal focusing

## Network Ports

| Port  | Protocol   | Purpose                        |
|-------|------------|--------------------------------|
| 18090 | HTTP       | Health check server            |
| 18091 | TCP/NDJSON | Speech broker (speak/stop/health) |

## IPC Protocol

Broker protocol documented in `docs/IPC.md`. NDJSON over TCP on port 18091.
