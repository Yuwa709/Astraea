#!/bin/bash
# Build Astraea and install it to /Applications, replacing any running copy.
#
# Why this exists: macOS refuses to launch a second instance of the same bundle
# identifier, so launching a freshly built copy while an old one is running
# silently re-activates the OLD process. That cost an entire debugging round —
# the stale process still held a denied Automation permission and never
# retried, so no prompt ever appeared.
#
# Running from /Applications also gives TCC a stable identity; a bundle inside
# DerivedData is rebuilt constantly and is a poor thing to hang permissions on.
#
# Usage: scripts/install.sh [--reset-automation]
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--reset-automation" ]]; then
    echo "==> Resetting Automation permission for com.techie.Astraea"
    tccutil reset AppleEvents com.techie.Astraea || true
fi

echo "==> Building"
xcodebuild -scheme Astraea -configuration Debug -destination 'platform=macOS' build \
    | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

BUILT=$(ls -d ~/Library/Developer/Xcode/DerivedData/Astraea-*/Build/Products/Debug/Astraea.app 2>/dev/null | head -1)
if [[ -z "$BUILT" ]]; then
    echo "!! No built app found"; exit 1
fi

echo "==> Quitting every running copy"
pkill -x Astraea 2>/dev/null || true
sleep 1

echo "==> Installing to /Applications"
rm -rf /Applications/Astraea.app
# ditto, not cp: it preserves extended attributes and code signatures.
ditto "$BUILT" /Applications/Astraea.app

codesign --verify --strict /Applications/Astraea.app && echo "==> Signature valid"

echo
echo "Installed. Launch it YOURSELF so permission prompts are attributed to a"
echo "user-initiated launch:  open /Applications/Astraea.app"
echo "(or Spotlight: Cmd-Space, \"Astraea\")"
