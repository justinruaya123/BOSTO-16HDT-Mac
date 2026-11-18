#import <Cocoa/Cocoa.h>
#import "UnifiedPen.h"
#include <assert.h>
int main(void) { @autoreleasepool {
    uint8_t b[]={1,0x1f,0,0x23,0,0x14,0,0x10}; UPPacket p={0};
    assert(UPParse(b,8,&p)); assert(p.inRange && p.tip && p.barrel && p.secondary && p.invert);
    assert(p.x==0x2300 && p.y==0x1400 && p.pressure==0x1000);
    assert(!UPParse(NULL,8,&p)); assert(!UPParse(b,8,NULL)); assert(!UPParse(b,9,&p));
    assert(!UPParse(b,7,&p)); b[0]=2; assert(!UPParse(b,8,&p)); b[0]=1;
    b[3]=0x47; assert(!UPParse(b,8,&p)); b[3]=0x23;
    b[5]=0x29; assert(!UPParse(b,8,&p)); b[5]=0x14;
    b[7]=0x21; assert(!UPParse(b,8,&p)); b[7]=0x10;
    b[1]=0x80; assert(!UPParse(b,8,&p)); b[1]=0x10; assert(UPParse(b,8,&p));
    UPState s={0}; UPBatch batch={0}; CGRect bounds=CGRectMake(-1920,0,1920,1080);
    assert(UPAdvance(&s,p,bounds,1,&batch)); assert(batch.count==2);
    assert(CGEventGetType(batch.events[0])==kCGEventTabletProximity);
    assert(CGEventGetIntegerValueField(batch.events[0],kCGTabletProximityEventEnterProximity)==1);
    assert(CGEventGetIntegerValueField(batch.events[0],kCGTabletProximityEventCapabilityMask)==0x447);
    assert(CGEventGetDoubleValueField(batch.events[1],kCGTabletEventPointPressure)==0);
    assert(CGEventGetType(batch.events[1])==kCGEventMouseMoved);
    assert(CGEventGetIntegerValueField(batch.events[1],kCGMouseEventSubtype)==1); UPClear(&batch);
    p.tip=true; assert(UPAdvance(&s,p,bounds,2,&batch)); assert(batch.count==1);
    CGEventRef e=batch.events[0]; assert(CGEventGetType(e)==kCGEventLeftMouseDown);
    assert(fabs(CGEventGetDoubleValueField(e,kCGTabletEventPointPressure)-0.25)<0.0001);
    assert(CGEventGetIntegerValueField(e,kCGTabletEventPointButtons)==1);
    NSEvent *native=[NSEvent eventWithCGEvent:e];
    assert(native.subtype==NSEventSubtypeTabletPoint);
    // AppKit mouse pressure is quantized to 8 bits during CGEvent conversion.
    assert(fabs(native.pressure-0.25)<=1.0/255);
    assert(CGEventGetLocation(e).x==-960); UPClear(&batch);
    assert(UPAdvance(&s,p,bounds,1,&batch)); assert(CGEventGetType(batch.events[0])==kCGEventLeftMouseDragged); UPClear(&batch);
    p.inRange=false; assert(UPAdvance(&s,p,bounds,1,&batch)); assert(batch.count==2);
    assert(CGEventGetType(batch.events[0])==kCGEventLeftMouseUp);
    assert(CGEventGetDoubleValueField(batch.events[0],kCGTabletEventPointPressure)==0);
    assert(CGEventGetType(batch.events[1])==kCGEventTabletProximity);
    assert(CGEventGetIntegerValueField(batch.events[1],kCGTabletProximityEventEnterProximity)==0); UPClear(&batch);
    p.inRange=true; p.invert=true; assert(UPAdvance(&s,p,bounds,1,&batch)); UPClear(&batch);
    p.invert=false;p.barrel=p.secondary=true;p.x=0x4600;p.y=0x2800;p.pressure=0x2000;
    assert(UPAdvance(&s,p,bounds,1,&batch));assert(batch.count==4);
    assert(CGEventGetIntegerValueField(batch.events[2],kCGTabletProximityEventPointerType)==1);
    assert(CGEventGetIntegerValueField(batch.events[3],kCGTabletEventPointButtons)==7);
    assert(CGEventGetDoubleValueField(batch.events[3],kCGTabletEventPointPressure)==1);
    assert(CGEventGetLocation(batch.events[3]).x==0 && CGEventGetLocation(batch.events[3]).y==1080);UPClear(&batch);
    UPCancel(&s,&batch); assert(batch.count==2); UPClear(&batch); UPCancel(&s,&batch); assert(batch.count==0);
    assert(!UPAdvance(&s,p,CGRectZero,1,&batch)); assert(!UPAdvance(&s,p,bounds,NAN,&batch));
    // One mapping owns outgoing pressure and the packet tester, including up/out.
    UPPacket pressurePacket={.pressure=4096,.tip=true,.inRange=true};
    assert(UPPressure(pressurePacket,1)==0.5);
    assert(UPPressure(pressurePacket,2)==0.25);
    assert(UPPressure(pressurePacket,0.5)==sqrt(0.5));
    pressurePacket.pressure=0;assert(UPPressure(pressurePacket,0.25)==0);
    pressurePacket.pressure=8192;assert(UPPressure(pressurePacket,4)==1);
    pressurePacket.tip=false;assert(UPPressure(pressurePacket,1)==0);
    pressurePacket.tip=true;pressurePacket.inRange=false;assert(UPPressure(pressurePacket,1)==0);
    assert(UPValidatedExponent(@"2")==1 && UPValidatedExponent(@(NAN))==1);
    assert(UPValidatedExponent(@0.24)==1 && UPValidatedExponent(@4.01)==1);
    assert(UPValidatedExponent(@0.5)==0.5);
    UPButtonState buttons={0};UPPacket bp={.inRange=true,.barrel=true};
    assert(UPButtonPresses(&buttons,bp,false)==0); // Initial held state.
    assert(UPButtonPresses(&buttons,bp,false)==0);
    bp.barrel=false;assert(UPButtonPresses(&buttons,bp,false)==0);
    bp.barrel=true;assert(UPButtonPresses(&buttons,bp,false)==1);
    assert(UPButtonPresses(&buttons,bp,false)==0); // No held repeats.
    bp.secondary=true;assert(UPButtonPresses(&buttons,bp,false)==2);
    bp.inRange=false;assert(UPButtonPresses(&buttons,bp,false)==0);
    bp.inRange=true;assert(UPButtonPresses(&buttons,bp,false)==0);
    bp.invert=true;assert(UPButtonPresses(&buttons,bp,false)==0);
    bp.barrel=bp.secondary=false;assert(UPButtonPresses(&buttons,bp,true)==0);
    bp.barrel=true;assert(UPButtonPresses(&buttons,bp,true)==0);
    assert(UPButtonPresses(&buttons,bp,false)==0); // Capture-held stays suppressed.
    bp.barrel=false;UPButtonPresses(&buttons,bp,false);
    bp.barrel=bp.secondary=true;assert(UPButtonPresses(&buttons,bp,false)==3);
    assert(UPShortcutValid(6,kCGEventFlagMaskCommand));
    assert(UPShortcutValid(64,0));
    assert(UPShortcutValid(79,0) && UPShortcutValid(80,0) && UPShortcutValid(90,0));
    assert(!UPShortcutValid(55,0)); // Modifier alone.
    assert(!UPShortcutValid(65535,0));
    assert(!UPShortcutValid(6,kCGEventFlagMaskAlphaShift));
    UPBatch keys={0};assert(UPShortcutEvents(6,kCGEventFlagMaskCommand,&keys));
    assert(keys.count==2 && CGEventGetType(keys.events[0])==kCGEventKeyDown);
    assert(CGEventGetType(keys.events[1])==kCGEventKeyUp);
    assert(CGEventGetFlags(keys.events[0])==kCGEventFlagMaskCommand);
    assert(CGEventGetFlags(keys.events[1])==0);
    UPClear(&keys);
    puts("Unified pen parser/native event checks passed (no events posted).");
} return 0; }
