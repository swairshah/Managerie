#!/bin/bash
set -e

# Change to project root (parent of scripts/)
cd "$(dirname "$0")/.."

# Version - update this for releases
VERSION="1.3.0"

echo "🔨 Building Managerie.app v$VERSION..."

UNIVERSAL=false

for arg in "$@"; do
    case "$arg" in
        --universal)
            UNIVERSAL=true
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Usage: ./scripts/build-app.sh [--universal]"
            exit 1
            ;;
    esac
done

# The app ships the pi extension as a bundled resource and writes it straight
# into ~/.pi/agent/extensions. Keep it in lockstep with the npm source so a
# release can't ship a stale extension.
if ! cmp -s Extensions/managerie/index.ts Sources/Managerie/Resources/managerie-extension.ts; then
    echo "Syncing bundled pi extension from Extensions/managerie/index.ts..."
    cp Extensions/managerie/index.ts Sources/Managerie/Resources/managerie-extension.ts
fi

if [ "$UNIVERSAL" = true ]; then
    echo "Building universal binary (arm64 + x86_64)..."
    swift build -c release --arch arm64 --arch x86_64 --product Managerie
    swift build -c release --arch arm64 --arch x86_64 --product mnote
    # Universal output path moved across Swift toolchains
    if [ -d ".build/apple/Products/Release" ]; then
        BINARY_PATH=".build/apple/Products/Release"
    else
        BINARY_PATH=".build/out/Products/Release"
    fi
else
    echo "Building for current architecture..."
    swift build -c release --product Managerie
    swift build -c release --product mnote
    BINARY_PATH=".build/release"
fi

# Create app bundle structure
APP_DIR=".build/Managerie.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy Swift executable
cp "$BINARY_PATH/Managerie" "$APP_DIR/Contents/MacOS/"

# Copy CLI tool
cp "$BINARY_PATH/mnote" "$APP_DIR/Contents/MacOS/"

# Copy app icon
cp Resources/icons/AppIcon.icns "$APP_DIR/Contents/Resources/"

# Copy SPM resource bundle (contains Assets.car and Resources/)
if [ -d "$BINARY_PATH/Managerie_Managerie.bundle" ]; then
    echo "Copying resource bundle Managerie_Managerie.bundle..."
    cp -R "$BINARY_PATH/Managerie_Managerie.bundle" "$APP_DIR/Contents/Resources/"
else
    echo "⚠️  Warning: Managerie_Managerie.bundle not found at $BINARY_PATH"
    echo "   The app may fail to launch without its resource bundle."
fi

# Copy menubar icons (also keep at top level for backward compat)
cp Sources/Managerie/Resources/menubar_on.png "$APP_DIR/Contents/Resources/"
cp Sources/Managerie/Resources/menubar_off.png "$APP_DIR/Contents/Resources/"

# Create Info.plist (note: no quotes around EOF to allow variable expansion)
cat > "$APP_DIR/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Managerie</string>
    <key>CFBundleIdentifier</key>
    <string>com.managerie.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Managerie</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026. All rights reserved.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Managerie needs microphone access so you can talk back to your agent sessions.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Managerie uses on-device speech recognition to turn voice replies into text.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Managerie controls your terminal (Ghostty, iTerm2, Terminal) to jump to the session an agent is waiting in.</string>
</dict>
</plist>
EOF

# Create PkgInfo
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

echo ""
# Ad-hoc sign with the real entitlements + hardened runtime.
#
# Dev builds used to ship unsigned, which meant they got microphone access that
# the notarized release build did not — the entitlement bug was invisible until
# someone installed from Homebrew. Signing dev builds the same way keeps the two
# honest. audio-input and apple-events are unrestricted, so ad-hoc works fine.
ENTITLEMENTS="Sources/Managerie/Managerie.entitlements"
if [ -f "$ENTITLEMENTS" ]; then
    codesign --force --deep --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign - "$APP_DIR" 2>/dev/null
    if codesign -d --entitlements - "$APP_DIR" 2>/dev/null | grep -q "audio-input"; then
        echo "🔏 Ad-hoc signed with entitlements (mic + apple events)"
    else
        echo "⚠️  Ad-hoc signing did not apply entitlements"
    fi
fi

echo "✅ Built: $APP_DIR"
echo "✅ Built: $BINARY_PATH/mnote (CLI tool)"
echo ""
echo "To run the app:"
echo "  open $APP_DIR"
echo ""
echo "To install the CLI:"
echo "  cp $BINARY_PATH/mnote ~/.local/bin/"
echo ""

APP_SIZE=$(du -sh "$APP_DIR" | cut -f1)
echo "📦 App size: $APP_SIZE"
