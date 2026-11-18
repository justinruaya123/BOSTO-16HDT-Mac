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
