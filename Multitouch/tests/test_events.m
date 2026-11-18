#import <Cocoa/Cocoa.h>
#import "../BT16TouchEvents.h"
#include <math.h>
static int checks, failures;
#define CHECK(x) do { checks++; if (!(x)) { failures++; fprintf(stderr,"line %d: FAIL %s\n",__LINE__,#x); } } while(0)
#define CLOSE(a,b) CHECK(fabs((a)-(b)) < 1e-8)
int main(int argc,const char **argv) {
 @autoreleasepool {
    const BTEventPhase phases[]={BTEventDown,BTEventDrag,BTEventUp};
    const CGEventType types[]={kCGEventLeftMouseDown,kCGEventLeftMouseDragged,kCGEventLeftMouseUp};
    for(size_t i=0;i<3;i++) {
        CGEventRef event=BTCreateMouseEvent((BTPointerEvent){phases[i],2429.5,539.5},2);
        CHECK(event!=NULL);
        if(event) {
            CHECK(CGEventGetType(event)==types[i]); CGPoint p=CGEventGetLocation(event); CLOSE(p.x,2429.5); CLOSE(p.y,539.5);
            CHECK(CGEventGetIntegerValueField(event,kCGMouseEventButtonNumber)==0);
            CHECK(CGEventGetIntegerValueField(event,kCGMouseEventSubtype)==0); // never a pen/tablet event
            CHECK(CGEventGetIntegerValueField(event,kCGMouseEventClickState)==2);
            CFRelease(event);
        }
    }
    CHECK(BTCreateMouseEvent((BTPointerEvent){BTEventNone,0,0},1)==NULL);
    CHECK(BTCreateMouseEvent((BTPointerEvent){BTEventDown,NAN,0},1)==NULL);
    CHECK(argc==2);
    NSData *data=argc==2?[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]]:nil;
    NSDictionary *fixture=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
    CHECK(fixture!=nil); NSArray *samples=fixture[@"savedSamples"]; CHECK(samples.count==32);
    BTTouchState state={0}; size_t valid=0,downs=0,drags=0,ups=0;
    for(NSDictionary *sample in samples) {
        NSString *hex=sample[@"hex"]; uint8_t packet[64]={0};
        CHECK(hex.length==128);
        for(size_t i=0;i<64;i++) { unsigned value=0; sscanf(hex.UTF8String+2*i,"%2x",&value); packet[i]=(uint8_t)value; }
        BTTouchFrame frame={0}; bool parsed=BTParseTouchReport(packet,64,&frame); CHECK(parsed); if(!parsed)continue; valid++;
        BTPointerEvent event={0};
        if(BTUpdateTouch(&state,&frame,(BTDisplayBounds){1470,0,1920,1080},&event)) {
            if(event.phase==BTEventDown) { downs++; CLOSE(event.x,2927.8731079101562); CLOSE(event.y,402.601875); }
            if(event.phase==BTEventDrag)drags++;
            if(event.phase==BTEventUp)ups++;
            CGEventRef mouse=BTCreateMouseEvent(event,1); CHECK(mouse!=NULL);
            if(mouse) { CGPoint p=CGEventGetLocation(mouse); CLOSE(p.x,event.x); CLOSE(p.y,event.y); CFRelease(mouse); }
        }
    }
    CHECK(valid==32); CHECK(downs==1); CHECK(drags==1); CHECK(ups==0);
    BTPointerEvent release={0}; CHECK(BTReleaseTouch(&state,&release)); CHECK(release.phase==BTEventUp);
    printf("Native mouse adapter + authentic packet replay: %d checks, %d failures\n",checks,failures);
    return failures?1:0;
 }
}
