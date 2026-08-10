#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"
/usr/bin/plutil -lint Info.plist
if [[ "$(/usr/bin/plutil -extract CFBundleIconFile raw Info.plist)" != "AppIcon" ]]; then
    echo "Info.plist: missing AppIcon bundle setting" >&2
    exit 1
fi
if [[ -z "$(/usr/bin/plutil -extract CFBundleShortVersionString raw Info.plist)" ]]; then
    echo "Info.plist: missing release version" >&2
    exit 1
fi
if [[ -z "$(/usr/bin/plutil -extract PoseDtxReleaseDate raw Info.plist)" ]]; then
    echo "Info.plist: missing release date" >&2
    exit 1
fi
if /usr/bin/grep -ERq \
    'activeVideo(Min|Max)FrameDuration|isVideoMirroringSupported|automaticallyAdjustsVideoMirroring|isVideoMirrored' \
    Sources/HandVisionNative; then
    echo "Unsafe AVFoundation camera-connection selector found" >&2
    exit 1
fi
swift test
swift run HandVisionNative --self-test
