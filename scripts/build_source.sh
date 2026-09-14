#!/bin/bash
# Development binaries only: no app bundle, signing, ZIP, or delivery replacement.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/clang-cache .build/swift-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift build --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" -c release
xcrun swiftc -O -target arm64-apple-macos13.0 -module-cache-path "$CLANG_MODULE_CACHE_PATH" Tests/Fixtures/BackgroundFixture.swift -o .build/GlassFrameFixture
