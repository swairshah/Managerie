# Releasing Managerie

Releases are automated by a single script:

```bash
./scripts/release.sh <version>              # full release
./scripts/release.sh <version> --skip-notarize   # local test build, no Apple round-trip
```

Example:

```bash
./scripts/release.sh 1.3.0
```

---

## What the script does

`scripts/release.sh` will:

1. Update `VERSION` in `scripts/build-app.sh`
2. Build a universal (arm64 + x86_64) app bundle via `scripts/build-app.sh --universal` (Managerie + `mnote`)
3. Sign the bundle with hardened runtime and entitlements
   (`Sources/Managerie/Managerie.entitlements` — required for microphone
   access and Apple events; the script fails if the `audio-input`
   entitlement is missing from the signature)
4. Notarize the app with Apple (`xcrun notarytool`) and staple the ticket
5. Create a DMG (`create-dmg`, falling back to `hdiutil`), sign, notarize, and staple it → `dist/Managerie-<version>.dmg`
6. Zip the pi extension → `dist/managerie-<version>.zip`
7. Print the DMG SHA256 and update `~/work/projects/homebrew-tap/Casks/managerie.rb` (if present)
8. Interactively (each step asks Y/n):
   - Commit the version bump
   - Create and push git tag `v<version>` (pushes `main` too)
   - Create the GitHub release with the DMG + extension zip (`gh release create`)
   - Commit and push the Homebrew tap update

---

## Prerequisites

- Developer ID Application certificate in the keychain
  (`Developer ID Application: Swair Rajesh Shah (8B9YURJS4G)`)
- `APPLE_APP_PASSWORD` (app-specific password) in `~/.env` — or use `--skip-notarize`
- `create-dmg` (`brew install create-dmg`; the script installs it if missing)
- `gh` CLI for the GitHub release step (optional; skipped if absent)

---

## pi extension (npm)

The script only creates `dist/managerie-<version>.zip`.
Publishing `@swairshah/managerie` to npm is a separate step:

```bash
cd Extensions/managerie
npm publish --access public
```

---

## Post-install notes for users

After `brew install --cask swairshah/tap/managerie`:

1. Open Managerie.app (menu bar app)
2. Agent integrations (pi / Claude Code / Codex) are installed automatically
   on first launch; removal from Settings is sticky and won't reinstall
3. Grant microphone (dictation) and Accessibility (terminal focusing)
   permissions when prompted
