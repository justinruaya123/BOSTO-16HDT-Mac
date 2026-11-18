#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/../build/multitouch"
APP="$OUT/Bosto Multitouch.app"
# Integration files must exist; never fall back to building the old helper here.
for file in BTGestureEvents.m BTPenMonitor.m; do
  if [ ! -f "$DIR/$file" ]; then printf 'Multitouch integration incomplete: %s missing\n' "$file" >&2; exit 2; fi
done
/bin/mkdir -p "$APP/Contents/MacOS"
/usr/bin/xcrun clang -arch arm64 -mmacosx-version-min=11.0 -std=c11 -O2 -Wall -Wextra -Werror -I"$DIR" -c "$DIR/BT16Touch.c" -o "$OUT/core.o"
/usr/bin/xcrun clang -arch arm64 -mmacosx-version-min=11.0 -std=c11 -O2 -Wall -Wextra -Werror -I"$DIR" -c "$DIR/BTGestures.c" -o "$OUT/gestures.o"
/usr/bin/xcrun clang -arch arm64 -mmacosx-version-min=11.0 -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror -I"$DIR" "$DIR/main.m" "$DIR/BTTouchController.m" "$DIR/BT16TouchEvents.m" "$DIR/BTGestureEvents.m" "$DIR/BTPenMonitor.m" "$OUT/core.o" "$OUT/gestures.o" -framework Cocoa -framework IOKit -framework ApplicationServices -o "$APP/Contents/MacOS/BostoMultitouch"
/bin/cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - --identifier local.BostoMultitouch "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"
