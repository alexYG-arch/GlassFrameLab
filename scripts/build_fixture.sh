#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir="$(mktemp -d /private/tmp/glassframe-fixture.XXXXXX)/GlassFrameFixture.app"
mkdir -p "$fixture_dir/Contents/MacOS"
xcrun swiftc -O -target arm64-apple-macos13.0 -module-cache-path "$PWD/.build/clang-cache" Tests/Fixtures/BackgroundFixture.swift -o "$fixture_dir/Contents/MacOS/GlassFrameFixture"
python3 - "$fixture_dir/Contents/Info.plist" <<'PY'
import plistlib,sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.uidev.GlassFrameFixture','CFBundleExecutable':'GlassFrameFixture','CFBundleName':'GlassFrame Background Test','CFBundlePackageType':'APPL','LSMinimumSystemVersion':'13.0','NSHighResolutionCapable':True}))
PY
codesign --force --sign - "$fixture_dir"
ln -sfn "$fixture_dir" .build/GlassFrameFixture.app
