# TODO

## Replies to hook-based agents (claude-code / codex)

`SendHandler` fallback chain is currently: herdr pane (`herdr agent prompt`)
→ tmux pane → iTerm2 (AppleScript `write text`, no focus steal) → Terminal.app
(AppleScript `do script` into the tab owning the TTY).

- [ ] **Ghostty route** — Ghostty has no scripting API, so the only option is:
      focus the right window (reuse `JumpHandler`'s CGWindowList + Accessibility
      matching) → verify it is actually frontmost → post keystrokes via CGEvent
      → Enter. Steals focus briefly; must guard against typing into the wrong
      window if focus changes mid-send. Until then, Ghostty users need herdr
      or tmux.
- [ ] zellij `write-chars` route (cheap addition alongside tmux)
