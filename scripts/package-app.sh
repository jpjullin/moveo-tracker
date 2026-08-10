#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/Moveo Tracker.app"
CONTENTS_DIR="$APP_DIR/Contents"
ICON_WORK_DIR="$PROJECT_DIR/.build/moveo-tracker-app-icon"
ICONSET_DIR="$ICON_WORK_DIR/AppIcon.iconset"
BUNDLE_IDENTIFIER="site.posedtx.moveo-tracker"

case "$APP_DIR" in
    "$PROJECT_DIR"/dist/*) ;;
    *) echo "Refusing unexpected package path: $APP_DIR" >&2; exit 1 ;;
esac

cd "$PROJECT_DIR"
/usr/bin/plutil -lint Info.plist
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BIN_DIR/MoveoTracker" "$CONTENTS_DIR/MacOS/MoveoTracker"
cp "$PROJECT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

rm -rf "$ICON_WORK_DIR"
mkdir -p "$ICONSET_DIR"
/usr/bin/xcrun swift "$SCRIPT_DIR/generate-app-icon.swift" "$ICONSET_DIR"
/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$ICON_WORK_DIR/AppIcon.icns"
cp "$ICON_WORK_DIR/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"

SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    # A plain ad-hoc signature synthesizes a cdhash-only designated requirement,
    # so TCC sees each rebuild as a new camera client. Keep a stable explicit
    # requirement for this local build so one camera approval survives rebuilds.
    /usr/bin/codesign \
        --force \
        --deep \
        --sign - \
        --identifier "$BUNDLE_IDENTIFIER" \
        --requirements "=designated => identifier \"$BUNDLE_IDENTIFIER\"" \
        "$APP_DIR"
else
    # A real Developer ID or Apple Development identity already gives the app a
    # stable certificate-based designated requirement.
    /usr/bin/codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$APP_DIR"
fi

echo "Packaged: $APP_DIR"
