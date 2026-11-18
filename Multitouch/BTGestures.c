// Multitouch and palm-rejection policy. No HID, event-posting or clock APIs.
#include "BTGestures.h"
#include <math.h>
#include <string.h>

BTGestureConfig BTGestureDefaultConfig(void) {
    return (BTGestureConfig){2,0.06,3,4,0.04,12,0.5};
}
static bool validDelay(double n) { return isfinite(n) && n>=0 && n<=30; }
static bool validConfig(BTGestureConfig c) {
    return validDelay(c.resumeDelay) && isfinite(c.armingDelay) && c.armingDelay>=0 && c.armingDelay<=1 &&
        isfinite(c.pointerSlop) && c.pointerSlop>=0 && c.pointerSlop<=100 &&
        isfinite(c.scrollSlop) && c.scrollSlop>0 && c.scrollSlop<=100 &&
        isfinite(c.pinchSlop) && c.pinchSlop>0 && c.pinchSlop<=0.5 &&
        isfinite(c.minSpan) && c.minSpan>0 && c.minSpan<=100 &&
        isfinite(c.maxMagnification) && c.maxMagnification>0 && c.maxMagnification<=1;
}
bool BTGestureInit(BTGestureState *s,BTGestureConfig c) {
    if(!s)return false;
    memset(s,0,sizeof *s);
    if(!validConfig(c))return false;
    s->config=c;s->mode=BTGestureIdle;s->pen=BTPenUnknown;
    return true;
}
static bool push(BTGestureBatch *b,BTGestureEvent event) {
    if(b->count>=BT_GESTURE_BATCH_CAPACITY)return false;
    b->events[b->count++]=event;return true;
}
static BTGestureEvent pointer(BTGestureKind kind,BTGesturePhase phase,double x,double y) {
    return (BTGestureEvent){.kind=kind,.phase=phase,.x=x,.y=y};
}
static bool finish(BTGestureState *s,BTGestureBatch *b,BTGesturePhase phase) {
    bool result=true;
    switch(s->mode) {
        case BTGestureDragging: result=push(b,pointer(BTGesturePointerUp,phase,s->x,s->y));break;
        case BTGestureScrolling: result=push(b,(BTGestureEvent){.kind=BTGestureScroll,.phase=phase,.x=s->anchorX,.y=s->anchorY});break;
        case BTGestureMagnifying: result=push(b,(BTGestureEvent){.kind=BTGestureMagnify,.phase=phase,.x=s->anchorX,.y=s->anchorY});break;
        case BTGestureIdle: case BTGestureOnePending: case BTGestureTwoPending: case BTGestureBlocked: break;
        default: result=false;break;
    }
    s->mode=BTGestureIdle;return result;
}
void BTGestureCancel(BTGestureState *s,BTGestureBatch *b) {
    if(!b)return;
    memset(b,0,sizeof *b);if(!s)return;
    (void)finish(s,b,BTGesturePhaseCancelled);
    s->mode=s->lastCount?BTGestureBlocked:BTGestureIdle;
}
static bool clockStep(BTGestureState *s,double time,BTGestureBatch *b) {
    if(!isfinite(time) || time<0 || (s->clockValid && time<s->lastTime)) {
        BTGestureCancel(s,b);return false;
    }
    s->clockValid=true;s->lastTime=time;return true;
}
static bool suppressed(const BTGestureState *s,double time) {
    return s->pen!=BTPenOutOfRange || (s->penOutSeen && time-s->penOutAt<s->config.resumeDelay);
}
BTGestureReadiness BTGestureGetReadiness(const BTGestureState *s,double time) {
    if(!s || !s->clockValid || !isfinite(time) || time<s->lastTime || s->pen==BTPenUnknown)
        return BTGestureReadinessUnknown;
    if(suppressed(s,time))return BTGestureReadinessPen;
    if(s->mode==BTGestureBlocked)return BTGestureReadinessLiftRequired;
    return BTGestureReadinessReady;
}
static bool suppressOutput(BTGestureState *s,BTGestureBatch *b) {
    bool result=finish(s,b,BTGesturePhaseCancelled);
    s->mode=s->lastCount?BTGestureBlocked:BTGestureIdle;return result;
}
bool BTGestureHandlePen(BTGestureState *s,BTGesturePenInput input,BTGestureBatch *b) {
    if(!s || !b)return false;
    memset(b,0,sizeof *b);if(!clockStep(s,input.time,b))return false;
    if(input.presence!=BTPenUnknown && input.presence!=BTPenOutOfRange && input.presence!=BTPenInRange) {
        s->pen=BTPenUnknown;BTGestureCancel(s,b);return false;
    }
    if(input.presence==BTPenInRange || (input.presence==BTPenUnknown && s->pen!=BTPenUnknown))s->penWasDetected=true;
    if(input.presence==BTPenOutOfRange && s->pen!=BTPenOutOfRange && s->penWasDetected) {
        s->penOutAt=input.time;s->penOutSeen=true;s->penWasDetected=false;
    }
    s->pen=input.presence;
    return suppressed(s,input.time)?suppressOutput(s,b):true;
}
bool BTGestureSetResumeDelay(BTGestureState *s,BTGestureDelayInput input,BTGestureBatch *b) {
    if(!s || !b)return false;
    memset(b,0,sizeof *b);
    // Reject user input without replacing the last valid setting or gesture.
    if(!validDelay(input.seconds))return false;
    if(!clockStep(s,input.time,b))return false;
    s->config.resumeDelay=input.seconds;
    return suppressed(s,input.time)?suppressOutput(s,b):true;
}
static bool beginDrag(BTGestureState *s,BTGestureBatch *b) {
    s->mode=BTGestureDragging;
    if(!push(b,pointer(BTGesturePointerDown,BTGesturePhaseBegan,s->startX,s->startY)))return false;
    if(s->x!=s->startX || s->y!=s->startY)
        return push(b,pointer(BTGesturePointerDrag,BTGesturePhaseChanged,s->x,s->y));
    return true;
}
bool BTGestureTick(BTGestureState *s,double time,BTGestureBatch *b) {
    if(!s || !b)return false;
    memset(b,0,sizeof *b);if(!clockStep(s,time,b))return false;
    if(suppressed(s,time))return suppressOutput(s,b);
    if(s->mode==BTGestureOnePending && time-s->startedAt>=s->config.armingDelay)return beginDrag(s,b);
    return true;
}
static bool validFrame(const BTTouchFrame *frame,BTDisplayBounds bounds) {
    double x,y;
    if(frame->count>BT_TOUCH_MAX_CONTACTS || !BTMapTouchPoint((BTContact){0},bounds,&x,&y))return false;
    for(size_t i=0;i<frame->count;i++) {
        if(frame->contacts[i].identifier>63)return false;
        for(size_t j=0;j<i;j++)if(frame->contacts[j].identifier==frame->contacts[i].identifier)return false;
    }
    return true;
}
static bool oneFinger(BTGestureState *s,BTGestureTouchInput input,BTGestureBatch *b) {
    BTContact contact=input.frame.contacts[0];double x,y;
    if(!BTMapTouchPoint(contact,input.bounds,&x,&y))return false;
    if(s->mode==BTGestureScrolling || s->mode==BTGestureMagnifying || s->mode==BTGestureTwoPending) {
        bool result=finish(s,b,BTGesturePhaseEnded);s->mode=BTGestureBlocked;return result;
    }
    if(s->mode==BTGestureBlocked)return true;
    if(s->mode==BTGestureIdle) {
        s->mode=BTGestureOnePending;s->identifiers[0]=contact.identifier;
        s->startedAt=input.time;s->startX=s->x=x;s->startY=s->y=y;
    }
    if(contact.identifier!=s->identifiers[0]) {
        bool result=finish(s,b,BTGesturePhaseCancelled);s->mode=BTGestureBlocked;return result;
    }
    bool changed=x!=s->x || y!=s->y;s->x=x;s->y=y;
    if(s->mode==BTGestureOnePending) {
        if(hypot(x-s->startX,y-s->startY)>=s->config.pointerSlop || input.time-s->startedAt>=s->config.armingDelay)
            return beginDrag(s,b);
        return true;
    }
    if(s->mode!=BTGestureDragging)return false;
    return changed?push(b,pointer(BTGesturePointerDrag,BTGesturePhaseChanged,x,y)):true;
}
static bool twoFingers(BTGestureState *s,BTGestureTouchInput input,BTGestureBatch *b) {
    BTContact a=input.frame.contacts[0],c=input.frame.contacts[1];
    if(a.identifier>c.identifier){BTContact temp=a;a=c;c=temp;}
    double ax,ay,bx,by;
    if(!BTMapTouchPoint(a,input.bounds,&ax,&ay) || !BTMapTouchPoint(c,input.bounds,&bx,&by))return false;
    double cx=(ax+bx)/2,cy=(ay+by)/2,span=hypot(bx-ax,by-ay);
    if(s->mode==BTGestureBlocked)return true;
    if(s->mode==BTGestureIdle || s->mode==BTGestureOnePending || s->mode==BTGestureDragging) {
        if(!finish(s,b,BTGesturePhaseCancelled))return false;
        s->mode=BTGestureTwoPending;s->identifiers[0]=a.identifier;s->identifiers[1]=c.identifier;
        s->anchorX=s->lastCx=cx;s->anchorY=s->lastCy=cy;s->startSpan=s->lastSpan=span;
        return true;
    }
    if(a.identifier!=s->identifiers[0] || c.identifier!=s->identifiers[1]) {
        bool result=finish(s,b,BTGesturePhaseCancelled);s->mode=BTGestureBlocked;return result;
    }
    if(s->mode==BTGestureTwoPending) {
        if(s->startSpan<s->config.minSpan) {
            if(span>=s->config.minSpan){s->anchorX=s->lastCx=cx;s->anchorY=s->lastCy=cy;s->startSpan=s->lastSpan=span;}
            return true;
        }
        double scrollScore=hypot(cx-s->anchorX,cy-s->anchorY)/s->config.scrollSlop;
        double pinchScore=span>=s->config.minSpan?fabs(span/s->startSpan-1)/s->config.pinchSlop:0;
        if(scrollScore<1 && pinchScore<1)return true;
        s->mode=pinchScore>scrollScore?BTGestureMagnifying:BTGestureScrolling;
        BTGestureKind kind=s->mode==BTGestureMagnifying?BTGestureMagnify:BTGestureScroll;
        // Scroll/gesture routing must not stay under an unrelated desktop cursor.
        if(!push(b,pointer(BTGesturePointerMove,BTGesturePhaseNone,s->anchorX,s->anchorY)) ||
           !push(b,(BTGestureEvent){.kind=kind,.phase=BTGesturePhaseBegan,.x=s->anchorX,.y=s->anchorY}))return false;
    }
    if(s->mode==BTGestureScrolling) {
        double dx=cx-s->lastCx,dy=cy-s->lastCy;s->lastCx=cx;s->lastCy=cy;
        return (dx!=0 || dy!=0)?push(b,(BTGestureEvent){.kind=BTGestureScroll,.phase=BTGesturePhaseChanged,
            .x=s->anchorX,.y=s->anchorY,.deltaX=dx,.deltaY=dy}):true;
    }
    if(s->mode==BTGestureMagnifying) {
        if(span<s->config.minSpan){bool result=finish(s,b,BTGesturePhaseCancelled);s->mode=BTGestureBlocked;return result;}
        double magnification=span/s->lastSpan-1;s->lastSpan=span;
        magnification=fmax(-s->config.maxMagnification,fmin(s->config.maxMagnification,magnification));
        return magnification!=0?push(b,(BTGestureEvent){.kind=BTGestureMagnify,.phase=BTGesturePhaseChanged,
            .x=s->anchorX,.y=s->anchorY,.magnification=magnification}):true;
    }
    return false;
}
bool BTGestureHandleTouch(BTGestureState *s,BTGestureTouchInput input,BTGestureBatch *b) {
    if(!s || !b)return false;
    memset(b,0,sizeof *b);if(!clockStep(s,input.time,b))return false;
    if(!validFrame(&input.frame,input.bounds)){BTGestureCancel(s,b);return false;}
    s->lastCount=input.frame.count;
    if(suppressed(s,input.time))return suppressOutput(s,b);
    if(input.frame.count==0) {
        if(s->mode==BTGestureOnePending) {
            // Release before arming is a tap, never a lost or held click.
            if(!push(b,pointer(BTGesturePointerDown,BTGesturePhaseBegan,s->x,s->y)) ||
               !push(b,pointer(BTGesturePointerUp,BTGesturePhaseEnded,s->x,s->y)))return false;
            s->mode=BTGestureIdle;return true;
        }
        return finish(s,b,BTGesturePhaseEnded);
    }
    if(input.frame.count>2) {
        bool result=finish(s,b,BTGesturePhaseCancelled);s->mode=BTGestureBlocked;return result;
    }
    return input.frame.count==1?oneFinger(s,input,b):twoFingers(s,input,b);
}
