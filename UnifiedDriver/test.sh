#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/unified-tests/scratch
export TMPDIR="$PWD/build/unified-tests/scratch"
xcrun clang -arch arm64 -fobjc-arc -Wall -Wextra -Werror -g -fsanitize=undefined,bounds -IUnifiedDriver UnifiedDriver/UnifiedPen.m UnifiedDriver/tests/test_pen.m -framework Cocoa -framework ApplicationServices -o build/unified-tests/test_pen
build/unified-tests/test_pen
xcrun clang -arch arm64 -std=c11 -Wall -Wextra -Werror -g -fsanitize=undefined,bounds -IMultitouch -c Multitouch/BTGestures.c -o build/unified-tests/gestures.o
xcrun clang -arch arm64 -std=c11 -Wall -Wextra -Werror -g -fsanitize=undefined,bounds -IMultitouch -c Multitouch/BT16Touch.c -o build/unified-tests/touch.o
xcrun clang -arch arm64 -fobjc-arc -fblocks -Wall -Wextra -Werror -g -fsanitize=undefined,bounds -IUnifiedDriver -IMultitouch UnifiedDriver/PenBattery.m UnifiedDriver/UnifiedPen.m UnifiedDriver/tests/test_monitor.m build/unified-tests/gestures.o build/unified-tests/touch.o -framework Cocoa -framework IOKit -framework ApplicationServices -o build/unified-tests/test_monitor
build/unified-tests/test_monitor
xcrun clang -arch arm64 -fobjc-arc -fblocks -Wall -Wextra -Werror -g -fsanitize=undefined,bounds -IUnifiedDriver -IMultitouch Multitouch/BT16TouchEvents.m Multitouch/BTGestureEvents.m UnifiedDriver/UnifiedPen.m UnifiedDriver/tests/test_controller.m build/unified-tests/gestures.o build/unified-tests/touch.o -framework Cocoa -framework IOKit -framework ApplicationServices -o build/unified-tests/test_controller
build/unified-tests/test_controller
xcrun clang -arch arm64 -fobjc-arc -fblocks -Wall -Wextra -Werror -g -fsanitize=undefined,bounds -IUnifiedDriver -IMultitouch UnifiedDriver/SetupState.m UnifiedDriver/tests/test_setup.m -framework Foundation -o build/unified-tests/test_setup
build/unified-tests/test_setup
xcrun clang -arch arm64 -DBT_UNIFIED_DRIVER=1 -fobjc-arc -fblocks -Wall -Wextra -Werror -g -fsanitize=undefined,bounds -IUnifiedDriver -IMultitouch UnifiedDriver/tests/test_launch.m UnifiedDriver/{MenuIcon,PenBattery,BatteryNotifications,SetupState,UpdatePolicy,UpdateController,ShortcutEditor,UnifiedPen,UnifiedMonitor}.m Multitouch/{BTTouchController,BT16TouchEvents,BTGestureEvents}.m build/unified-tests/{gestures,touch}.o -framework Cocoa -framework IOKit -framework ApplicationServices -framework ServiceManagement -framework UserNotifications -o build/unified-tests/test_launch
build/unified-tests/test_launch
xcrun clang -arch arm64 -fobjc-arc -fblocks -Wall -Wextra -Werror -g -fsanitize=undefined,bounds -IUnifiedDriver UnifiedDriver/UpdatePolicy.m UnifiedDriver/tests/test_updates.m -framework Foundation -o build/unified-tests/test_updates
build/unified-tests/test_updates
xcrun clang -arch arm64 -fobjc-arc -fblocks -Wall -Wextra -Werror -g -fsanitize=undefined,bounds -IUnifiedDriver UnifiedDriver/UpdatePolicy.m UnifiedDriver/tests/test_update_io.m -framework Cocoa -o build/unified-tests/test_update_io
build/unified-tests/test_update_io
xcrun clang -arch arm64 -fobjc-arc -Wall -Wextra -Werror -g -fsanitize=undefined,bounds -IUnifiedDriver UnifiedDriver/PenBattery.m UnifiedDriver/tests/test_battery.m -framework Foundation -o build/unified-tests/test_battery
build/unified-tests/test_battery
