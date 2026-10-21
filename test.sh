#!/bin/bash
# Runs the protocol tests. No headphones needed.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -O -framework AppKit -framework IOBluetooth -framework CoreAudio \
    Sources/Core/*.swift Tests/*.swift -o build/hush-tests
exec build/hush-tests
