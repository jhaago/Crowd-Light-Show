#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

rm -rf dist
mkdir -p dist

swift build -c release --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release/CrowdLightBridge"
if [ ! -f "$BIN" ]; then
  BIN=".build/release/CrowdLightBridge"
fi

if [ ! -f "$BIN" ]; then
  echo "Could not locate built CrowdLightBridge executable."
  find .build -name CrowdLightBridge -type f -print || true
  exit 1
fi

APP="dist/CrowdLight Bridge.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/CrowdLightBridge"
chmod +x "$APP/Contents/MacOS/CrowdLightBridge"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>CrowdLightBridge</string>
    <key>CFBundleIdentifier</key>
    <string>com.crowdlight.bridge</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>CrowdLight Bridge</string>
    <key>CFBundleDisplayName</key>
    <string>CrowdLight Bridge</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist"

ARCHS="$(lipo -archs "$APP/Contents/MacOS/CrowdLightBridge")"
echo "Built architectures: $ARCHS"
if [[ "$ARCHS" != *"arm64"* || "$ARCHS" != *"x86_64"* ]]; then
  echo "Expected a universal arm64 + x86_64 binary."
  exit 1
fi

codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/CrowdLight-Bridge-macOS.zip"
unzip -t "dist/CrowdLight-Bridge-macOS.zip"

echo "Created and verified $ROOT/dist/CrowdLight-Bridge-macOS.zip"
