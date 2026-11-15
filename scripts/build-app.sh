#!/bin/bash
# Builds build/LimitBar.app (ad-hoc signed, Hardened Runtime). Pass --install to copy it to
# ~/Applications and open it.
set -euo pipefail
# Use only system tools, whatever the caller's PATH contains (swift is reached through xcrun).
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/LimitBar.app"

cd "$ROOT"
xcrun swift build -c release
BIN="$(xcrun swift build -c release --show-bin-path)/LimitBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LimitBar"

# App icon: build an .icns from Resources/AppIcon.png (regenerate it with scripts/make-icon.swift).
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for px in 16 32 128 256 512; do
    sips -z "$px" "$px" "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
    sips -z $((px * 2)) $((px * 2)) "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.coderai.limitbar</string>
    <key>CFBundleName</key><string>LimitBar</string>
    <key>CFBundleExecutable</key><string>LimitBar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
codesign --force --options runtime --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications/LimitBar.app"
    pkill -x LimitBar || true
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "Installed $DEST"
fi
