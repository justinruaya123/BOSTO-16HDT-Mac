// Existing offline hardware fixture, exercising the unified-only controller guard.
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
    resetFakes();assert([controller startWithDisplay:42 postEvents:YES error:NULL]);
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
    resetFakes();assert([controller startWithDisplay:42 postEvents:YES error:NULL]);
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
        resetFakes();assert([controller startWithDisplay:42 postEvents:YES error:NULL]);
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
            sendFakeTouches(0,0,0);sendFakeTouches(2,4000,8000);sendFakeTouches(2,4500,8500);
        }
        assert(postedEvents.lastObject.type==NSEventTypeScrollWheel && postedEvents.lastObject.phase==NSEventPhaseChanged);
        forceReportGap(controller);
        assert(postedEvents.lastObject.phase==NSEventPhaseCancelled);
        sendFakeTouches(2,4000,8000);sendFakeTouches(2,3500,8500);
        assert(postedEvents.lastObject.type==NSEventTypeMagnify && postedEvents.lastObject.phase==NSEventPhaseChanged);
        assert(postedDowns==0 && postedUps==0 && controller.running && openCalls==1 && penOpenCalls==1);
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
    resetFakes();assert([controller startWithDisplay:42 postEvents:YES error:NULL]);
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
    puts("Gesture settings preserve native defaults, latch action until lift, and count decoded contact pairs.");
}
static void checkShortcutDoesNotReplayAcrossGap(BTTouchController *controller) {
    for(int recording=0;recording<2;recording++){
        resetFakes();assert([controller startWithDisplay:42 postEvents:YES error:NULL]);
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
    resetFakes();assert([controller startWithDisplay:42 postEvents:YES error:NULL]);
    NSArray *bindings=@[@{@"key":@YES,@"modifiers":@0},@{@"key":@6,@"modifiers":@NO}];
    for(NSDictionary *binding in bindings){
        NSData *data=[NSPropertyListSerialization dataWithPropertyList:@{@"swipe":binding} format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        chooseActions(controller,[NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL]);
        sendFakeTouches(2,4000,8000);sendFakeTouches(2,4500,8500);sendFakeTouches(0,0,0);
        assert(postedEvents.lastObject.type==NSEventTypeScrollWheel && "A Boolean setting must not generate a key code or modifier mask");
    }
    [controller stop];drainMain();chooseActions(controller,@{});
}
int main(void) { @autoreleasepool {
    createFakeDevices();resetFakes();
    BTTouchController *controller=[BTTouchController new];NSError *error=nil;
    assert([controller startWithDisplay:42 postEvents:YES error:NULL]);
    assert([controller.snapshot[@"interfaces"] unsignedIntValue]==1 && "Exclusive open must leave the native gesture companion to macOS");
    assert(boundaryViolations==0 && writtenDevice && property(writtenDevice,kIOHIDPrimaryUsagePageKey)==13);
    [controller stop];drainMain();
    checkVerticalOrientation(controller);checkTouchReportRecovery(controller);checkPassivePairRecovery(controller);checkGestureActions(controller);
    checkShortcutDoesNotReplayAcrossGap(controller);checkBooleanShortcutPreferencesFallBackToNative(controller);
    puts("No shortcut replay across a report gap; Boolean preferences retain native output.");resetFakes();
    BOOL started=[controller startWithDisplay:42 postEvents:NO error:&error];
    assert(!started && error && openCalls==0 && penOpenCalls==0 && symbolicPosts==0 && featureReads==0 && featureWrites==0);
    // A silent pen at startup is not an in-range pen. First proximity must
    // cancel any held touch and only a fresh contact after exit may press again.
    resetFakes();initialPen=BTPenUnknown;
    assert([controller startWithDisplay:42 postEvents:YES error:NULL]);
    [controller setValue:@(NSProcessInfo.processInfo.systemUptime-60) forKey:@"lastFrameAt"];
    [controller tick:nil];pressFakeFinger();
    assert(postedDowns==1 && postedUps==0 && controller.running);
    sendFakePen(BTPenInRange);
    assert(postedUps==1 && controller.running);
    sendFakeTouches(0,0,0);pressFakeFinger();assert(postedDowns==1);
    sendFakePen(BTPenOutOfRange);assert([controller updateResumeDelay:0]);
    pressFakeFinger();assert(postedDowns==1);
    sendFakeTouches(0,0,0);pressFakeFinger();assert(postedDowns==2 && openCalls==1 && penOpenCalls==1);
    [controller stop];drainMain();assert([controller updateResumeDelay:2]);
    // Existing fake controller exercises pending, dragging, scroll and pinch loss.
    for(int mode=0;mode<4;mode++) {
        resetFakes();assert([controller startWithDisplay:42 postEvents:YES error:NULL]);
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
    assert([controller startWithDisplay:42 postEvents:YES error:NULL]);pressFakeFinger();
    id monitor=[controller valueForKey:@"penMonitor"];
    [NSNotificationCenter.defaultCenter postNotificationName:@"UnifiedPenFailed" object:monitor userInfo:@{@"reason":@"Held-tip report timeout"}];
    assert(!controller.running && closeCalls==0 && postedUps==0);drainMain();
    assert(!controller.running && closeCalls==1 && penCloseCalls==1 && postedUps==1);
    [controller stop];drainMain();
    resetFakes();assert([controller startWithDisplay:42 postEvents:YES error:NULL]);pressFakeFinger();
    removedCallback(removedContext,0,NULL,(__bridge IOHIDDeviceRef)testDigitizer());
    assert(!controller.running && closeCalls==0 && postedUps==0);
    NSString *reason=controller.status;assert(![controller startWithDisplay:42 postEvents:YES error:NULL]);
    int oldPosts=symbolicPosts;pressFakeFinger();assert(symbolicPosts==oldPosts);
    drainMain();assert(closeCalls==1 && postedUps==1 && [controller.status isEqual:reason]);
    assert([controller startWithDisplay:42 postEvents:YES error:NULL]);drainMain();assert(controller.running);
    [controller stop];drainMain();CFRelease(fakeDevices);
    puts("Unified observe entry rejected before device opens, writes or posting (fake hardware).");
}return 0;}
