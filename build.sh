#!/bin/bash
# Builds Hush.app, including the bundled MediaRemote adapter framework.
# Usage: ./build.sh [install]
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Hush.app"
ADAPTER="vendor/mediaremote-adapter"
FRAMEWORK="build/MediaRemoteAdapter.framework"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$FRAMEWORK/Resources"

# --- 1. MediaRemoteAdapter.framework --------------------------------------
# Loaded inside /usr/bin/perl, which is Apple-signed and entitled to use
# MediaRemote. Since macOS 15.4 an unentitled app gets nothing from it directly.
cat > "$FRAMEWORK/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.vandenbe.MediaRemoteAdapter</string>
  <key>CFBundleName</key><string>MediaRemoteAdapter</string>
  <key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
</dict></plist>
PLIST

clang -dynamiclib -fobjc-arc -fvisibility=default \
    -arch arm64 -mmacosx-version-min=13.0 \
    -I"$ADAPTER/src" -I"$ADAPTER/include" \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    "$ADAPTER"/src/adapter/*.m "$ADAPTER"/src/private/*.m "$ADAPTER"/src/utility/*.m \
    -install_name @rpath/MediaRemoteAdapter.framework/MediaRemoteAdapter \
    -o "$FRAMEWORK/MediaRemoteAdapter"

# --- 2. the app ------------------------------------------------------------
swiftc -O -target arm64-apple-macos13.0 \
    -framework AppKit -framework SwiftUI -framework IOBluetooth -framework CoreAudio \
    Sources/*.swift -o "$APP/Contents/MacOS/Hush"

cp Info.plist "$APP/Contents/Info.plist"
cp "$ADAPTER/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/"
cp -R "$FRAMEWORK" "$APP/Contents/Resources/"

codesign --force --deep --sign - "$APP"
echo "built: $(pwd)/$APP"

if [ "${1:-}" = "install" ]; then
    pkill -x Hush 2>/dev/null || true
    rm -rf "$HOME/Applications/Hush.app"
    mkdir -p "$HOME/Applications"
    cp -R "$APP" "$HOME/Applications/Hush.app"
    echo "installed: $HOME/Applications/Hush.app"
fi
