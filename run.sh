#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_PATH=".build/Managerie.app"
APP_BIN="$APP_PATH/Contents/MacOS/Managerie"
MNOTE_BIN="$APP_PATH/Contents/MacOS/mnote"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Managerie Build & Run ===${NC}"

# Kill existing Managerie + embedded server
pkill -f "$APP_BIN" 2>/dev/null || true

# Build debug binaries
echo -e "${YELLOW}Building (swift build)...${NC}"
swift build

# Ensure app bundle exists (created by scripts/build-app.sh)
if [ ! -d "$APP_PATH" ]; then
  echo -e "${RED}Missing $APP_PATH${NC}"
  echo -e "Create it once with: ${YELLOW}./scripts/build-app.sh${NC}"
  exit 1
fi

# Replace app bundle binaries with fresh debug builds
echo -e "${YELLOW}Updating app bundle binaries...${NC}"
cp .build/debug/Managerie "$APP_BIN"
cp .build/debug/mnote "$MNOTE_BIN"

# Keep CLI in PATH in sync (if local bin exists)
if [ -d "$HOME/.local/bin" ]; then
  cp .build/debug/mnote "$HOME/.local/bin/mnote"
  chmod +x "$HOME/.local/bin/mnote"
fi

# Launch app
echo -e "${GREEN}Launching Managerie...${NC}"
open "$APP_PATH"
sleep 2

# Quick health checks
if pgrep -f "$APP_BIN" >/dev/null; then
  echo -e "${GREEN}Managerie process: running${NC}"
else
  echo -e "${RED}Managerie process: not running${NC}"
fi

if curl -fsS http://127.0.0.1:18090/health >/dev/null 2>&1; then
  echo -e "${GREEN}TTS server (18090): healthy${NC}"
else
  echo -e "${RED}TTS server (18090): not healthy yet${NC}"
fi

if nc -z 127.0.0.1 18091 >/dev/null 2>&1; then
  echo -e "${GREEN}Broker (18091): listening${NC}"
else
  echo -e "${RED}Broker (18091): not listening${NC}"
fi

echo -e "${GREEN}Done.${NC}"
