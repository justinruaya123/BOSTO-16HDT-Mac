#import "BTGestureEvents.h"
#import "BT16TouchEvents.h"
#include <math.h>

static int64_t phaseValue(BTGesturePhase phase) {
    switch(phase) {
        case BTGesturePhaseBegan:return kCGScrollPhaseBegan;
        case BTGesturePhaseChanged:return kCGScrollPhaseChanged;
        case BTGesturePhaseEnded:return kCGScrollPhaseEnded;
        case BTGesturePhaseCancelled:return kCGScrollPhaseCancelled;
        case BTGesturePhaseNone:return 0;
    }
    return 0;
}
CGEventRef BTCreateGestureEvent(BTGestureEvent e,int64_t clickCount) {
    if(!isfinite(e.x) || !isfinite(e.y) || !isfinite(e.deltaX) || !isfinite(e.deltaY) || !isfinite(e.magnification))return NULL;
    CGEventRef cg=NULL;
    switch(e.kind) {
        case BTGesturePointerMove:
            if(e.phase!=BTGesturePhaseNone)return NULL;
            cg=CGEventCreateMouseEvent(NULL,kCGEventMouseMoved,CGPointMake(e.x,e.y),kCGMouseButtonLeft);break;
        case BTGesturePointerDown:case BTGesturePointerDrag:case BTGesturePointerUp: {
            BTPointerEvent mouse={.phase=e.kind==BTGesturePointerDown?BTEventDown:e.kind==BTGesturePointerDrag?BTEventDrag:BTEventUp,.x=e.x,.y=e.y};
            cg=BTCreateMouseEvent(mouse,clickCount);break;
        }
        case BTGestureScroll:
            if(!phaseValue(e.phase) || fabs(e.deltaX)>32767 || fabs(e.deltaY)>32767)return NULL;
            cg=CGEventCreateScrollWheelEvent(NULL,kCGScrollEventUnitPixel,2,(int32_t)lrint(e.deltaY),(int32_t)lrint(e.deltaX));
            if(cg){
                CGEventSetIntegerValueField(cg,kCGScrollWheelEventIsContinuous,1);
                CGEventSetIntegerValueField(cg,kCGScrollWheelEventScrollPhase,phaseValue(e.phase));
                CGEventSetDoubleValueField(cg,kCGScrollWheelEventFixedPtDeltaAxis1,e.deltaY);
                CGEventSetDoubleValueField(cg,kCGScrollWheelEventFixedPtDeltaAxis2,e.deltaX);
            }
            break;
        case BTGestureMagnify:
            if(!phaseValue(e.phase) || fabs(e.magnification)>1)return NULL;
            cg=CGEventCreate(NULL);
            if(cg){
                // Undocumented recognized-gesture fields; no vendored serializer/IOHID structs.
                // Contract reference: Hammerspoon eventtap/TouchEvents.c (field values only).
                CGEventSetType(cg,(CGEventType)29);
                CGEventSetFlags(cg,kCGEventFlagMaskNonCoalesced);
                CGEventSetIntegerValueField(cg,(CGEventField)0x6e,8);
                CGEventSetIntegerValueField(cg,(CGEventField)0x84,phaseValue(e.phase));
                CGEventSetDoubleValueField(cg,(CGEventField)0x71,e.magnification);
            }
            break;
        default:return NULL;
    }
    if(cg){CGEventSetLocation(cg,CGPointMake(e.x,e.y));CGEventSetIntegerValueField(cg,kCGEventSourceUserData,0x42544d54);}
    return cg;
}
