#import <Cocoa/Cocoa.h>
#import "BTGestures.h"
// Creates only; never posts input or opens HID. Caller owns the result.
CGEventRef BTCreateGestureEvent(BTGestureEvent event,int64_t clickCount) CF_RETURNS_RETAINED;
