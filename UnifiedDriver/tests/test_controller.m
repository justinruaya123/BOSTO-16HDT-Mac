// Existing offline hardware fixture, exercising the unified-only controller guard.
#import <Foundation/Foundation.h>
// Advance only this fixture's monotonic uptime; no wall-clock sleeps or HID I/O.
static double uptimeOffset;
@interface PalmTestClock : NSObject
+ (instancetype)processInfo;
- (NSTimeInterval)systemUptime;
@end
@implementation PalmTestClock
+ (instancetype)processInfo {static PalmTestClock *clock;if(!clock)clock=[self new];return clock;}
- (NSTimeInterval)systemUptime {return NSProcessInfo.processInfo.systemUptime+uptimeOffset;}
@end
#define NSProcessInfo PalmTestClock
#define BT_UNIFIED_DRIVER 1
#define BTCreateGestureEvent TestGestureEventFactory
#import "../../Multitouch/tests/hardware_fakes.h"
#undef BTCreateGestureEvent
#import "BTGestureEvents.h"
extern CGEventRef BTCreateGestureEvent(BTGestureEvent event,int64_t clickCount);
static BOOL failCancelledUp;
CGEventRef TestGestureEventFactory(BTGestureEvent event,int64_t clickCount) {
    if(failCancelledUp && event.kind==BTGesturePointerUp && event.phase==BTGesturePhaseCancelled)return NULL;
    return BTCreateGestureEvent(event,clickCount);
}
#include <assert.h>
static void drainMain(void) {
    __block bool done=false;dispatch_async(dispatch_get_main_queue(),^{done=true;});
    double until=CFAbsoluteTimeGetCurrent()+1;
    while(!done && CFAbsoluteTimeGetCurrent()<until)CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
    assert(done);
}
// Most lifecycle tests start their stimulus with both streams attached.
static BOOL startAndServicePen(BTTouchController *controller) {
    BOOL started=[controller startWithDisplay:42 postEvents:YES error:NULL];
    drainMain();return started && controller.running;
}
@interface BTTouchController (OrientationTest)
- (void)setFlipTouchY:(BOOL)flip;
@end
static void tapAtY(uint16_t y, uint32_t reportID) {
    uint8_t packet[64]={0};packet[0]=(uint8_t)reportID;
    packet[1]=reportID==3?0x80:0x41;
    packet[3]=0x20;packet[4]=y&255;packet[5]=y>>8;packet[55]=1;
    size_t length=reportID==3?6:64;
    reportCallback(reportContext,0,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,reportID,packet,length);
    packet[1]=packet[55]=0;
    reportCallback(reportContext,0,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,reportID,packet,length);
}
static void checkVerticalOrientation(BTTouchController *controller) {
    resetFakes();assert(startAndServicePen(controller));
    tapAtY(0,3);
    CGPoint normal=CGEventGetLocation(postedEvents[0].CGEvent);
    assert(normal.y==-1080);
    assert([controller respondsToSelector:@selector(setFlipTouchY:)] && "Missing finger-only vertical orientation");
    [controller setFlipTouchY:YES];
    tapAtY(0,3);tapAtY(9600,4);
    CGPoint flippedTop=CGEventGetLocation(postedEvents[2].CGEvent);
    CGPoint flippedBottom=CGEventGetLocation(postedEvents[4].CGEvent);
    assert(flippedTop.x==normal.x && flippedBottom.x==normal.x);
    assert(flippedTop.y==-1 && flippedBottom.y==-1080);
    pressFakeFinger();assert(postedDowns==4 && postedUps==3);
    failCancelledUp=YES;
    [controller setFlipTouchY:NO];
    assert(controller.running && controller.flipTouchY && postedUps==3 && penCloseCalls==0);
    failCancelledUp=NO;
    [controller setFlipTouchY:NO];assert(postedUps==4);
    pressFakeFinger();assert(postedDowns==4);
    sendFakeTouches(0,0,0);pressFakeFinger();
    assert(postedDowns==5 && openCalls==1 && penOpenCalls==1 && controller.running);
    [controller stop];drainMain();
    puts("Touch orientation reflects Y only in both report formats and rearms safely after lift.");
}
static void checkTouchReportRecovery(BTTouchController *controller) {
    resetFakes();assert(startAndServicePen(controller));
    tapAtY(4800,4);assert(postedDowns==1 && postedUps==1);
    // Immediately following vendor packets can be duplicates of the same tap.
    tapAtY(4800,3);assert(postedDowns==1 && postedUps==1);
    // Simulate an idle gap, without restarting either HID connection.
    uint8_t vendorHeld[6]={3,0x80,0,0x20,0xc0,0x12};
    reportCallback(reportContext,0,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,3,vendorHeld,6);
    [controller setValue:@(NSProcessInfo.processInfo.systemUptime-1) forKey:@"report4PreferredUntil"];
    sendFakeTouches(0,0,0); // Idle frames do not extend preference.
    reportCallback(reportContext,0,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,3,vendorHeld,6);
    vendorHeld[1]=0;
    reportCallback(reportContext,0,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,3,vendorHeld,6);
    assert(postedDowns==1 && postedUps==1 && "An ignored held duplicate cannot become a tap");
    tapAtY(4800,3);
    assert(postedDowns==2 && postedUps==2 && "A previous multitouch frame must not permanently block vendor taps");
    // When report 4 comes back, it must still be able to deliver both gestures.
    sendFakeTouches(2,4000,8000);sendFakeTouches(2,4500,8500);
    assert(postedEvents.lastObject.type==NSEventTypeScrollWheel && postedEvents.lastObject.phase==NSEventPhaseChanged);
    sendFakeTouches(1,4500,0);
    assert(postedEvents.lastObject.phase==NSEventPhaseEnded);
    NSUInteger afterLift=postedEvents.count;
    sendFakeTouches(2,4500,8000);assert(postedEvents.count==afterLift);
    sendFakeTouches(2,4000,8500);
    assert(postedEvents.lastObject.type==NSEventTypeMagnify && postedEvents.lastObject.phase==NSEventPhaseChanged);
    assert(controller.running && openCalls==1 && penOpenCalls==1);
    [controller stop];drainMain();
    puts("Report-stream recovery: duplicate tap rejected, vendor tap restored after silence, scroll and pinch on report 4.");
}
static void forceReportGap(BTTouchController *controller) {
    [controller setValue:@(NSProcessInfo.processInfo.systemUptime-1) forKey:@"lastFrameAt"];
    [controller tick:nil];
}
static void checkPassivePairRecovery(BTTouchController *controller) {
    for(int palm=0;palm<2;palm++) {
        resetFakes();assert(startAndServicePen(controller));
        const uint8_t vendorHeld[6]={3,0x80,0,0x20,0xc0,0x12};
        reportCallback(reportContext,0,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,3,(uint8_t *)vendorHeld,6);
        forceReportGap(controller);
        if(palm){
            assert([controller updateResumeDelay:0]);
            sendFakePen(BTPenInRange);sendFakePen(BTPenOutOfRange);
        }
        // No release on either stream. Motion following the first real pair
        // should drive scroll unless the contacts were held during palm rejection.
        sendFakeTouches(2,4000,8000);sendFakeTouches(2,4000,8000);
        assert(symbolicPosts==0 && postedDowns==0);
        sendFakeTouches(2,4500,8500);
        if(palm) {
            assert(symbolicPosts==0);
            sendFakeTouches(0,0,0); // Also clear the original report 3 finger before starting a new pair.
            uint8_t vendorUp[6]={3};reportCallback(reportContext,0,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,3,vendorUp,6);
            sendFakeTouches(2,4000,8000);sendFakeTouches(2,4500,8500);
        }
        assert(postedEvents.lastObject.type==NSEventTypeScrollWheel && postedEvents.lastObject.phase==NSEventPhaseChanged);
        forceReportGap(controller);
        assert(postedEvents.lastObject.phase==NSEventPhaseCancelled);
        sendFakeTouches(2,4000,8000);sendFakeTouches(2,3500,8500);
        assert(postedEvents.lastObject.type==NSEventTypeMagnify && postedEvents.lastObject.phase==NSEventPhaseChanged);
        assert(postedDowns==0 && postedUps==0 && controller.running && openCalls==1+palm && penOpenCalls==1);
        [controller stop];drainMain();
    }
    assert([controller updateResumeDelay:2]);
    puts("Report gaps: scroll and pinch resume from measured pair motion without lift or HID reopen; pen suppression still requires lift.");
}
@interface BTTouchController (GestureActionsTest)
- (void)setGestureActions:(NSDictionary *)actions;
@end
static void chooseActions(BTTouchController *controller, NSDictionary *actions) {
    if([controller respondsToSelector:@selector(setGestureActions:)])[controller setGestureActions:actions];
}
static void checkGestureActions(BTTouchController *controller) {
    resetFakes();assert(startAndServicePen(controller));
    chooseActions(controller,@{@"swipe":@{@"key":@6,@"modifiers":@(kCGEventFlagMaskCommand)},@"pinch":@"off"});
    sendFakeTouches(2,4000,8000);sendFakeTouches(2,4500,8500);sendFakeTouches(2,5000,9000);
    chooseActions(controller,@{@"pinch":@"off"}); // The current swipe must finish on its original route.
    sendFakeTouches(2,5500,9500);sendFakeTouches(0,0,0);
    assert(postedEvents.count==2 && postedEvents[0].type==NSEventTypeKeyDown && postedEvents[1].type==NSEventTypeKeyUp && "A remapped swipe must emit only one key pair");
    assert(postedEvents[0].keyCode==6 && (postedEvents[0].modifierFlags&NSEventModifierFlagCommand));
    sendFakeTouches(2,4000,8000);sendFakeTouches(2,3500,8500);sendFakeTouches(0,0,0);
    assert(postedEvents.count==2 && "Off must not post any pinch phases");
    chooseActions(controller,@{@"swipe":@{@"key":@9999,@"modifiers":@0}});
    sendFakeTouches(2,4000,8000);sendFakeTouches(2,4500,8500);
    assert(postedEvents.lastObject.type==NSEventTypeScrollWheel && postedEvents.lastObject.phase==NSEventPhaseChanged);
    chooseActions(controller,@{@"swipe":@"off"});
    sendFakeTouches(0,0,0);
    assert(postedEvents.lastObject.type==NSEventTypeScrollWheel && postedEvents.lastObject.phase==NSEventPhaseEnded);
    sendFakeTouches(2,4000,8000);sendFakeTouches(2,3500,8500);sendFakeTouches(0,0,0);
    assert(postedEvents.lastObject.type==NSEventTypeMagnify && postedEvents.lastObject.phase==NSEventPhaseEnded);
    assert([controller.snapshot[@"peakContacts"] intValue]==2 && [controller.snapshot[@"multiContactFrames"] intValue]==10);
    chooseActions(controller,@{@"swipe":@{@"key":@6,@"modifiers":@(kCGEventFlagMaskCommand)}});
    NSUInteger beforeCapture=postedEvents.count;
    UPSetShortcutCapture(true);
    sendFakeTouches(2,4000,8000);sendFakeTouches(2,4500,8500);
    UPSetShortcutCapture(false);
    sendFakeTouches(2,5000,9000);sendFakeTouches(0,0,0);
    assert(postedEvents.count==beforeCapture && "A gesture recognized during recording cannot play a shortcut later");
    [controller stop];drainMain();chooseActions(controller,@{});
    puts("Compatibility preserves default scroll/magnify, latches actions until lift, and counts decoded pairs.");
}
static void checkShortcutDoesNotReplayAcrossGap(BTTouchController *controller) {
    for(int recording=0;recording<2;recording++){
        resetFakes();assert(startAndServicePen(controller));
        chooseActions(controller,@{@"swipe":@{@"key":@6,@"modifiers":@(kCGEventFlagMaskCommand)}});
        UPSetShortcutCapture(recording!=0);
        sendFakeTouches(2,4000,8000);sendFakeTouches(2,4500,8500);
        unsigned initial=recording?0:2;
        assert(postedEvents.count==initial);
        UPSetShortcutCapture(false);
        forceReportGap(controller);
        sendFakeTouches(2,4500,8500);sendFakeTouches(2,5000,9000);
        assert(postedEvents.count==initial && "Silent watchdog recovery must not replay a shortcut from the same held fingers");
        sendFakeTouches(1,5000,0);sendFakeTouches(2,5000,8000);sendFakeTouches(2,5500,8500);
        assert(postedEvents.count==initial && "Replacing one finger is not a new shortcut sequence");
        sendFakeTouches(0,0,0);
        sendFakeTouches(2,4000,8000);sendFakeTouches(2,4500,8500);sendFakeTouches(0,0,0);
        assert(postedEvents.count==initial+2 && postedEvents.lastObject.type==NSEventTypeKeyUp);
        [controller stop];drainMain();
    }
    chooseActions(controller,@{});
}
static void checkBooleanShortcutPreferencesFallBackToNative(BTTouchController *controller) {
    resetFakes();assert(startAndServicePen(controller));
    NSArray *bindings=@[@{@"key":@YES,@"modifiers":@0},@{@"key":@6,@"modifiers":@NO}];
    for(NSDictionary *binding in bindings){
        NSData *data=[NSPropertyListSerialization dataWithPropertyList:@{@"swipe":binding} format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        chooseActions(controller,[NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL]);
        sendFakeTouches(2,4000,8000);sendFakeTouches(2,4500,8500);sendFakeTouches(0,0,0);
        assert(postedEvents.lastObject.type==NSEventTypeScrollWheel && "A Boolean setting must not generate a key code or modifier mask");
    }
    [controller stop];drainMain();chooseActions(controller,@{});
}
static void vendorPoint(BOOL down,uint16_t x,uint16_t y){
    uint8_t bytes[]={3,down?0x80:0,x&255,x>>8,y&255,y>>8};
    reportCallback(reportContext,0,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,3,bytes,sizeof bytes);
}
static void sendVendorContact(BOOL down){vendorPoint(down,8192,4800);}
static void expectPointer(NSUInteger i,NSEventType type,double x,double y){
    assert(i<postedEvents.count && postedEvents[i].type==type);
    CGPoint p=CGEventGetLocation(postedEvents[i].CGEvent);assert(p.x==x && p.y==y);
}
static void checkNativeVendorPointer(void){
    resetFakes();initialPen=BTPenUnknown;
    BTTouchController *controller=[BTTouchController new];
    assert([controller startWithDisplay:42 postEvents:YES error:NULL]);
    // Synthetic report 3 only, before pen discovery. Real Quartz events, intercepted at post.
    tapAtY(0,3);
    assert(postedDowns==1 && postedUps==1 && "Report-3-only tap was not delivered to the event adapter");
    expectPointer(0,NSEventTypeMouseMoved,-960.5,-1080);
    expectPointer(1,NSEventTypeLeftMouseDown,-960.5,-1080);
    expectPointer(2,NSEventTypeLeftMouseUp,-960.5,-1080);
    sendVendorContact(YES);uptimeOffset+=0.1;[controller tick:nil];
    assert(postedDowns==1); // Holding still is not a press.
    vendorPoint(YES,16384,9600);sendVendorContact(NO);
    assert(postedEvents.count==7 && !penOpenCalls && !nativePenPosts);
    assert([controller.snapshot[@"nativePointerReportID"] isEqual:@3] && [controller.snapshot[@"peakContacts"] isEqual:@0]);
    expectPointer(3,NSEventTypeMouseMoved,-960.5,-540.5);
    expectPointer(4,NSEventTypeLeftMouseDown,-960.5,-540.5);
    expectPointer(5,NSEventTypeLeftMouseDragged,-1,-1);
    expectPointer(6,NSEventTypeLeftMouseUp,-1,-1);
    assert([controller.status containsString:@"report 3"] && [controller.status localizedCaseInsensitiveContainsString:@"pinch"]);
    [controller stop];drainMain();assert(!seizedTouches.count);
    puts("Native report 3 without a pen: direct move/tap at (-960.5,-1080), drag to (-1,-1), balanced release.");
}
static void checkHeldVendorAcrossModeSwitch(void){
    for(int native=0;native<2;native++){
        resetFakes();initialPen=BTPenUnknown;
        BTTouchController *controller=[BTTouchController new];controller.nativeTouchEnabled=native;
        assert(startAndServicePen(controller));sendVendorContact(YES);vendorPoint(YES,16384,9600);
        assert(postedDowns==1 && !postedUps);[controller stop];drainMain();assert(postedUps==1);
        controller.nativeTouchEnabled=!native;assert(startAndServicePen(controller));
        int before=symbolicPosts;
        sendFakeTouches(0,0,0);vendorPoint(YES,16384,9600);sendVendorContact(NO);
        assert(symbolicPosts==before && "Switching modes while held must not replay the previous stroke");
        tapAtY(0,3);assert(postedDowns==2 && postedUps==2);
        [controller stop];drainMain();
    }
}
static void checkNativeSourceTransition(void){
    for(int state=0;state<3;state++){
        resetFakes();initialPen=BTPenUnknown;
        BTTouchController *controller=[BTTouchController new];assert(startAndServicePen(controller));
        sendVendorContact(YES);sendFakeTouches(0,0,0); // Idle report 4 does not terminate the vendor stroke.
        if(state==1)vendorPoint(YES,16384,9600); // Drag in progress.
        if(state==2){sendVendorContact(NO);uptimeOffset+=2;} // Already clicked; late duplicate.
        assert(postedDowns==(state!=0) && postedUps==(state==2));
        sendFakeTouches(1,8000,0);sendVendorContact(NO);
        assert([controller.snapshot[@"nativePointerReportID"] isEqual:@4] && [controller.snapshot[@"activeContacts"] isEqual:@1]);
        sendFakeTouches(1,12000,0);sendFakeTouches(0,0,0);
        assert(postedDowns==(state!=0) && postedUps==postedDowns);
        int before=symbolicPosts;
        uptimeOffset+=2;tapAtY(0,3);assert(symbolicPosts==before); // Silence is not a new source.
        tapAtY(0,4);assert(postedDowns==(state!=0)+1 && postedDowns==postedUps && symbolicPosts==before+3);
        [controller stop];drainMain();
    }
}
// A second finger can arrive after Compatibility's one-finger arming deadline.
static void delayedPair(BTTouchController *controller){
    sendFakeTouches(1,4000,0);uptimeOffset+=0.060;[controller tick:nil];
    sendFakeTouches(1,4000,0);sendFakeTouches(2,4000,8000);sendFakeTouches(2,4500,8500);
    sendFakeTouches(2,3500,9000);sendFakeTouches(1,3500,0);uptimeOffset+=0.150;[controller tick:nil];
    sendFakeTouches(1,9000,0);sendFakeTouches(0,0,0);
}
static void checkNativeInterruptedContacts(void){
    resetFakes();initialPen=BTPenUnknown;
    BTTouchController *controller=[BTTouchController new];assert(startAndServicePen(controller));
    sendFakeTouches(1,8000,0);uptimeOffset+=1; // Late lift beats the watchdog callback.
    sendFakeTouches(0,0,0);assert(!postedDowns && !postedUps && "A silent pending finger must not click on a late lift");
    pressFakeFinger();assert(postedDowns==1 && !postedUps);
    uptimeOffset+=1;sendVendorContact(YES);[controller tick:nil];
    assert(postedUps==1 && [controller.snapshot[@"cancelEvents"] isEqual:@1] && controller.running);
    sendVendorContact(NO);int afterGap=symbolicPosts;
    pressFakeFinger();sendFakeTouches(0,0,0);assert(symbolicPosts==afterGap);
    tapAtY(4800,4);assert(postedDowns==2 && postedUps==2);
    pressFakeFinger();postAccess=NO;[controller tick:nil];drainMain();
    assert(!controller.running && [controller.status containsString:@"Accessibility"] && postedDowns==3 && postedUps==3 && !seizedTouches.count);
}
static void checkNativeUncertainSequences(void){
    for(int malformed=0;malformed<2;malformed++){
        resetFakes();initialPen=BTPenUnknown;pressDuringStartup=!malformed;
        BTTouchController *controller=[BTTouchController new];assert(startAndServicePen(controller));
        if(malformed){
            sendFakeTouches(1,4000,0);
            uint8_t broken[]={4,0};reportCallback(reportContext,0,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,4,broken,sizeof broken);
        }
        sendVendorContact(NO); // Does not clear an incomplete report 4 sequence.
        sendFakeTouches(1,8000,0);sendFakeTouches(0,0,0);
        assert(!postedDowns && !postedUps && "An incomplete sequence is not a solitary touch");
        tapAtY(0,4);assert(postedDowns==1 && postedUps==1);
        [controller stop];drainMain();assert(!seizedTouches.count);
    }
}
static void checkNativeVendorInterruptions(void){
    for(int cause=0;cause<3;cause++){
        resetFakes();initialPen=BTPenUnknown;requirePalmBeforePen=YES;
        BTTouchController *controller=[BTTouchController new];assert(startAndServicePen(controller));
        sendVendorContact(YES);vendorPoint(YES,16384,9600);assert(postedDowns==1 && !postedUps);
        if(cause==0){
            uint8_t broken[]={3,0};
            reportCallback(reportContext,0,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,3,broken,sizeof broken);
        }else if(cause==1){
            uptimeOffset+=1;sendVendorContact(YES); // Resumed contact beats the watchdog.
        }else{
            sendFakePen(BTPenInRange);assert(nativePenPosts && !unprotectedPenPosts);
            sendFakePen(BTPenOutOfRange);uptimeOffset+=31;
        }
        assert(postedDowns==1 && postedUps==1 && [controller.snapshot[@"cancelEvents"] isEqual:@1]);
        NSUInteger before=postedEvents.count;
        sendFakeTouches(0,0,0);sendVendorContact(YES);sendVendorContact(NO);
        assert(postedEvents.count==before && ![seizedTouches containsObject:testCompanion()]);
        tapAtY(0,3);assert(postedDowns==2 && postedUps==2);
        [controller stop];drainMain();
    }
}
static void checkNativeDefault(BTTouchController *controller){
    resetFakes();assert(startAndServicePen(controller));
    controller.nativeTouchEnabled=NO; // Preference applies only to the next start.
    NSDictionary *binding=@{@"key":@6,@"modifiers":@(kCGEventFlagMaskCommand)};
    chooseActions(controller,@{@"swipe":binding,@"pinch":binding});
    assert([controller.snapshot[@"nativeTouchEnabled"] boolValue] && [controller.snapshot[@"gestureReadiness"] intValue]==BTGestureReadinessReady);
    sendVendorContact(YES);delayedPair(controller);sendVendorContact(NO);
    assert(symbolicPosts<=1 && !postedDowns && !postedUps && (!symbolicPosts || postedEvents[0].type==NSEventTypeMouseMoved));
    int before=symbolicPosts;
    sendFakeTouches(2,4000,8000);sendFakeTouches(2,3500,8500);sendVendorContact(NO);
    NSDictionary *snap=controller.snapshot;
    assert([snap[@"activeContacts"] intValue]==2 && [snap[@"peakContacts"] intValue]==2 && [snap[@"multiContactFrames"] intValue]>0);
    NSMutableDictionary *lookalike=[testDigitizer() mutableCopy];
    uint8_t lift[64]={4};
    reportCallback(reportContext,0,(__bridge void *)lookalike,kIOHIDReportTypeInput,4,lift,sizeof lift);
    assert([controller.snapshot[@"activeContacts"] intValue]==2 && [controller.snapshot[@"rawReports"] isEqual:snap[@"rawReports"]]);
    sendFakeTouches(0,0,0);assert([controller.snapshot[@"activeContacts"] intValue]==0 && symbolicPosts==before);
    for(NSString *key in @[@"pointerDown",@"downEvents",@"upEvents",@"dragEvents",@"scrollEvents",@"magnifyEvents",@"cancelEvents",@"postsGestureEvents"])assert([snap[key] isEqual:@0]);
    assert([snap[@"moveEvents"] intValue]==before && [snap[@"postsMouseEvents"] isEqual:@YES] && controller.running);
    // Actual report 4 tap, interleaved with both early and delayed duplicate report 3 lifts.
    sendFakeTouches(1,8000,0);sendVendorContact(YES);sendVendorContact(NO);assert(!postedDowns && !postedUps);
    sendVendorContact(YES);sendFakeTouches(0,0,0);assert(postedDowns==1 && postedUps==1);
    uptimeOffset+=1;sendVendorContact(NO);tapAtY(4800,3);assert(postedDowns==1 && postedUps==1);
    assert([seizedTouches isEqual:[NSSet setWithObject:testDigitizer()]] && !boundaryViolations);
    pressFakeFinger();assert(postedDowns==2 && postedUps==1);
    [controller stop];drainMain();assert(postedUps==2 && !seizedTouches.count && ![controller.snapshot[@"postsMouseEvents"] boolValue]);
    chooseActions(controller,@{});
    resetFakes();assert(startAndServicePen(controller));
    controller.nativeTouchEnabled=YES;
    sendFakeTouches(0,0,0); // Lift the previous Native drag before a fresh Compatibility sequence.
    delayedPair(controller);
    assert(postedDowns==1 && postedUps==1 && [controller.snapshot[@"nativeTouchEnabled"] isEqual:@NO]);
    pressFakeFinger();[controller stop];drainMain();assert(postedDowns==2 && postedUps==2);
    resetFakes();assert(startAndServicePen(controller));
    delayedPair(controller);unplugFakeTouch(testCompanion());drainMain();
    assert(!controller.running && [controller.status containsString:@"disconnected"] && !seizedTouches.count && !scheduledTouches.count && !postedDowns && !postedUps && symbolicPosts<=1);
    puts("Native → Compatibility → Native: 60 ms delayed pair, taps, drag, swipe, pinch, shortcuts, and cleanup verified.");
}
static void checkPalmCompanion(BTTouchController *controller){
    int dragAndCancelPosts=controller.nativeTouchEnabled?4:3; // Native also moves on first contact.
    resetFakes();initialPen=BTPenUnknown;requirePalmBeforePen=YES;
    assert(startAndServicePen(controller));
    assert([controller updateResumeDelay:2]);
    pressFakeFinger();sendVendorContact(YES); // Duplicate stream still reports this palm.
    assert(![seizedTouches containsObject:testCompanion()] && postedDowns==1);
    sendFakePen(BTPenInRange);
    assert([seizedTouches containsObject:testCompanion()] && "Confirmed hover must synchronously seize the paired native companion");
    assert(postedUps==1 && controller.running && nativePenPosts>0 && !unprotectedPenPosts);
    sendFakePen(BTPenInRange);uptimeOffset+=300;[[controller valueForKey:@"penMonitor"] tick:nil];[controller tick:nil];
    assert(openCalls==2 && closeCalls==0 && symbolicPosts==dragAndCancelPosts);
    sendFakePen(BTPenOutOfRange);uptimeOffset+=3;[controller tick:nil];
    sendFakeTouches(0,0,0); // Not proof that report 3 lifted.
    assert(closeCalls==0);sendFakeTouches(2,4000,8000);sendFakeTouches(2,4500,8500);
    assert(symbolicPosts==dragAndCancelPosts);sendVendorContact(NO);
    assert(closeCalls==0);sendFakeTouches(0,0,0);
    assert(closeCalls==1 && ![seizedTouches containsObject:testCompanion()] && controller.running);
    sendFakePen(BTPenInRange);sendFakePen(BTPenOutOfRange);sendFakeTouches(0,0,0);
    uptimeOffset+=1;sendFakePen(BTPenInRange);uptimeOffset+=3;[controller tick:nil];
    assert(openCalls==3 && closeCalls==1);sendFakePen(BTPenOutOfRange);
    uptimeOffset+=1;sendFakePen(BTPenOutOfRange);[controller tick:nil];assert(closeCalls==1);
    uptimeOffset+=1.1; // New contact is the first callback past the deadline; do not hand it to macOS mid-contact.
    sendFakeTouches(1,5000,0);[controller tick:nil];assert(closeCalls==1);
    assert([controller.snapshot[@"gestureReadiness"] intValue]==BTGestureReadinessLiftRequired);
    sendFakeTouches(0,0,0);assert(closeCalls==2);
    sendFakePen(BTPenInRange);sendFakeTouches(0,0,0);
    uint8_t broken[]={4,0};reportCallback(reportContext,0,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,4,broken,sizeof broken);
    sendFakePen(BTPenOutOfRange);uptimeOffset+=5;[controller tick:nil];
    assert(closeCalls==2 && "A malformed exact report is not a clean boundary");
    sendVendorContact(NO);assert(closeCalls==2);sendFakeTouches(0,0,0);assert(closeCalls==3);
    // A verified lift during hover is sufficient when the full delay expires.
    sendFakePen(BTPenInRange);sendFakeTouches(0,0,0);sendFakePen(BTPenOutOfRange);
    uptimeOffset+=2.1;[controller tick:nil];assert(closeCalls==4);
    pressFakeFinger();assert(postedDowns==2 && penOpenCalls==1 && !unprotectedPenPosts);
    [controller stop];drainMain();assert(seizedTouches.count==0);
    assert(postedUps==2);

    resetFakes();initialPen=BTPenInRange;
    requirePalmBeforePen=pressDuringStartup=YES;
    assert(startAndServicePen(controller));
    assert([seizedTouches containsObject:testCompanion()] && nativePenPosts>0 && !unprotectedPenPosts);
    sendFakePen(BTPenOutOfRange);uptimeOffset+=3;sendVendorContact(NO);
    assert([seizedTouches containsObject:testCompanion()] && !symbolicPosts && "Carry startup contacts across initial proximity");
    unplugFakeTouch(testCompanion());drainMain();
    assert(!controller.running && [controller.status containsString:@"disconnected"] && !seizedTouches.count);
    for(int startup=0;startup<2;startup++){
        resetFakes();failTouchOpenService=12;requirePalmBeforePen=YES;initialPen=startup?BTPenInRange:BTPenUnknown;
        NSError *error=nil;BOOL started=[controller startWithDisplay:42 postEvents:YES error:&error];
        drainMain();assert(started && !error && featureWrites==1);if(!startup)sendFakePen(BTPenInRange);
        assert(!controller.running && ![[controller valueForKey:@"penMonitor"] running]);
        assert([controller.status localizedCaseInsensitiveContainsString:@"companion"]);
        drainMain();assert(!seizedTouches.count && closeCalls==1 && !symbolicPosts && !nativePenPosts);
    }
    resetFakes();initialPen=BTPenInRange;assert(startAndServicePen(controller));
    failTouchCloseOnce=12;sendFakeTouches(0,0,0);sendFakePen(BTPenOutOfRange);
    uptimeOffset+=3;[controller tick:nil];assert(!controller.running && [controller.status localizedCaseInsensitiveContainsString:@"release"]);
    drainMain();assert(!seizedTouches.count);
    printf("%s palm guard: synchronous exact claim, silent hover, both contact streams, cooldown, reentry, failures and cleanup passed.\n",controller.nativeTouchEnabled?"Native":"Compatibility");
}
static void checkInputModes(BTTouchController *controller){
    assert(controller.touchInputEnabled && controller.penInputEnabled);
    for(int touch=0;touch<2;touch++)for(int pen=0;pen<2;pen++){
        resetFakes();controller.touchInputEnabled=touch;controller.penInputEnabled=pen;
        chooseActions(controller,@{@"swipe":@{@"key":@6,@"modifiers":@0}});
        assert(startAndServicePen(controller));
        NSSet *expected=touch?[NSSet setWithObject:testDigitizer()]:[NSSet setWithObjects:testDigitizer(),testCompanion(),nil];
        assert(boundaryViolations==0 && touchOpenAttempts.count==expected.count && [[NSSet setWithArray:touchOpenAttempts] isEqual:expected]);
        assert([[controller valueForKey:@"penMonitor"] penInputEnabled]==(BOOL)pen && penOpenCalls==1);
        assert(featureReads==touch && featureWrites==touch && (!touch || writtenDevice==(__bridge IOHIDDeviceRef)testDigitizer()));
        sendFakePen(BTPenInRange);
        if(!touch){
            // There is no live report subscription; drive the same callback anyway
            // to verify even a queued tap, swipe or pinch cannot escape the mute.
            assert(!reportCallback);reportCallback=received;reportContext=(__bridge void *)controller;
            tapAtY(0,3);vendorPoint(YES,8192,4800);vendorPoint(YES,16384,9600);sendVendorContact(NO);
        }
        tapAtY(2000,4);sendFakeTouches(2,4000,8000);sendFakeTouches(2,4500,8500);sendFakeTouches(0,0,0);
        sendFakeTouches(2,4000,8000);sendFakeTouches(2,3500,8500);sendFakeTouches(0,0,0);
        [controller tick:nil];assert(controller.running);
        if(touch && !pen && !controller.nativeTouchEnabled)assert(postedDowns==1 && postedUps==1 && postedEvents[3].type==NSEventTypeKeyUp && postedEvents.lastObject.type==NSEventTypeMagnify);
        else if(touch && !pen)assert(symbolicPosts==3 && postedDowns==1 && postedUps==1);
        else assert(symbolicPosts==0);
        assert(pen?(nativePenPosts>0):(nativePenPosts==0));
        NSSet *held=touch && !pen?[NSSet setWithObject:testDigitizer()]:[NSSet setWithObjects:testDigitizer(),testCompanion(),nil];
        assert([seizedTouches isEqual:held]);
        [controller stop];drainMain();assert(!seizedTouches.count && [[NSSet setWithArray:touchClosed] isEqual:held]);
    }
    for(int touch=0;touch<2;touch++)for(int pen=0;pen<2;pen++){
        resetFakes();controller.touchInputEnabled=touch;controller.penInputEnabled=pen;
        removeDuringSchedule=ReviewGetService((__bridge IOHIDDeviceRef)(touch?testDigitizer():testCompanion()));
        NSError *error=nil;assert(![controller startWithDisplay:42 postEvents:YES error:&error] && error && !controller.running);
        drainMain();assert(!seizedTouches.count && !scheduledTouches.count && penOpenCalls==penCloseCalls && !featureWrites);
    }
    chooseActions(controller,@{});
}
static void checkInvalidTouchSelection(BTTouchController *controller){
    CFSetRef saved=fakeDevices;
    for(int both=0;both<2;both++)for(int variant=0;variant<11;variant++){
        resetFakes();controller.touchInputEnabled=both;
        NSMutableDictionary *digitizer=[testDigitizer() mutableCopy],*mouse=[testCompanion() mutableCopy];
        NSMutableSet *inventory=[NSMutableSet set];
        switch(variant){
            case 0: break; // missing companion
            case 1: parents[@22]=@32;usbNodes[@32]=usbNodes[@31];break; // other physical device, even with cloned location
            case 2: mouse[@kIOHIDLocationIDKey]=@42;break;
            case 3: [mouse removeObjectForKey:@kIOHIDLocationIDKey];break;
            case 4: mouse[@kIOHIDTransportKey]=@"Bluetooth";break;
            case 5: [parents removeObjectForKey:@21];break;
            case 6: usbNodes[@31]=@{@"idVendor":@1,@"idProduct":@1,@"locationID":@0x12340000};break;
            case 7: {NSMutableDictionary *extra=[mouse mutableCopy];extra[@"service"]=@13;[inventory addObject:extra];break;}
            case 8: {NSMutableDictionary *extra=[digitizer mutableCopy];extra[@"service"]=@13;[inventory addObject:extra];controller.touchInputEnabled=YES;break;}
            case 9: digitizer[@kIOHIDTransportKey]=@"Virtual";controller.touchInputEnabled=YES;break;
            case 10: usbInterfaces[@22]=@{@"bInterfaceNumber":@5};break; // unrelated mouse function on the composite device

        }
        [inventory addObject:digitizer];if(variant)[inventory addObject:mouse];
        fakeDevices=(__bridge_retained CFSetRef)inventory;NSError *error=nil;
        assert(![controller startWithDisplay:42 postEvents:YES error:&error] && error && !controller.running);
        drainMain();assert(!openCalls && !penOpenCalls && !featureWrites && !symbolicPosts);
        CFRelease(fakeDevices);
    }
    fakeDevices=saved;resetFakes();controller.touchInputEnabled=NO;failTouchOpenService=12;
    assert(![controller startWithDisplay:42 postEvents:YES error:NULL]);drainMain();
    assert(!controller.running && !featureWrites && !symbolicPosts && [touchClosed containsObject:testDigitizer()]);
    resetFakes();assert(startAndServicePen(controller));
    unplugFakeTouch(testCompanion());
    drainMain();assert(!controller.running && touchClosed.count==2 && !symbolicPosts);
    controller.touchInputEnabled=YES;controller.penInputEnabled=YES;
}
static void checkEarliestStartupHover(void) {
    for(int fail=0;fail<2;fail++){
        resetFakes();hoverDuringPenSchedule=requirePalmBeforePen=YES;
        if(fail)failTouchOpenService=12;
        BTTouchController *controller=[BTTouchController new];NSError *error=nil;
        BOOL started=[controller startWithDisplay:42 postEvents:YES error:&error];
        drainMain();if(fail)assert(started && !error && !controller.running && [controller.status containsString:@"companion"] && !nativePenPosts && featureWrites==1);
        else assert(started && nativePenPosts && !unprotectedPenPosts && [controller.snapshot[@"palmCompanionHeld"] boolValue] &&
                    [controller.snapshot[@"penObserver"][@"presence"] isEqual:@"inRange"]);
        [controller stop];drainMain();assert(!seizedTouches.count && penCloseCalls==1);
    }
}
static void checkLaunchCandidate(void) {
    resetFakes();penInventory=nil;
    NSArray *candidate=BTTabletRegistryIdentity();
    assert(candidate.count && [candidate isEqual:BTTabletRegistryIdentity()] && "Stable touch-only launch identity required");
    penInventory=[NSSet setWithObject:fakePen];assert([candidate isEqual:BTTabletRegistryIdentity()]);
    unreadableRegistryID=41;assert([candidate isEqual:BTTabletRegistryIdentity()]);unreadableRegistryID=0;
    [parents removeObjectForKey:@41];assert([candidate isEqual:BTTabletRegistryIdentity()]);
    resetFakes();penInventory=nil;[parents removeObjectForKey:@11];assert(!BTTabletRegistryIdentity());
    resetFakes();NSMutableDictionary *extra=[fakePen mutableCopy];extra[@"service"]=@42;
    penInventory=[NSSet setWithObjects:fakePen,extra,nil];assert([candidate isEqual:BTTabletRegistryIdentity()]);
    assert(!openCalls && !penOpenCalls && !featureReads && !featureWrites && !boundaryViolations);
}
static void checkTouchFirstStartup(void) {
    for(int mode=0;mode<3;mode++)for(int pen=0;pen<2;pen++){
        resetFakes();penInventory=nil;
        BTTouchController *controller=[BTTouchController new];
        controller.touchInputEnabled=mode!=0;controller.nativeTouchEnabled=mode!=2;controller.penInputEnabled=pen;
        assert(startAndServicePen(controller) && "An absent pen cannot block exact touch startup");
        NSArray *candidate=BTTabletRegistryIdentity();assert(candidate.count && [candidate isEqual:BTTabletRegistryIdentity()]);
        NSDictionary *observer=controller.snapshot[@"penObserver"];
        assert([observer[@"waitingForDevice"] isEqual:@YES] && [observer[@"seized"] isEqual:@NO] && !penOpenCalls && !nativePenPosts);
        assert([controller.snapshot[@"penAccessed"] isEqual:@NO] && "Waiting for hardware is not accessing a pen");
        assert(featureWrites==(mode!=0) && [seizedTouches containsObject:testCompanion()]==(mode==0));
        if(mode){tapAtY(2000,4);assert(postedDowns==1 && postedUps==1);}
        else assert(!reportCallback && !featureReads);
        id originalMonitor=[controller valueForKey:@"penMonitor"];
        penInventory=[NSSet setWithObject:fakePen];
        assert(penAddedCallback);penAddedCallback(penAddedContext,0,NULL,(__bridge IOHIDDeviceRef)fakePen);
        assert([candidate isEqual:BTTabletRegistryIdentity()] && "A pen-only disconnect cannot change the automatic retry key");
        assert(controller.running && [controller valueForKey:@"penMonitor"]==originalMonitor && penOpenCalls==1 && closeCalls==0 && featureWrites==(mode!=0));
        observer=controller.snapshot[@"penObserver"];
        assert([controller.snapshot[@"penAccessed"] isEqual:@YES] && [controller.snapshot[@"penSeized"] isEqual:@YES]);
        assert([observer[@"waitingForDevice"] isEqual:@NO] && [observer[@"seized"] isEqual:@YES] && [observer[@"reports"] isEqual:@0]);
        uptimeOffset+=60;[controller tick:nil];[originalMonitor tick:nil];assert(controller.running && !nativePenPosts);
        if(mode){assert(![seizedTouches containsObject:testCompanion()]);pressFakeFinger();}
        requirePalmBeforePen=YES;sendFakePen(BTPenInRange);
        assert(controller.running && !boundaryViolations && !unprotectedPenPosts && (nativePenPosts!=0)==(pen!=0));
        assert([seizedTouches containsObject:testCompanion()]==(!mode || pen));
        if(!mode){reportCallback=received;reportContext=(__bridge void *)controller;tapAtY(2000,4);assert(!symbolicPosts);}
        if(mode && pen)assert(postedDowns==2 && postedUps==2);
        unplugFakeTouch(fakePen);assert(!controller.running);drainMain();
        assert(!seizedTouches.count && penCloseCalls==1);
        penInventory=nil;assert([candidate isEqual:BTTabletRegistryIdentity()]);
    }
    puts("Absent pen: exact touch starts, mute is preserved, late silent pen attaches in place, first hover guards touch.");
}
static void checkIndependentPenStartup(void) {
    for(int native=0;native<2;native++)for(int scenario=0;scenario<4;scenario++){
        resetFakes();BTTouchController *controller=[BTTouchController new];controller.nativeTouchEnabled=native;
        if(scenario==0)penOpenResult=kIOReturnExclusiveAccess;
        if(scenario==1)unreadableRegistryID=41;
        if(scenario==2)penInventory=nil;
        __block BOOL observed=NO;
        beforePenDiscovery=^{
            observed=YES;
            assert(controller.running && featureReads==1 && featureWrites==1 && reportCallback && !penOpenCalls && "Touch initialized before pen discovery");

        };
        NSError *error=nil;assert([controller startWithDisplay:42 postEvents:YES error:&error] && !error);
        assert(!observed && controller.running && !penOpenCalls && "Touch start must return before pen discovery");
        tapAtY(0,4);assert(postedDowns==1 && postedUps==1 && [controller.snapshot[@"validFrames"] intValue]==2);
        if(native){
            assert(postedEvents.count==3 && postedEvents[0].type==NSEventTypeMouseMoved &&
                   postedEvents[1].type==NSEventTypeLeftMouseDown && postedEvents[2].type==NSEventTypeLeftMouseUp);
            for(NSEvent *event in postedEvents){CGPoint p=CGEventGetLocation(event.CGEvent);assert(p.x==-960.5 && p.y==-1080);}
            pressFakeFinger();assert(postedEvents.lastObject.type==NSEventTypeLeftMouseDragged && postedDowns==2 && postedUps==1);
            CGPoint p=CGEventGetLocation(postedEvents.lastObject.CGEvent);assert(p.x>-960.5 && p.y==-540.5);
            sendFakeTouches(0,0,0);assert(postedUps==2);
        }
        drainMain();beforePenDiscovery=nil;assert(observed);
        NSDictionary *s=controller.snapshot,*p=s[@"penObserver"];
        assert([s[@"touchRunningWithoutPen"] isEqual:@(scenario<2)] && [p[@"seized"] isEqual:@(scenario==3)]);
        assert([p[@"waitingForDevice"] isEqual:@(scenario==2)] && [p[@"presence"] isEqual:@"unknown"]);
        assert(penOpenCalls==(scenario==0 || scenario==3) && ![s[@"palmCompanionHeld"] boolValue] && !nativePenPosts && !boundaryViolations);
        if(scenario<2){
            BTPenMonitor *monitor=[controller valueForKey:@"penMonitor"];
            penOpenResult=kIOReturnSuccess;unreadableRegistryID=0;uptimeOffset+=60;[monitor tick:nil];
            assert(controller.running && [controller.snapshot[@"penSeized"] boolValue] && ![controller.snapshot[@"touchRunningWithoutPen"] boolValue]);
            assert(featureWrites==1 && !closeCalls && !nativePenPosts);
            requirePalmBeforePen=YES;sendFakePen(BTPenInRange);assert(nativePenPosts && !unprotectedPenPosts);
            unplugFakeTouch(fakePen);assert(!controller.running);
        }
        [controller stop];drainMain();assert(![controller.snapshot[@"touchRunningWithoutPen"] boolValue] && !seizedTouches.count);
    }
    puts("Touch initialized and processing before pen discovery: busy, unverified, absent, and owned/no report. Late recovery preserved touch.");
}
static void checkDiscoveryBoundaries(void) {
    BTTouchController *controller=[BTTouchController new];
    resetFakes();beforePenDiscovery=^{unplugFakeTouch(testDigitizer());};
    assert([controller startWithDisplay:42 postEvents:YES error:NULL]);drainMain();
    assert(!controller.running && !penOpenCalls && !nativePenPosts && "Touch removal during pen discovery revokes authority to attach");
    drainMain();
    resetFakes();assert([controller startWithDisplay:42 postEvents:YES error:NULL]);
    [controller stop];drainMain();assert(!penOpenCalls && !seizedTouches.count);
    resetFakes();firmwareReply[2]=25;assert(![controller startWithDisplay:42 postEvents:YES error:NULL]);
    drainMain();assert(!penOpenCalls && !featureWrites && ![controller.snapshot[@"touchRunningWithoutPen"] boolValue]);
    resetFakes();duringPenOpen=^{
        duringPenOpen=nil;penAddedCallback(penAddedContext,0,NULL,(__bridge IOHIDDeviceRef)fakePen);
    };
    assert(startAndServicePen(controller) && penOpenCalls==1 && "A matching callback during open cannot claim twice");
    [controller stop];drainMain();assert(penCloseCalls==1);
    resetFakes();penOpenResult=kIOReturnExclusiveAccess;assert(startAndServicePen(controller));
    BTPenMonitor *monitor=[controller valueForKey:@"penMonitor"];
    for(int i=0;i<20;i++){
        penAddedCallback(penAddedContext,0,NULL,(__bridge IOHIDDeviceRef)fakePen);
        uptimeOffset+=60;[monitor tick:nil];
    }
    assert(controller.running && penOpenCalls==4 && !penCloseCalls && !nativePenPosts && featureWrites==1);
    // Exhausted retries must not hide an inventory change: removal of an
    // ambiguous sibling can expose the sole verified survivor without a new add.
    [controller stop];drainMain();resetFakes();
    NSMutableDictionary *other=[fakePen mutableCopy];other[@"service"]=@42;
    penInventory=[NSSet setWithObjects:fakePen,other,nil];assert(startAndServicePen(controller));
    monitor=[controller valueForKey:@"penMonitor"];
    for(int i=0;i<10;i++){uptimeOffset+=60;[monitor tick:nil];}
    assert(!penOpenCalls && [controller.snapshot[@"touchRunningWithoutPen"] boolValue]);
    penInventory=[NSSet setWithObject:fakePen];penRemovedCallback(penRemovedContext,0,NULL,(__bridge IOHIDDeviceRef)other);
    assert(penOpenCalls==1 && controller.running && !closeCalls && featureWrites==1 && !nativePenPosts);
    [controller stop];drainMain();
    puts("Security failures stop touch; busy retry cap, cancellation and removal-driven late attachment verified.");
}
int main(void) { @autoreleasepool {
    createFakeDevices();checkNativeVendorPointer();checkNativeSourceTransition();checkHeldVendorAcrossModeSwitch();
    checkNativeUncertainSequences();checkNativeInterruptedContacts();checkNativeVendorInterruptions();
    checkDiscoveryBoundaries();checkIndependentPenStartup();checkLaunchCandidate();checkTouchFirstStartup();checkEarliestStartupHover();resetFakes();
    BTTouchController *controller=[BTTouchController new];NSError *error=nil;
    assert(startAndServicePen(controller));
    assert([controller.snapshot[@"interfaces"] unsignedIntValue]==1 && "Exclusive open must leave the native gesture companion to macOS");
    assert(boundaryViolations==0 && writtenDevice && property(writtenDevice,kIOHIDPrimaryUsagePageKey)==13);
    [controller stop];drainMain();
    resetFakes();controller.penInputEnabled=NO;
    usbInterfaces[@22]=@{@"bInterfaceNumber":@5}; // Mouse on the same tablet, not the native companion.
    assert(![controller startWithDisplay:42 postEvents:YES error:&error] && error && !controller.running && "Native touch alone requires its verified companion");
    drainMain();assert(!openCalls && !penOpenCalls && !featureWrites && !symbolicPosts);
    checkNativeDefault(controller);
    controller.penInputEnabled=YES;
    checkPalmCompanion(controller);checkInputModes(controller);checkInvalidTouchSelection(controller);
    controller.nativeTouchEnabled=NO; // Original v0.1.16 synthetic regression suite.
    checkPalmCompanion(controller);checkInputModes(controller);checkInvalidTouchSelection(controller);
    puts("All four input modes, exact pinned claims, USB pairing rejection and partial-open cleanup passed.");
    checkVerticalOrientation(controller);checkTouchReportRecovery(controller);checkPassivePairRecovery(controller);checkGestureActions(controller);
    checkShortcutDoesNotReplayAcrossGap(controller);checkBooleanShortcutPreferencesFallBackToNative(controller);
    puts("No shortcut replay across a report gap; Boolean preferences retain native output.");resetFakes();
    BOOL started=[controller startWithDisplay:42 postEvents:NO error:&error];
    assert(!started && error && openCalls==0 && penOpenCalls==0 && symbolicPosts==0 && featureReads==0 && featureWrites==0);
    // A silent pen at startup is not an in-range pen. First proximity must
    // cancel any held touch and only a fresh contact after exit may press again.
    resetFakes();initialPen=BTPenUnknown;
    assert(startAndServicePen(controller));
    [controller setValue:@(NSProcessInfo.processInfo.systemUptime-60) forKey:@"lastFrameAt"];
    [controller tick:nil];pressFakeFinger();
    assert(postedDowns==1 && postedUps==0 && controller.running);
    sendFakePen(BTPenInRange);
    assert(postedUps==1 && controller.running);
    sendFakeTouches(0,0,0);pressFakeFinger();assert(postedDowns==1);
    sendFakePen(BTPenOutOfRange);assert([controller updateResumeDelay:0]);
    pressFakeFinger();assert(postedDowns==1);
    sendFakeTouches(0,0,0);pressFakeFinger();assert(postedDowns==2 && openCalls==2 && penOpenCalls==1);
    [controller stop];drainMain();assert([controller updateResumeDelay:2]);
    // Existing fake controller exercises pending, dragging, scroll and pinch loss.
    for(int mode=0;mode<4;mode++) {
        resetFakes();assert(startAndServicePen(controller));
        if(mode==0)sendFakeTouches(1,8000,0);
        if(mode==1)pressFakeFinger();
        if(mode>=2){sendFakeTouches(2,8000,12000);sendFakeTouches(2,mode==2?10000:6000,14000);}
        IOHIDReportCallback savedCallback=reportCallback;void *savedContext=reportContext;
        id savedMonitor=[controller valueForKey:@"penMonitor"];
        int beforePosts=symbolicPosts,beforeUps=postedUps;
        NSUInteger beforeCancels=[controller.snapshot[@"cancelEvents"] unsignedIntegerValue];
        [controller setValue:@(NSProcessInfo.processInfo.systemUptime-1) forKey:@"lastFrameAt"];
        [controller tick:nil];drainMain();
        fprintf(stderr,"touch silence mode %d: running=%d closes=%d ups=%d cancels=%lu\n",mode,controller.running,closeCalls,postedUps-beforeUps,(unsigned long)([controller.snapshot[@"cancelEvents"] unsignedIntegerValue]-beforeCancels));
        assert(controller.running && closeCalls==0 && penCloseCalls==0 && openCalls==1 && penOpenCalls==1);
        assert(reportCallback==savedCallback && reportContext==savedContext && [controller valueForKey:@"penMonitor"]==savedMonitor);
        assert([controller.snapshot[@"gestureReadiness"] intValue]==BTGestureReadinessLiftRequired);
        assert([controller.snapshot[@"cancelEvents"] unsignedIntegerValue]==beforeCancels+(mode==0?0:1));
        assert(symbolicPosts==beforePosts+(mode==0?0:1));
        int cancelledPosts=symbolicPosts;
        for(int i=0;i<3;i++){[controller tick:nil];sendFakeTouches(mode>=2?2:1,10000,14000);}
        assert(symbolicPosts==cancelledPosts && controller.running);
        uint8_t otherStreamUp[6]={3,0,0,0,0,0};
        reportCallback(reportContext,0,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,3,otherStreamUp,6);
        // An ignored report 3 release cannot rearm a stale single finger or
        // terminate the restored, still-stationary report 4 pair.
        assert([controller.snapshot[@"gestureMode"] intValue]==(mode>=2?BTGestureTwoPending:BTGestureBlocked));
        assert([controller.snapshot[@"activeReportID"] intValue]==4 && symbolicPosts==cancelledPosts);
        sendFakeTouches(0,0,0);[controller tick:nil];
        assert([controller.snapshot[@"gestureReadiness"] intValue]==BTGestureReadinessReady);
        [controller setValue:@(NSProcessInfo.processInfo.systemUptime-10) forKey:@"lastFrameAt"];
        [controller tick:nil];assert(controller.running && symbolicPosts==cancelledPosts);
        pressFakeFinger();assert(postedDowns==(mode==1?2:1) && controller.running && openCalls==1);
        [controller stop];drainMain();
    }
    puts("Touch silence cancels pending/drag/scroll/pinch once; a stationary pair or stale single finger cannot post new output.");
    resetFakes();
    // A monitor failure must close both streams even without the app delegate.
    assert(startAndServicePen(controller));pressFakeFinger();
    id monitor=[controller valueForKey:@"penMonitor"];
    [NSNotificationCenter.defaultCenter postNotificationName:@"UnifiedPenFailed" object:monitor userInfo:@{@"reason":@"Held-tip report timeout"}];
    assert(!controller.running && closeCalls==0 && postedUps==0);drainMain();
    assert(!controller.running && closeCalls==1 && penCloseCalls==1 && postedUps==1);
    [controller stop];drainMain();
    resetFakes();assert(startAndServicePen(controller));pressFakeFinger();
    unplugFakeTouch(testDigitizer());
    assert(!controller.running && closeCalls==0 && postedUps==0);
    NSString *reason=controller.status;assert(![controller startWithDisplay:42 postEvents:YES error:NULL]);
    int oldPosts=symbolicPosts;pressFakeFinger();assert(symbolicPosts==oldPosts);
    drainMain();assert(closeCalls==1 && postedUps==1 && [controller.status isEqual:reason]);
    unpluggedDevice=NULL; // Reconnected before explicit restart.
    assert(startAndServicePen(controller));drainMain();assert(controller.running);
    [controller stop];drainMain();CFRelease(fakeDevices);
    puts("Unified observe entry rejected before device opens, writes or posting (fake hardware).");
}return 0;}
