#!/bin/sh
# Builds WhisperSpike.app next to this script. Needs a real bundle so macOS asks for mic/camera.
set -e
cd "$(dirname "$0")"
APP=WhisperSpike.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -swift-version 5 -O Spike.swift -o "$APP/Contents/MacOS/WhisperSpike"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.ainkrad.whisper-spike</string>
  <key>CFBundleName</key><string>WhisperSpike</string>
  <key>CFBundleExecutable</key><string>WhisperSpike</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>Calls in Teams, Slack and WhatsApp.</string>
  <key>NSMicrophoneUsageDescription</key><string>Calls in Teams, Slack and WhatsApp.</string>
</dict></plist>
PLIST
codesign --force -s - "$APP"
echo "built $(pwd)/$APP"
