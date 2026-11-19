#!/bin/bash
# Build MeetingAgent.app with SwiftPM (no Xcode needed) and install it to ~/Applications.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
UV="$(command -v uv || echo /opt/homebrew/bin/uv)"
APP="$HOME/Applications/MeetingAgent.app"

cd "$HERE"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/MeetingAgent"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/MeetingAgent"
mkdir -p "$APP/Contents/Resources"
cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.krittanon.meetingagent</string>
  <key>CFBundleName</key><string>MeetingAgent</string>
  <key>CFBundleDisplayName</key><string>Meeting Agent</string>
  <key>CFBundleExecutable</key><string>MeetingAgent</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Meeting Agent อัดเสียงไมค์ของพี่เพื่อถอดเสียงการประชุม</string>
  <key>MeetingAgentRepo</key><string>$REPO</string>
  <key>MeetingAgentUV</key><string>$UV</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS keeps the microphone permission attached to this bundle.
codesign --force --sign - "$APP"
echo "Installed $APP"
echo "Open it:  open '$APP'"
