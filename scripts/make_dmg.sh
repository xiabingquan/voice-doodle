#!/bin/bash
# Package Voice Doodle as a drag-to-Applications DMG.
# Usage:
#   ./scripts/make_dmg.sh          # dist/Voice-Doodle-<commit>.dmg
#   ./scripts/make_dmg.sh v0.0.2   # dist/Voice-Doodle-v0.0.2.dmg
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="voice-doodle"
SCHEME="voice-doodle"
APP_BUNDLE="Voice Doodle.app"
CONFIG="Release"
DERIVED="$PWD/build"
BUILT_APP="$DERIVED/Build/Products/$CONFIG/$APP_BUNDLE"
DIST_DIR="$PWD/dist"
STAGING="$DIST_DIR/.stage"
SUFFIX="${1:-$(git rev-parse --short HEAD 2>/dev/null || echo dev)}"
DMG_PATH="$DIST_DIR/Voice-Doodle-$SUFFIX.dmg"
IDENTITY="${VD_SIGN_IDENTITY:-F8D922DC70EF6D4846F5AE0C867379190C162753}"

echo "==> Building ${CONFIG}…"
xcodebuild \
  -project "$PROJECT.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  build | tail -3

if [ ! -d "$BUILT_APP" ]; then
  echo "error: build product not found: $BUILT_APP" >&2
  exit 1
fi

echo "==> Stamping app metadata…"
PLIST="$BUILT_APP/Contents/Info.plist"
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
/usr/libexec/PlistBuddy -c "Set :VDBuildCommit $COMMIT" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :VDBuildCommit string $COMMIT" "$PLIST"
# User-visible names: Xcode's generator can emit CFBundleName=PRODUCT_NAME.
/usr/libexec/PlistBuddy -c "Set :CFBundleName 'Voice Doodle'" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleName string 'Voice Doodle'" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName 'Voice Doodle'" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string 'Voice Doodle'" "$PLIST"
# Finder comment (product tagline) — stamped before packaging so the xattr
# travels inside the DMG with the app.
COMMENT_HEX=$(python3 -c "import plistlib; print(plistlib.dumps('极简语音输入法', fmt=plistlib.FMT_BINARY).hex())" 2>/dev/null || true)
if [ -n "$COMMENT_HEX" ]; then
  xattr -wx com.apple.metadata:kMDItemFinderComment "$COMMENT_HEX" "$BUILT_APP" 2>/dev/null || true
fi

echo "==> Re-signing (bundle contents changed)…"
codesign --force --sign "$IDENTITY" \
  --entitlements "$PWD/voice-doodle/voice-doodle.entitlements" \
  "$BUILT_APP"
codesign -dv "$BUILT_APP" 2>&1 | grep -E 'Authority|Identifier' | head -2

echo "==> Staging DMG contents…"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$BUILT_APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating DMG (layout pass)…"
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"
RAW_DMG="$DIST_DIR/.raw.dmg"
BG_PNG="$DIST_DIR/.dmg-background.png"

# Background art: neutral panel + drag hint.
BG_SWIFT="$DIST_DIR/.dmg-bg.swift"
cat > "$BG_SWIFT" <<'SWIFT'
import AppKit
let w: CGFloat = 620, h: CGFloat = 360
let img = NSImage(size: NSSize(width: w, height: h))
img.lockFocus()
NSColor(calibratedWhite: 0.965, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: w, height: h).fill()
let label = NSAttributedString(string: "拖入 Applications 安装", attributes: [
    .font: NSFont.systemFont(ofSize: 13, weight: .regular),
    .foregroundColor: NSColor.tertiaryLabelColor
])
label.draw(at: NSPoint(x: (w - label.size().width) / 2, y: 42))
img.unlockFocus()
let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(filePath: CommandLine.arguments[1]))
SWIFT
swift "$BG_SWIFT" "$BG_PNG" 2>/dev/null || echo "warn: background render failed, continuing without art"

# Read-write image, then Finder-layout pass (icon positions, window, background).
hdiutil create -volname "Voice Doodle安装向导" -srcfolder "$STAGING" -ov -format UDRW "$RAW_DMG" >/dev/null
# Detach any stale same-name volumes so Finder name resolution is unambiguous.
for v in /Volumes/Voice*oodle*; do hdiutil detach "$v" -force -quiet 2>/dev/null || true; done
sleep 1
ATTACH_OUT=$(hdiutil attach -readwrite -noverify -noautoopen "$RAW_DMG")
MOUNT=$(echo "$ATTACH_OUT" | tail -1 | sed 's/.*\t//')
VOLNAME=$(basename "$MOUNT")
echo "    mounted: $MOUNT (volume: $VOLNAME)"
if [ -f "$BG_PNG" ]; then
  mkdir -p "$MOUNT/.background"
  cp "$BG_PNG" "$MOUNT/.background/bg.png"
fi
sleep 2
osascript <<EOF || echo "warn: Finder layout script failed (automation permission?)"
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {80, 80, 700, 440}
    set opts to the icon view options of container window
    set icon size of opts to 96
    set arrangement of opts to not arranged
    try
      set background picture of opts to file ".background:bg.png"
    end try
    set position of item "Voice Doodle.app" to {170, 190}
    set position of item "Applications" to {450, 190}
    delay 1
    close
    open
    delay 1
    close
  end tell
end tell
EOF
sync
hdiutil detach "$MOUNT" -quiet
hdiutil convert "$RAW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -rf "$STAGING" "$RAW_DMG" "$BG_PNG" "$BG_SWIFT"
ls -lh "$DMG_PATH"

echo "==> Done. Open with: open \"$DMG_PATH\""
open "$DMG_PATH"
