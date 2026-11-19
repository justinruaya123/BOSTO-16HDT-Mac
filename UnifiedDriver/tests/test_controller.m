// Existing offline hardware fixture, exercising the unified-only controller guard.
#define BT_UNIFIED_DRIVER 1
#import "../../Multitouch/tests/hardware_fakes.h"
#include <assert.h>
static void drainMain(void) {
    __block bool done=false;dispatch_async(dispatch_get_main_queue(),^{done=true;});
    double until=CFAbsoluteTimeGetCurrent()+1;
    while(!done && CFAbsoluteTimeGetCurrent()<until)CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
    assert(done);
}
int main(void) { @autoreleasepool {
    createFakeDevices();resetFakes();
    BTTouchController *controller=[BTTouchController new];NSError *error=nil;
    BOOL started=[controller startWithDisplay:42 postEvents:NO error:&error];
    assert(!started && error && openCalls==0 && penOpenCalls==0 && symbolicPosts==0 && featureReads==0 && featureWrites==0);
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
        assert([controller.snapshot[@"gestureReadiness"] intValue]==BTGestureReadinessLiftRequired);
        assert([controller.snapshot[@"activeReportID"] intValue]==4 && symbolicPosts==cancelledPosts);
        sendFakeTouches(0,0,0);[controller tick:nil];
        assert([controller.snapshot[@"gestureReadiness"] intValue]==BTGestureReadinessReady);
        [controller setValue:@(NSProcessInfo.processInfo.systemUptime-10) forKey:@"lastFrameAt"];
        [controller tick:nil];assert(controller.running && symbolicPosts==cancelledPosts);
        pressFakeFinger();assert(postedDowns==(mode==1?2:1) && controller.running && openCalls==1);
        [controller stop];drainMain();
    }
    puts("Touch silence cancels pending/drag/scroll/pinch once, blocks held contacts and rearms on real empty frame.");
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
