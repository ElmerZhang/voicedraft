#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
python3 scripts/check-localizations.py
swift build -c release --disable-sandbox
BIN_DIR="$(swift build -c release --show-bin-path --disable-sandbox)"
APP="$PWD/dist/VoiceDraft.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VoiceDraft" "$APP/Contents/MacOS/VoiceDraft"
rm -rf "$APP/Contents/Resources/VoiceDraft_VoiceDraftCore.bundle"
cp -R "$BIN_DIR/VoiceDraft_VoiceDraftCore.bundle" "$APP/Contents/Resources/"
for language in en zh-Hans zh-Hant ja ko de fr es; do
    mkdir -p "$APP/Contents/Resources/$language.lproj"
    cp "Sources/VoiceDraftCore/Resources/$language.lproj/InfoPlist.strings" "$APP/Contents/Resources/$language.lproj/"
done
swift scripts/make-icon.swift "$PWD/.build/VoiceDraft.iconset" "$APP/Contents/Resources/VoiceDraft.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>VoiceDraft</string>
<key>CFBundleIdentifier</key><string>com.voicedraft.mac</string>
<key>CFBundleName</key><string>VoiceDraft</string>
<key>CFBundleDisplayName</key><string>VoiceDraft</string>
<key>CFBundleIconFile</key><string>VoiceDraft</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string><string>zh-Hant</string><string>ja</string><string>ko</string><string>de</string><string>fr</string><string>es</string></array>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>VoiceDraft records when you start dictation and sends the recording to your configured speech recognition provider.</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VOICEDRAFT_VERSION:-0.2.2}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VOICEDRAFT_BUILD:-4}" "$APP/Contents/Info.plist"
codesign --force --sign "${VOICEDRAFT_CODESIGN_IDENTITY:--}" "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"
printf 'Built %s\n' "$APP"
