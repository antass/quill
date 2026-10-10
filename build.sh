#!/bin/bash
# Builds Quill.app. Run: ./build.sh          (build + install to /Applications)
#                        ./build.sh --local  (leave the .app next to this script)
set -euo pipefail

cd "$(dirname "$0")"
PROJECT_DIR="$(pwd)"
APP_NAME="Quill"
BUNDLE_ID="com.ania.quill"
VERSION="1.0"

# iCloud Drive is a poor build directory, so keep intermediates on the local disk.
SCRATCH="${TMPDIR:-/tmp}/quill-build"
STAGE="${TMPDIR:-/tmp}/quill-stage"

echo "==> Compiling (this takes ~30s the first time)"
swift build -c release --scratch-path "$SCRATCH"
BINARY="$SCRATCH/release/$APP_NAME"

echo "==> Assembling $APP_NAME.app"
rm -rf "$STAGE"
APP="$STAGE/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"

echo "==> Rendering icon"
ICONSET="$STAGE/$APP_NAME.iconset"
swift Tools/makeicon.swift "$ICONSET" > /dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/$APP_NAME.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Built locally.</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc, for Keychain + network access)"
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null

if [ "${1:-}" = "--local" ]; then
    rm -rf "$PROJECT_DIR/$APP_NAME.app"
    cp -R "$APP" "$PROJECT_DIR/"
    echo "==> Done: $PROJECT_DIR/$APP_NAME.app"
else
    DEST="/Applications/$APP_NAME.app"
    if [ -d "$DEST" ]; then
        osascript -e 'tell application "Quill" to quit' 2>/dev/null || true
        sleep 1
        rm -rf "$DEST"
    fi
    cp -R "$APP" /Applications/
    echo "==> Installed: $DEST"
    echo "    Launch it with:  open -a Quill"
fi
