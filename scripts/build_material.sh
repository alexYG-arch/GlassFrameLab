#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/clang-cache .build/swift-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift build --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" -c release
binary_dir="$(swift build --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" -c release --show-bin-path)"
runtime_dir="$(mktemp -d /private/tmp/glassframe-material-build.XXXXXX)"
app_dir="$runtime_dir/GlassFrameLab-Material.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$binary_dir/GlassFrameLab" "$app_dir/Contents/MacOS/GlassFrameLab"
python3 - Resources/Info.plist "$app_dir/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
info = plistlib.loads(Path(sys.argv[1]).read_bytes())
info.update(CFBundleIdentifier='local.uidev.GlassFrameLab.material',
            CFBundleName='GlassFrame Material', CFBundleVersion='2',
            GlassFrameMaterialBackend='system')
info.pop('NSScreenCaptureUsageDescription', None)
Path(sys.argv[2]).write_bytes(plistlib.dumps(info))
PY
# Stage outside iCloud metadata updates before signing and archiving.
codesign --force --sign - "$app_dir"
codesign --verify --strict --verbose=2 "$app_dir"
delivery_dir="${GLASS_BUILD_OUTPUT:-$PWD/build}"
mkdir -p "$delivery_dir"
ditto -c -k --keepParent "$app_dir" "$delivery_dir/GlassFrameLab-Material.zip"
python3 - "$app_dir" "$delivery_dir/GlassFrameLab-Material.app" <<'PY'
import os, plistlib, shutil, sys
from pathlib import Path
target, link = map(Path, sys.argv[1:])
if link.is_symlink():
    link.unlink()
elif link.exists():
    with (link/'Contents/Info.plist').open('rb') as file:
        assert plistlib.load(file)['CFBundleIdentifier'] == 'local.uidev.GlassFrameLab.material'
    shutil.rmtree(link)
os.symlink(target, link)
PY
printf '%s\n' "$delivery_dir/GlassFrameLab-Material.zip"
