#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
export GOCACHE="${GOCACHE:-$root/.build/go-cache}"
python3 scripts/check-localizations.py
python3 scripts/check-desktop-localizations.py
cd server
go vet ./...
go build ./...
go test -race ./...
go run ./cmd/integration-test -root "$root"

# iOS Simulator build and unit tests (opt in: needs Xcode with an iOS SDK and the "iPhone 17" simulator).
if [[ "${VOICEDRAFT_IOS:-0}" == "1" ]]; then
  cd "$root"
  xcodebuild -project ios/VoiceDraft.xcodeproj -scheme VoiceDraft \
    -destination "platform=iOS Simulator,name=${VOICEDRAFT_IOS_SIMULATOR:-iPhone 17}" \
    test CODE_SIGNING_ALLOWED=NO | grep -E "Executed|error:|\*\* TEST"
fi
