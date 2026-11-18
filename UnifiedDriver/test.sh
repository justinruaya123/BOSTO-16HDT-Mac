#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/unified-tests/scratch
export TMPDIR="$PWD/build/unified-tests/scratch"
xcrun clang -arch arm64 -fobjc-arc -Wall -Wextra -Werror -g -fsanitize=undefined,bounds -IUnifiedDriver UnifiedDriver/UnifiedPen.m UnifiedDriver/tests/test_pen.m -framework Cocoa -framework ApplicationServices -o build/unified-tests/test_pen
build/unified-tests/test_pen
xcrun clang -arch arm64 -std=c11 -Wall -Wextra -Werror -g -fsanitize=undefined,bounds -IMultitouch -c Multitouch/BTGestures.c -o build/unified-tests/gestures.o
xcrun clang -arch arm64 -std=c11 -Wall -Wextra -Werror -g -fsanitize=undefined,bounds -IMultitouch -c Multitouch/BT16Touch.c -o build/unified-tests/touch.o
xcrun clang -arch arm64 -fobjc-arc -fblocks -Wall -Wextra -Werror -g -fsanitize=undefined,bounds -IUnifiedDriver -IMultitouch UnifiedDriver/UnifiedPen.m UnifiedDriver/tests/test_monitor.m build/unified-tests/gestures.o build/unified-tests/touch.o -framework Cocoa -framework IOKit -framework ApplicationServices -o build/unified-tests/test_monitor
build/unified-tests/test_monitor
xcrun clang -arch arm64 -fobjc-arc -fblocks -Wall -Wextra -Werror -g -fsanitize=undefined,bounds -IUnifiedDriver -IMultitouch Multitouch/BT16TouchEvents.m Multitouch/BTGestureEvents.m UnifiedDriver/tests/test_controller.m build/unified-tests/gestures.o build/unified-tests/touch.o -framework Cocoa -framework IOKit -framework ApplicationServices -o build/unified-tests/test_controller
build/unified-tests/test_controller
