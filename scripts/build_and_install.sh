#!/bin/bash
# Build voice-doodle and install the .app to ~/Library/Applications.
# Usage:
#   ./scripts/build_and_install.sh            # Debug build (default, fast)
#   ./scripts/build_and_install.sh --release  # Release build
set -euo pipefail

# Project root = parent of scripts/
cd "$(dirname "$0")/.."

CONFIG="Debug"
if [[ "${1:-}" == "--release" ]]; then
  CONFIG="Release"
fi

APP_NAME="voice-doodle"
INSTALL_DIR="$HOME/Library/Applications"
INSTALL_PATH="$INSTALL_DIR/$APP_NAME.app"
DERIVED="$PWD/build"

echo "==> Building ($CONFIG)…"
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  build | tail -3

BUILT_APP="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "error: build product not found: $BUILT_APP" >&2
  exit 1
fi

# Gracefully quit any running old instance (ignored if none)
osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
sleep 1

echo "==> Installing to $INSTALL_PATH"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_PATH"
cp -R "$BUILT_APP" "$INSTALL_DIR/"

# Stamp the installed copy with the version (commit + build config), shown under the menu-bar settings entry
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
PLIST="$INSTALL_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :VDBuildCommit $COMMIT" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :VDBuildCommit string $COMMIT" "$PLIST"

# The modified bundle must be re-signed with the same developer identity Xcode
# uses — an ad-hoc re-sign changes the designated requirement, which invalidates
# granted Accessibility permissions and disables the app.
IDENTITY="${VD_SIGN_IDENTITY:-F8D922DC70EF6D4846F5AE0C867379190C162753}"
# Sign with the local entitlements (disable-library-validation for the
# bundled ten_vad.bin; no sandbox — see voice-doodle.entitlements).
codesign --force --sign "$IDENTITY" \
  --entitlements "$PWD/$APP_NAME/$APP_NAME.entitlements" \
  "$INSTALL_PATH"
codesign -dv "$INSTALL_PATH" 2>&1 | grep -E 'Authority|Identifier' | head -2

echo "==> Done ($CONFIG @ $COMMIT). Launch with: open \"$INSTALL_PATH\""
echo "    （辅助功能授权绑定路径；覆盖同路径一般仍有效，失效时从系统设置移除后重新添加）"
