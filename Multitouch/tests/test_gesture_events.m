// Real AppKit decoding, not a post mock. No input posting or HID access.
#import "../BTGestureEvents.h"
#include <math.h>
static int checks,failures;
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x);failures++;}}while(0)
static NSEvent *decode(BTGestureEvent e){
    CGEventRef cg=BTCreateGestureEvent(e,2);CHECK(cg!=NULL);if(!cg)return nil;
    NSEvent *n=nil;@try{n=[NSEvent eventWithCGEvent:cg];}@catch(NSException *ex){fprintf(stderr,"AppKit rejected: %s\n",ex.reason.UTF8String);}
    CHECK(n!=nil);CFRelease(cg);return n;
}
int main(void){@autoreleasepool{
    const BTGesturePhase phases[]={BTGesturePhaseBegan,BTGesturePhaseChanged,BTGesturePhaseEnded,BTGesturePhaseCancelled};
    const NSEventPhase expected[]={NSEventPhaseBegan,NSEventPhaseChanged,NSEventPhaseEnded,NSEventPhaseCancelled};
    for(size_t i=0;i<4;i++){
        NSEvent *n=decode((BTGestureEvent){.kind=BTGestureMagnify,.phase=phases[i],.x=-1200,.y=300,.magnification=i==1?0.25:0});
        if(n){CHECK(n.type==NSEventTypeMagnify);CHECK(n.phase==expected[i]);CHECK(fabs(n.magnification-(i==1?0.25:0))<0.000001);}
        n=decode((BTGestureEvent){.kind=BTGestureScroll,.phase=phases[i],.x=-1200,.y=300,.deltaX=i==1?-7:0,.deltaY=i==1?12:0});
        if(n){CHECK(n.type==NSEventTypeScrollWheel);CHECK(n.phase==expected[i]);CHECK(n.hasPreciseScrollingDeltas);CHECK(fabs(n.scrollingDeltaX-(i==1?-7:0))<0.001);CHECK(fabs(n.scrollingDeltaY-(i==1?12:0))<0.001);}
    }
    NSEvent *n=decode((BTGestureEvent){.kind=BTGestureMagnify,.phase=BTGesturePhaseChanged,.magnification=-0.125});
    if(n)CHECK(fabs(n.magnification+0.125)<0.000001);
    n=decode((BTGestureEvent){.kind=BTGesturePointerDown,.phase=BTGesturePhaseBegan,.x=-1250,.y=300});
    if(n){CHECK(n.type==NSEventTypeLeftMouseDown);CHECK(n.clickCount==2);}
    n=decode((BTGestureEvent){.kind=BTGesturePointerUp,.phase=BTGesturePhaseCancelled,.x=-1250,.y=300});if(n)CHECK(n.type==NSEventTypeLeftMouseUp);
    n=decode((BTGestureEvent){.kind=BTGesturePointerMove,.phase=BTGesturePhaseNone,.x=-1250,.y=300});if(n)CHECK(n.type==NSEventTypeMouseMoved);
    BTGestureEvent invalid[]={
        {.kind=BTGestureMagnify,.phase=BTGesturePhaseNone},
        {.kind=BTGestureMagnify,.phase=BTGesturePhaseChanged,.magnification=NAN},
        {.kind=BTGestureScroll,.phase=BTGesturePhaseChanged,.deltaY=INFINITY},
        {.kind=BTGesturePointerDown,.phase=BTGesturePhaseBegan,.x=NAN},
        {.kind=(BTGestureKind)99,.phase=BTGesturePhaseChanged}
    };
    for(size_t i=0;i<sizeof invalid/sizeof *invalid;i++){CGEventRef cg=BTCreateGestureEvent(invalid[i],1);CHECK(cg==NULL);if(cg)CFRelease(cg);}
    printf("Native gesture AppKit interpretation: %d checks, %d failures\n",checks,failures);return failures?1:0;
}}
