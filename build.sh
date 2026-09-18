#!/bin/bash
# Build OpenDeck and assemble a runnable .app bundle.
#
# Uses swiftc directly rather than SwiftPM: this machine only has Command Line
# Tools, where (a) @State is unusable (no SwiftUI macro plugin) and (b) the
# SwiftPM manifest dylib is missing symbols.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/OpenDeck.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

OPT_FLAGS=(-O)
[ "$CONFIG" = "debug" ] && OPT_FLAGS=(-Onone -g)

echo "==> compiling (${CONFIG})"
mkdir -p build
swiftc \
  -sdk "$SDK" \
  -target arm64-apple-macosx15.0 \
  -swift-version 5 \
  "${OPT_FLAGS[@]}" \
  $(find Sources -name '*.swift' | sort) \
  -o build/OpenDeck

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp build/OpenDeck "$APP/Contents/MacOS/OpenDeck"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature so macOS lets the app request TCC permissions.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "   (codesign skipped)"

echo "==> built $APP"
