# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Managerie is a macOS menu bar application that acts as a notification hub for local coding agents (Pi, Codex, Claude Code, …). Agents send messages/status to Managerie via a port-free file event spool; Managerie surfaces messages as macOS user notifications (click → jump to the agent's terminal session), shows live agent status, and supports dictation (speech→text) into sessions.

**There is no text-to-speech.** TTS was removed entirely — no providers, no audio playback, no `ffplay`. Dictation is the only speech feature and runs on Apple's on-device recognizer, so the app needs no API keys at all. The event verb is still named `speak` purely for wire compatibility with installed hooks/extensions; it means "deliver this message".

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

**Swift Package Manager** (swift-tools-version: 5.9, macOS 13+). Two targets, zero external Swift dependencies:
- `Managerie` — main menu bar app (SwiftUI MenuBarExtra)
- `mnote` — CLI tool (depends on ManagerieClient)

### Core Components (all in `ManagerieApp.swift` ~2600 lines)

- **ManagerieApp** (`@main`) — SwiftUI app entry point with MenuBarExtra
- **AppDelegate** — Owns the event spool watcher and remote runtime, sets up hotkeys. Singleton via `AppDelegate.shared`
- **EventSpoolWatcher** (`EventSpool.swift`) — watches `~/.pi/agent/managerie/events/` for NDJSON event files (`speak`, `status`; `health`/`stop` accepted as no-ops) and maintains the `app.alive` heartbeat file
- **BrokerRequestProcessor** — Shared processing pipeline (spool + WebSocket remote). `deliver()` records history + posts the notification
- **RequestHistoryStore** — Singleton, persists to `~/Library/Application Support/Managerie/request-history.json` (max 250 entries)
- All SwiftUI views (Settings, Sessions, History, About) are also in this file

### Supporting Files

- **AgentStatusStore** (`AgentStatusStore.swift`) — Singleton, thread-safe store for real-time agent status events received from the managerie extension via the broker. Replaces telemetry file polling.
- **VoiceMonitor** (`VoiceMonitor.swift`) — `@MainActor ObservableObject`, push/event-driven via `AgentStatusStore` + `RequestHistoryStore` publishers (no polling timer), drives the UI
- **IntegrationsManager** (`IntegrationsManager.swift`) — installs/removes agent integrations: pi (writes `~/.pi/agent/extensions/managerie.ts`, which pi auto-loads), claude-code (hooks in `~/.claude/settings.json`), codex (lifecycle hooks in `~/.codex/hooks.json`). Never shells out to a CLI, so it works from a GUI app with no nvm/node PATH. Runs automatically at launch via `autoInstallIfNeeded()` for agents the user has; explicit removal sets a sticky `integrationOptOut.<agent>` flag so a launch never reinstalls it. Paths are injectable (`init(home:)`) for tests
- **JumpHandler** (`JumpHandler.swift`) — Focuses terminal windows for a PID. Supports Ghostty (CGWindowList + Accessibility API), iTerm2/Terminal (AppleScript), tmux/zellij detection
- **SendHandler** (`SendHandler.swift`) — Sends text to terminal sessions via tmux `send-keys`, zellij `write-chars`, or Ghostty keystrokes

### Pi Extension (`Extensions/managerie/`)

TypeScript npm package (`@swairshah/managerie`) for the Pi coding agent. Forwards messages, live status, and inbox replies via the file spool. v2.0.0 removed all `<voice>`/`/tts*` support.

## Key Patterns

- Debug logging gated by `MANAGERIE_DEBUG=1` env var (duplicated `fileprivate let debugEnabled` in multiple files)
- UserDefaults for settings (server enabled stored inverted as "serverDisabled", dock icon, launch at login, `notificationsEnabled` — default true, `notificationChimeEnabled` — default true, `notifyOnlyWhenIdle` — default false, `integrationOptOut.<agent>`)
- **AgentNotificationManager** (`NotificationManager.swift`) — posts UNUserNotifications for agent messages; notification tap / "Jump to Session" action calls `JumpHandler.jump(to:)`. Banner visibility honours `notificationsEnabled` + `notifyOnlyWhenIdle`; the chime is independent (`notificationChimeEnabled`)
- `LSUIElement=true` — menu bar app, dock icon is toggleable
- App bundle ID: `com.managerie.app`
- Flow: `speak` event (spool) → history entry → notification
- Requires Accessibility permission for terminal focusing, Microphone + Speech Recognition for dictation

## IPC

No local TCP ports — agent ingestion is entirely file-based (spool + `app.alive` heartbeat), documented in `docs/IPC.md`. The only network listener is the optional WebSocket remote for the iOS companion app (`docs/REMOTE_WS_PROTOCOL.md`).
