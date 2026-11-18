#import "BT16TouchEvents.h"
#include <math.h>

CGEventRef BTCreateMouseEvent(BTPointerEvent event, int64_t clickCount) {
    if (!isfinite(event.x) || !isfinite(event.y)) return NULL;
    CGEventType type;
    switch (event.phase) {
        case BTEventDown: type = kCGEventLeftMouseDown; break;
        case BTEventDrag: type = kCGEventLeftMouseDragged; break;
        case BTEventUp: type = kCGEventLeftMouseUp; break;
        default: return NULL;
    }
    CGEventRef mouse = CGEventCreateMouseEvent(NULL, type, CGPointMake(event.x, event.y), kCGMouseButtonLeft);
    if (mouse) {
        CGEventSetIntegerValueField(mouse, kCGMouseEventSubtype, 0);
        CGEventSetIntegerValueField(mouse, kCGMouseEventClickState, clickCount > 0 ? clickCount : 1);
        CGEventSetDoubleValueField(mouse, kCGMouseEventPressure, event.phase == BTEventUp ? 0 : 1);
    }
    return mouse;
}
