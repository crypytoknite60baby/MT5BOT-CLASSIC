#!/usr/bin/env bash
set -euo pipefail

# scripts/docker-compile.sh — Compile MQL5 sources via Wine + MetaEditor in Docker
# Uses gmag11/metatrader5_vnc:1.0 which ships MetaEditor + Wine.
#
# Usage:
#   ./scripts/docker-compile.sh [WEMADEIT_dev.mq5]
#   Defaults to compiling WEMADEIT_dev.mq5
#
# Requires:
#   - Docker installed and running

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TARGET="${1:-WEMADEIT_dev.mq5}"
TARGET_EX5="${TARGET%.mq5}.ex5"
IMAGE="gmag11/metatrader5_vnc:1.0"
CONTAINER="mql-compile-$$"

if ! docker info &>/dev/null; then
  echo "ERROR: Docker is not running. Start Docker and try again."
  exit 1
fi

if [ ! -f "$PROJECT_DIR/$TARGET" ]; then
  echo "ERROR: Source file $TARGET not found in project root."
  exit 1
fi

echo "==> Compiling $TARGET via Wine + MetaEditor in Docker..."

# Remove old ex5 if present
rm -f "$PROJECT_DIR/$TARGET_EX5"

# Run container, copy sources, compile, copy ex5 back
docker run --name "$CONTAINER" -d "$IMAGE" tail -f /dev/null 2>/dev/null
trap 'docker rm -f "$CONTAINER" 2>/dev/null' EXIT

# Create MQL5 directory structure inside container
docker exec "$CONTAINER" mkdir -p "/root/.wine/drive_c/Users/User/AppData/Roaming/MetaQuotes/Terminal/Common/MQL5/Experts"

# Copy all .mq5 and .mqh files (they may be #included)
tar -c -C "$PROJECT_DIR" --include='*.mq5' --include='*.mqh' . |
  docker exec -i "$CONTAINER" tar -x -C "/root/.wine/drive_c/Users/User/AppData/Roaming/MetaQuotes/Terminal/Common/MQL5/Experts"

# Compile with MetaEditor64
docker exec "$CONTAINER" wine \
  "/root/.wine/drive_c/Program Files/MetaTrader 5/MetaEditor64.exe" \
  /compile:"$TARGET" \
  /inc:"/root/.wine/drive_c/Users/User/AppData/Roaming/MetaQuotes/Terminal/Common/MQL5" \
  /log:"/tmp/compile.log" \
  2>/dev/null || true

# Copy compiled ex5 back
if docker exec "$CONTAINER" test -f "/root/.wine/drive_c/Users/User/AppData/Roaming/MetaQuotes/Terminal/Common/MQL5/Experts/$TARGET_EX5"; then
  docker cp "$CONTAINER:/root/.wine/drive_c/Users/User/AppData/Roaming/MetaQuotes/Terminal/Common/MQL5/Experts/$TARGET_EX5" "$PROJECT_DIR/$TARGET_EX5"
  echo "SUCCESS: $TARGET_EX5 produced."
else
  echo "FAILED: $TARGET_EX5 not found. Check compile log:"
  docker exec "$CONTAINER" cat /tmp/compile.log 2>/dev/null || true
  exit 1
fi
