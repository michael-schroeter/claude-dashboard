#!/bin/sh
# Builds the menu bar app – needs only the Swift compiler that comes with Xcode.
#
# Usage:   sh menubar/build.sh
# Output:  dist/Claude Dashboard.app and dist/Claude-Dashboard-menubar-<version>.zip
#
# Install: copy the app to ~/Applications (or /Applications) and open it.
# Remove:  quit it (gear menu), switch off "Start at login" first if you used it,
#          then delete the app.

set -eu
cd "$(dirname "$0")"

VERSION=$(plutil -extract version raw ../package.json)
APP="../dist/Claude Dashboard.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Universal binary: runs on Apple silicon and Intel Macs.
BIN="$APP/Contents/MacOS/ClaudeDashboard"
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library \
    -target "$ARCH-apple-macos13.0" \
    Sources/*.swift \
    -o "$BIN-$ARCH"
done
lipo -create "$BIN-arm64" "$BIN-x86_64" -output "$BIN"
rm "$BIN-arm64" "$BIN-x86_64"

# App icon: the app draws it itself, iconutil (part of macOS) packs it.
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET" "$APP/Contents/Resources"
for SIZE in 16 32 128 256 512; do
  "$BIN" --write-icon "$ICONSET/icon_${SIZE}x${SIZE}.png" "$SIZE"
  "$BIN" --write-icon "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" "$((SIZE * 2))"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Dashboard</string>
  <key>CFBundleDisplayName</key><string>Claude Dashboard</string>
  <key>CFBundleIdentifier</key><string>local.claude-dashboard.menubar</string>
  <key>CFBundleExecutable</key><string>ClaudeDashboard</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Ad-hoc signature: enough to run on this Mac, no developer account needed.
codesign --force --sign - "$APP"

# Zip for the release page.
ZIP="../dist/Claude-Dashboard-menubar-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Built $APP ($VERSION)"
echo "Built $ZIP"
