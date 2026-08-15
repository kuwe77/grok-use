#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
mkdir -p "$ROOT/bin"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -O -o "$ROOT/bin/grok-use-helper" \
  "$ROOT/Sources/main.swift" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework Foundation
chmod +x "$ROOT/bin/grok-use-helper" "$ROOT/mcp/server.py"
echo "built $ROOT/bin/grok-use-helper"
"$ROOT/bin/grok-use-helper" permissions
