#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"
/usr/bin/plutil -lint Info.plist
swift build -c release

echo "Release executable: $(swift build -c release --show-bin-path)/HandVisionNative"
