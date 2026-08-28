#!/bin/bash
# Builds OwlCap.app. Needs the Swift toolchain (Xcode or the Command Line Tools).
#
#   ./build.sh              build into ./build/OwlCap.app
#   ./build.sh --install    also copy it into /Applications
#   ./build.sh --zip        also produce build/OwlCap-<version>.zip
set -euo pipefail

cd "$(dirname "$0")"
VERSION="$(cat VERSION)"
APP="build/OwlCap.app"
INSTALL=false
ZIP=false
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    --zip) ZIP=true ;;
    *) echo "unknown option: $arg"; exit 1 ;;
  esac
done

echo "==> Building OwlCap $VERSION"
# Universal binaries need full Xcode; the Command Line Tools can only build for this Mac.
ARCH_FLAGS=(--arch arm64 --arch x86_64)
if swift build -c release "${ARCH_FLAGS[@]}" >/dev/null 2>&1; then
  echo "    built universal (arm64 + x86_64)"
else
  echo "    building for this Mac's architecture only (install Xcode for a universal build)"
  ARCH_FLAGS=()
  swift build -c release
fi
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/OwlCap"

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OwlCap"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"

if [ ! -f Resources/AppIcon.icns ]; then
  echo "==> Rendering icon"
  rm -rf build/AppIcon.iconset
  mkdir -p build
  swift Tools/makeicon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

if [ "$ZIP" = true ]; then
  echo "==> Zipping"
  (cd build && rm -f "OwlCap-$VERSION.zip" && ditto -c -k --keepParent OwlCap.app "OwlCap-$VERSION.zip")
fi

if [ "$INSTALL" = true ]; then
  echo "==> Installing to /Applications"
  rm -rf /Applications/OwlCap.app
  cp -R "$APP" /Applications/OwlCap.app
  echo "    installed: /Applications/OwlCap.app"
fi

echo "==> Done: $APP"
