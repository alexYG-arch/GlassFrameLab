#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/clang-cache .build/swift-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift build --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" -c release
binary_dir="$(swift build --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" -c release --show-bin-path)"
runtime_dir="$(mktemp -d /private/tmp/glassframe-build.XXXXXX)"
app_dir="$runtime_dir/GlassFrameLab.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$binary_dir/GlassFrameLab" "$app_dir/Contents/MacOS/GlassFrameLab"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
# Sign outside iCloud's live metadata updates. Keep a durable zip and a local launch link.
codesign --force --sign - "$app_dir"
codesign --verify --strict --verbose=2 "$app_dir"
delivery_dir="${GLASS_BUILD_OUTPUT:-$PWD/build}"
mkdir -p "$delivery_dir"
ditto -c -k --keepParent "$app_dir" "$delivery_dir/GlassFrameLab.zip"
python3 - "$app_dir" "$delivery_dir/GlassFrameLab.app" <<'PY'
import os
import plistlib
import shutil
import sys
from pathlib import Path
target, link = map(Path, sys.argv[1:])
if link.is_symlink():
    link.unlink()
elif link.exists():
    with (link/'Contents/Info.plist').open('rb') as file:
        assert plistlib.load(file)['CFBundleIdentifier']=='local.uidev.GlassFrameLab'
    shutil.rmtree(link)  # Only the previous generated app bundle, never source files.
os.symlink(target,link)
PY
printf '%s\n' "$delivery_dir/GlassFrameLab.app"
