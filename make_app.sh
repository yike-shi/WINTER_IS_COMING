#!/bin/zsh
# Package WinterIsComing into a double-clickable Mac app + a zip ready for GitHub Releases.
# Usage: zsh make_app.sh [version]        e.g.  zsh make_app.sh 1.0
set -e
cd "$(dirname "$0")"

VERSION="${1:-1.0}"
APP="dist/WinterIsComing.app"
ZIP="dist/WinterIsComing-mac-v${VERSION}.zip"

echo "❄︎ Building WinterIsComing ${VERSION}…"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist/tmp

# 1. Binary: universal (arm64 + x86_64) if both targets succeed, otherwise native host architecture
HAVE_ARM64=0
if swiftc -O -target arm64-apple-macos12 WinterIsComing.swift -o dist/tmp/WinterIsComing-arm64 2>/dev/null; then
  HAVE_ARM64=1
fi

HAVE_X86_64=0
if swiftc -O -target x86_64-apple-macos12 WinterIsComing.swift -o dist/tmp/WinterIsComing-x86_64 2>/dev/null; then
  HAVE_X86_64=1
fi

if [[ $HAVE_ARM64 -eq 1 && $HAVE_X86_64 -eq 1 ]]; then
  echo "❄︎ Packaging universal binary (arm64 + x86_64)…"
  lipo -create dist/tmp/WinterIsComing-arm64 dist/tmp/WinterIsComing-x86_64 -output "$APP/Contents/MacOS/WinterIsComing"
elif [[ $HAVE_ARM64 -eq 1 ]]; then
  echo "❄︎ Note: x86_64 target not supported by local toolchain; bundling arm64 binary."
  cp dist/tmp/WinterIsComing-arm64 "$APP/Contents/MacOS/WinterIsComing"
elif [[ $HAVE_X86_64 -eq 1 ]]; then
  echo "❄︎ Note: arm64 target not supported by local toolchain; bundling x86_64 binary."
  cp dist/tmp/WinterIsComing-x86_64 "$APP/Contents/MacOS/WinterIsComing"
else
  echo "❄︎ Compiling native host binary…"
  swiftc -O WinterIsComing.swift -o "$APP/Contents/MacOS/WinterIsComing"
fi

# 2. App icon (from assets/icon.png)
ICONSET=dist/tmp/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) assets/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# 3. Info.plist (LSUIElement = no Dock icon, it lives in the menu bar)
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>WinterIsComing</string>
  <key>CFBundleDisplayName</key>        <string>WinterIsComing</string>
  <key>CFBundleIdentifier</key>         <string>io.github.yike-shi.winteriscoming</string>
  <key>CFBundleExecutable</key>         <string>WinterIsComing</string>
  <key>CFBundleIconFile</key>           <string>AppIcon</string>
  <key>CFBundlePackageType</key>        <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
  <key>CFBundleVersion</key>            <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>     <string>12.0</string>
  <key>LSUIElement</key>                <true/>
  <key>NSHighResolutionCapable</key>    <true/>
</dict>
</plist>
EOF

# 4. Ad-hoc signature (free; required for apps to run on Apple silicon)
codesign --force --deep --sign - "$APP"

# 5. Zip it for GitHub Releases (ditto keeps the app bundle intact)
ditto -c -k --keepParent "$APP" "$ZIP"
rm -rf dist/tmp

echo ""
echo "✅ Done!"
echo "   App: $APP   (double-click to test)"
echo "   Zip: $ZIP   (upload this to GitHub Releases)"
