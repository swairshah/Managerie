#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

BASE_APP_PATH=".build/Managerie.app"
APP_PATH=".build/ManagerieDev.app"
APP_BIN="$APP_PATH/Contents/MacOS/Managerie"
RUN_BIN="$APP_BIN"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Managerie Dev Build & Run ===${NC}"

# Build
echo -e "${YELLOW}Building...${NC}"
swift build

# Ensure base app bundle exists (used as template for a writable dev app)
if [ ! -d "$BASE_APP_PATH" ]; then
    echo -e "${YELLOW}Creating base app bundle...${NC}"
    ./scripts/build-app.sh
fi

# Ensure writable dev app bundle exists
if [ ! -d "$APP_PATH" ]; then
    echo -e "${YELLOW}Creating writable dev app bundle...${NC}"
    cp -R "$BASE_APP_PATH" "$APP_PATH"
fi

# Update binary in app bundle with debug build
# On newer macOS versions this can fail with "Operation not permitted"
# if Terminal lacks App Management permission for modifying .app bundles.
echo -e "${YELLOW}Updating app bundle with debug build...${NC}"
if cp .build/debug/Managerie "$APP_BIN"; then
    codesign --force --sign - "$APP_PATH"
else
    echo -e "${YELLOW}Warning: Could not update .app bundle (likely App Management permission).${NC}"
    echo -e "${YELLOW}Falling back to running .build/debug/Managerie directly.${NC}"
    RUN_BIN=".build/debug/Managerie"
fi

# Run Managerie with debug logging enabled
echo -e "${GREEN}Launching Managerie (debug mode)...${NC}"
MANAGERIE_DEBUG=1 "$RUN_BIN" &
PID=$!

sleep 1
echo -e "${GREEN}Managerie is running (PID: $PID)${NC}"
echo -e "Click the menubar icon to open the status panel."
echo ""
echo -e "To stop: ${YELLOW}pkill -f Managerie${NC}"
echo -e "To test: ${YELLOW}echo '{\"type\":\"speak\",\"text\":\"Hello world\"}' | nc localhost 18091${NC}"
