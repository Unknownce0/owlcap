#!/bin/bash
# Builds OwlCap.app. Needs the Swift toolchain (Xcode or the Command Line Tools).
#
#   ./build.sh              build into ./build/OwlCap.app
#   ./build.sh --install    also copy it into /Applications
#   ./build.sh --zip        also produce build/OwlCap-<version>.zip
#   ./build.sh --reset-permission
#                           clear the stale Screen Recording grant (see the note below)
set -euo pipefail

cd "$(dirname "$0")"
VERSION="$(cat VERSION)"
APP="build/OwlCap.app"
INSTALL=false
ZIP=false
RESET=false
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    --zip) ZIP=true ;;
    --reset-permission) RESET=true ;;
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
  WAS_RUNNING=false
  if pgrep -x OwlCap >/dev/null; then
    WAS_RUNNING=true
    osascript -e 'quit app "OwlCap"' >/dev/null 2>&1 || true
    sleep 1
    pkill -x OwlCap >/dev/null 2>&1 || true
  fi
  rm -rf /Applications/OwlCap.app
  cp -R "$APP" /Applications/OwlCap.app
  echo "    installed: /Applications/OwlCap.app"
  # An ad-hoc signature changes with every build, and macOS ties the Screen Recording
  # grant to that signature. The switch stays on in System Settings but no longer
  # matches, so the app gets asked all over again.
  if [ "$RESET" = true ]; then
    tccutil reset ScreenCapture com.unknownce.owlcap >/dev/null 2>&1 \
      && echo "    cleared the old Screen Recording grant — approve the next prompt"
  else
    echo "    note: a rebuild can invalidate the Screen Recording permission."
    echo "          If OwlCap asks again even though it is already switched on in"
    echo "          System Settings, run ./build.sh --install --reset-permission,"
    echo "          then approve the prompt once."
  fi
  if [ "$WAS_RUNNING" = true ]; then
    open -a /Applications/OwlCap.app
  fi
fi

echo "==> Done: $APP"
