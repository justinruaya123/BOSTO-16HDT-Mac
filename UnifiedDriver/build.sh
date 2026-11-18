#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(python3 UnifiedDriver/version.py ${BT_VERSION+--override "$BT_VERSION"})
BUILD_VERSION=$(python3 UnifiedDriver/version.py --build)
OUT="$PWD/build/unified"
APP="$OUT/BostoTablet.app"
mkdir -p "$APP/Contents/MacOS" "$OUT/objects" "$OUT/scratch"
export TMPDIR="$OUT/scratch"
CFLAGS=(-DBT_UNIFIED_DRIVER=1 -arch arm64 -mmacosx-version-min=11.0 -O2 -Wall -Wextra -Werror -IMultitouch -IUnifiedDriver)
xcrun clang "${CFLAGS[@]}" -std=c11 -c Multitouch/BT16Touch.c -o "$OUT/objects/touch.o"
xcrun clang "${CFLAGS[@]}" -std=c11 -c Multitouch/BTGestures.c -o "$OUT/objects/gestures.o"
xcrun clang "${CFLAGS[@]}" -fobjc-arc -fblocks UnifiedDriver/main.m UnifiedDriver/SetupState.m UnifiedDriver/UpdatePolicy.m UnifiedDriver/UpdateController.m UnifiedDriver/ShortcutEditor.m UnifiedDriver/UnifiedPen.m UnifiedDriver/UnifiedMonitor.m Multitouch/BTTouchController.m Multitouch/BT16TouchEvents.m Multitouch/BTGestureEvents.m "$OUT/objects/touch.o" "$OUT/objects/gestures.o" -framework Cocoa -framework IOKit -framework ApplicationServices -framework ServiceManagement -o "$APP/Contents/MacOS/BostoTablet"
cp UnifiedDriver/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$APP/Contents/Info.plist"
codesign --force --sign - --identifier local.BostoTablet "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/BostoTablet" --self-check
mkdir -p "$OUT/payload"
rm -rf "$OUT/payload/BostoTablet.app"
cp -R "$APP" "$OUT/payload/BostoTablet.app"
pkgbuild --root "$OUT/payload" --component-plist UnifiedDriver/components.plist --identifier local.BostoTablet.pkg --version "$VERSION" --install-location /Applications "$OUT/BostoTablet.pkg"
printf '%s\n' "$APP" "$OUT/BostoTablet.pkg"
