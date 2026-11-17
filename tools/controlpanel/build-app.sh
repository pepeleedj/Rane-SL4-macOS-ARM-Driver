#!/bin/bash
# build-app.sh [output-dir] — build "SL 4 Control Panel.app" (universal: arm64 + x86_64, macOS 13+)
# into output-dir (default: the repository root), ad-hoc signed. Run by `make controlpanel`.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${1:-$ROOT}
VERSION=$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || echo "1.4.0")
APP="$OUT/SL 4 Control Panel.app"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Compile each architecture, then join them.
for arch in arm64 x86_64; do
    swiftc -O -parse-as-library -target "$arch-apple-macos13.0" \
        -import-objc-header "$HERE/../../plugin/SL4Status.h" \
        "$HERE/SL4ControlPanel.swift" -o "$TMP/SL4ControlPanel-$arch"
done

# Draw the icon (make-icon.swift) and pack it into an .icns.
swiftc -O "$HERE/make-icon.swift" -o "$TMP/make-icon"
"$TMP/make-icon" "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$TMP/AppIcon.icns"

# Lay out the bundle and sign it.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$TMP/SL4ControlPanel-arm64" "$TMP/SL4ControlPanel-x86_64" -output "$APP/Contents/MacOS/SL4ControlPanel"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
cp "$TMP/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "built $APP"
