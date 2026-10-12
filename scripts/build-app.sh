#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift build -c release --disable-sandbox
BIN_DIR="$(swift build -c release --show-bin-path --disable-sandbox)"
APP="$PWD/dist/VoiceDraft.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VoiceDraft" "$APP/Contents/MacOS/VoiceDraft"
swift scripts/make-icon.swift "$PWD/.build/VoiceDraft.iconset"
iconutil -c icns "$PWD/.build/VoiceDraft.iconset" -o "$APP/Contents/Resources/VoiceDraft.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>VoiceDraft</string>
<key>CFBundleIdentifier</key><string>com.voicedraft.mac</string>
<key>CFBundleName</key><string>VoiceDraft</string>
<key>CFBundleDisplayName</key><string>VoiceDraft</string>
<key>CFBundleIconFile</key><string>VoiceDraft</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>VoiceDraft records when you start dictation and sends the recording to your configured Alibaba Cloud speech model.</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
