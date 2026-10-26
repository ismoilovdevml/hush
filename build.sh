#!/bin/bash
# Builds Hush.app and the `hush` CLI as universal binaries (arm64 + x86_64).
# Usage: ./build.sh [install]
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Hush.app"
ADAPTER="vendor/mediaremote-adapter"
FRAMEWORK="build/MediaRemoteAdapter.framework"
ARCHS=(arm64 x86_64)
MIN_MACOS=13.0

# SwiftUI's @State/@Binding/@Environment are compiler-plugin macros shipped as
# libSwiftUIMacros.dylib inside the *platform*, not the toolchain. xcodebuild adds this
# search path automatically; a raw `swiftc` invocation does not on some Xcode releases
# (e.g. 27.0.1), so @State fails with "plugin for module 'SwiftUIMacros' not found".
# Pass both the platform and toolchain plugin dirs explicitly so the build never depends
# on the compiler's default plugin search.
PLUGIN_DIRS=(
    "$(xcrun --show-sdk-platform-path)/Developer/usr/lib/swift/host/plugins"
    "$(dirname "$(xcrun --find swiftc)")/../lib/swift/host/plugins"
)
PLUGIN_FLAGS=()
for d in "${PLUGIN_DIRS[@]}"; do [ -d "$d" ] && PLUGIN_FLAGS+=(-plugin-path "$d"); done

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$FRAMEWORK/Resources" build/arch

# --- 1. MediaRemoteAdapter.framework --------------------------------------
# Loaded inside /usr/bin/perl, which is Apple-signed and entitled to use MediaRemote.
# Since macOS 15.4 an unentitled app gets nothing from that framework directly.
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
    -arch arm64 -arch x86_64 -mmacosx-version-min="$MIN_MACOS" \
    -I"$ADAPTER/src" -I"$ADAPTER/include" \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    "$ADAPTER"/src/adapter/*.m "$ADAPTER"/src/private/*.m "$ADAPTER"/src/utility/*.m \
    -install_name @rpath/MediaRemoteAdapter.framework/MediaRemoteAdapter \
    -o "$FRAMEWORK/MediaRemoteAdapter"

# --- 2. the app and the CLI, one slice at a time then lipo'd together ------
# swiftc emits a single architecture per invocation, so each target is built twice.
swift_build() {          # swift_build <output> <source dir...>
    local out="$1"; shift
    local slices=()
    for arch in "${ARCHS[@]}"; do
        swiftc -O -target "${arch}-apple-macos${MIN_MACOS}" \
            "${PLUGIN_FLAGS[@]}" \
            -framework AppKit -framework SwiftUI -framework IOBluetooth -framework CoreAudio \
            "$@" -o "build/arch/$(basename "$out").$arch"
        slices+=("build/arch/$(basename "$out").$arch")
    done
    lipo -create "${slices[@]}" -output "$out"
}

swift_build "$APP/Contents/MacOS/Hush" Sources/Core/*.swift Sources/App/*.swift
swift_build "build/hush" Sources/Core/*.swift Sources/CLI/*.swift

cp Info.plist "$APP/Contents/Info.plist"
cp "$ADAPTER/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/"
cp -R "$FRAMEWORK" "$APP/Contents/Resources/"
# NOT Contents/MacOS/hush: the filesystem is case-insensitive, so that path is the same
# file as Contents/MacOS/Hush and the CLI would overwrite the app binary.
cp build/hush "$APP/Contents/Resources/hush"

codesign --force --deep --sign - "$APP"
codesign --force --sign - build/hush
rm -rf build/arch
echo "built: $(pwd)/$APP"
echo "built: $(pwd)/build/hush"

if [ "${1:-}" = "install" ]; then
    # Same destination rule as install.sh, so a source build and a released build never
    # end up as two copies fighting over the menu bar.
    if [ -w /Applications ]; then dest="/Applications"; else dest="$HOME/Applications"; fi
    pkill -x Hush 2>/dev/null || true
    rm -rf "$dest/Hush.app" "$HOME/Applications/Hush.app"
    mkdir -p "$dest"
    cp -R "$APP" "$dest/Hush.app"
    echo "installed: $dest/Hush.app"
    cli="$dest/Hush.app/Contents/Resources/hush"
    if ln -sf "$cli" /usr/local/bin/hush 2>/dev/null; then
        echo "linked:    /usr/local/bin/hush"
    else
        mkdir -p "$HOME/.local/bin"
        ln -sf "$cli" "$HOME/.local/bin/hush"
        echo "linked:    $HOME/.local/bin/hush  (add it to PATH, or run:"
        echo "           sudo ln -sf '$cli' /usr/local/bin/hush )"
    fi
fi
