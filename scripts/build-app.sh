#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release --product hopapp
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/.build/hopapp.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/hopapp" "$APP/Contents/MacOS/hopapp"
# Keep the bundle identifier stable across the app rename.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.switchapps</string>
  <key>CFBundleName</key><string>hopapp</string>
  <key>CFBundleDisplayName</key><string>hopapp</string>
  <key>CFBundleExecutable</key><string>hopapp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.4.0</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign "${HOPAPP_SIGN_IDENTITY:-${SWITCHAPPS_SIGN_IDENTITY:--}}" --identifier local.switchapps --timestamp=none "$APP"
codesign --verify --strict "$APP"
printf '\nBuilt %s\n' "$APP"
