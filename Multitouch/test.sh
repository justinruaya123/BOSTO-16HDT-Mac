#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/../build/multitouch-tests"
/bin/mkdir -p "$OUT"
/usr/bin/xcrun clang -std=c11 -g -Wall -Wextra -Werror -fsanitize=undefined,bounds -fno-omit-frame-pointer -I"$DIR" "$DIR/BT16Touch.c" "$DIR/tests/test_touch.c" -o "$OUT/test_touch"
"$OUT/test_touch"
/usr/bin/xcrun clang -std=c11 -g -Wall -Wextra -Werror -fsanitize=undefined,bounds -fno-omit-frame-pointer -I"$DIR" "$DIR/BT16Touch.c" "$DIR/BTGestures.c" "$DIR/tests/test_gestures.c" -o "$OUT/test_gestures"
"$OUT/test_gestures"
/usr/bin/xcrun clang -std=c11 -g -fsanitize=undefined,bounds -I"$DIR" -c "$DIR/BTGestures.c" -o "$OUT/gestures.o"
if [ -f "$DIR/tests/test_events.m" ]; then
  /usr/bin/xcrun clang -std=c11 -g -fsanitize=undefined,bounds -I"$DIR" -c "$DIR/BT16Touch.c" -o "$OUT/core.o"
  /usr/bin/xcrun clang -fobjc-arc -g -Wall -Wextra -Werror -fsanitize=undefined,bounds -I"$DIR" "$DIR/BT16TouchEvents.m" "$DIR/tests/test_events.m" "$OUT/core.o" -framework Cocoa -framework ApplicationServices -o "$OUT/test_events"
  "$OUT/test_events" "$DIR/fixtures/real-touch-capture.json"
fi
/usr/bin/xcrun clang -fobjc-arc -g -Wall -Wextra -Werror -fsanitize=undefined,bounds -I"$DIR" "$DIR/BT16TouchEvents.m" "$DIR/BTGestureEvents.m" "$DIR/tests/test_gesture_events.m" -framework Cocoa -framework ApplicationServices -o "$OUT/test_gesture_events"
"$OUT/test_gesture_events"
/usr/bin/xcrun clang -fobjc-arc -fblocks -g -Wall -Wextra -Werror -fsanitize=undefined,bounds -I"$DIR" "$DIR/tests/test_pen_monitor.m" -framework Cocoa -framework IOKit -framework ApplicationServices -o "$OUT/test_pen_monitor"
"$OUT/test_pen_monitor"
/usr/bin/xcrun clang -fobjc-arc -fblocks -g -Wall -Wextra -Werror -fsanitize=undefined,bounds -I"$DIR" "$DIR/BT16TouchEvents.m" "$DIR/BTGestureEvents.m" "$DIR/tests/test_lifecycle.m" "$OUT/core.o" "$OUT/gestures.o" -framework Cocoa -framework IOKit -framework ApplicationServices -o "$OUT/test_lifecycle"
"$OUT/test_lifecycle"
/usr/bin/xcrun clang -fobjc-arc -fblocks -g -Wall -Wextra -Werror -fsanitize=undefined,bounds -I"$DIR" "$DIR/BT16TouchEvents.m" "$DIR/BTGestureEvents.m" "$DIR/tests/test_cli_signal.m" "$OUT/core.o" "$OUT/gestures.o" -framework Cocoa -framework IOKit -framework ApplicationServices -o "$OUT/test_cli_signal"
"$OUT/test_cli_signal" INT
"$OUT/test_cli_signal" TERM
if [ "${BT_LIVE_TESTS:-0}" = 1 ]; then
  /usr/bin/xcrun clang -fobjc-arc -fblocks -g -Wall -Wextra -Werror -fsanitize=undefined,bounds -I"$DIR" "$DIR/BTTouchController.m" "$DIR/BTPenMonitor.m" "$DIR/BT16TouchEvents.m" "$DIR/BTGestureEvents.m" "$DIR/tests/test_controller.m" "$OUT/core.o" "$OUT/gestures.o" -framework Cocoa -framework IOKit -framework ApplicationServices -o "$OUT/test_controller"
  "$OUT/test_controller"
fi
