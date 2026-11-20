#!/usr/bin/env bash
# Build, package, ad-hoc sign, and reveal the cue9 macOS app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/app"
OUT="$APP/build/cue9.app"
SCRATCH="${CUE9_SWIFT_SCRATCH:-/tmp/cue9-app-build}"
CACHE="${CUE9_SWIFT_CACHE:-/tmp/cue9-swift-cache}"
SDK_CACHE="$CACHE/sdk"
mkdir -p "$SCRATCH" "$CACHE" "$SDK_CACHE" "$APP/build"

export CLANG_MODULE_CACHE_PATH="$CACHE/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$CACHE/swiftpm"
swift build --package-path "$APP" -c release --disable-sandbox \
  --scratch-path "$SCRATCH" --cache-path "$CACHE" --config-path "$CACHE/config" \
  --security-path "$CACHE/security"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$SCRATCH/out/Products/release/cue9" "$OUT/Contents/MacOS/cue9"
cp -R "$SCRATCH/out/Products/release/cue9_Cue9App.bundle" "$OUT/Contents/Resources/"
cp "$ROOT/brand/decided/final/cue9-lockup-white.svg" "$OUT/Contents/Resources/cue9-lockup-white.svg"
cp "$ROOT/brand/decided/final/cue9-lockup.svg" "$OUT/Contents/Resources/cue9-lockup.svg"
cp "$APP/Sources/Cue9App/Resources/InterVariable.ttf" "$OUT/Contents/Resources/InterVariable.ttf"
cp "$APP/Sources/Cue9App/Resources/Inter-OFL.txt" "$OUT/Contents/Resources/Inter-OFL.txt"
cp -R "$ROOT/pi" "$OUT/Contents/Resources/cue9-pi"

cat > "$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>cue9</string>
  <key>CFBundleDisplayName</key><string>cue9</string>
  <key>CFBundleIdentifier</key><string>com.cue9.app</string>
  <key>CFBundleExecutable</key><string>cue9</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
    <key>NSAllowsArbitraryLoads</key><true/>
  </dict>
</dict>
</plist>
PLIST

ICON_TMP="$SCRATCH/icon"
rm -rf "$ICON_TMP"
mkdir -p "$ICON_TMP"
swiftc "$APP/Scripts/render-icon.swift" -o "$SCRATCH/render-icon" \
  -module-cache-path "$CACHE/clang" -sdk "$(xcrun --sdk macosx --show-sdk-path)"
"$SCRATCH/render-icon" "$ROOT/brand/decided/final/cue9-icon.svg" "$ICON_TMP/cue9-icon.png"
"$SCRATCH/render-icon" "$ROOT/brand/decided/final/cue9-favicon.svg" "$ICON_TMP/cue9-favicon.png"
ICONSET="$ICON_TMP/cue9.iconset"
mkdir -p "$ICONSET"
render_icon() {
  local size="$1" out="$2" source="$ICON_TMP/cue9-icon.png"
  if [[ "$size" -le 32 ]]; then source="$ICON_TMP/cue9-favicon.png"; fi
  sips -z "$size" "$size" "$source" --out "$out" >/dev/null
}
for s in 16 32 64 128 256 512 1024; do
  render_icon "$s" "$ICONSET/icon_${s}x${s}.png"
  if [[ "$s" -le 512 ]]; then
    render_icon "$((s*2))" "$ICONSET/icon_${s}x${s}@2x.png"
  fi
done
iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/cue9.icns"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string cue9.icns' "$OUT/Contents/Info.plist"

codesign --force --deep --sign - "$OUT" >/dev/null
echo "built $OUT"
