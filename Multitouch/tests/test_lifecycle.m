// Tests real production lifecycle logic behind a fake hardware boundary. No HID access or real clicks.
#import "hardware_fakes.h"
static int checks, failures;
#define CHECK(x) do {checks++;if(!(x)){failures++;fprintf(stderr,"line %d: FAIL %s\n",__LINE__,#x);}}while(0)
static BTTouchController *startHeld(void) {
    resetFakes();BTTouchController *controller=[BTTouchController new];
    CHECK([controller startWithDisplay:42 postEvents:YES error:NULL]);pressFakeFinger();
    CHECK([controller.snapshot[@"pointerDown"] boolValue]);CHECK(postedDowns==1);return controller;
}
static void releasedAndClosed(BTTouchController *controller) {
    CHECK(!controller.running);CHECK(![controller.snapshot[@"pointerDown"] boolValue]);CHECK(postedUps==1);CHECK(closeCalls==1);
    CHECK(penOpenCalls==1);CHECK(penCloseCalls==1);CHECK(boundaryViolations==0);
    [controller stop];CHECK(postedUps==1);CHECK(closeCalls==1);
}
int main(void) { @autoreleasepool {
    createFakeDevices();
    BTTouchController *controller=startHeld();listenAccess=kIOHIDAccessTypeDenied;[controller tick:nil];
    CHECK([controller.status rangeOfString:@"Input Monitoring"].location!=NSNotFound);releasedAndClosed(controller);
    controller=startHeld();[controller setValue:@(NSProcessInfo.processInfo.systemUptime-0.6) forKey:@"lastFrameAt"];[controller tick:nil];
    CHECK([controller.status rangeOfString:@"timeout"].location!=NSNotFound);releasedAndClosed(controller);
    controller=startHeld();removedCallback(removedContext,kIOReturnSuccess,NULL,(__bridge IOHIDDeviceRef)testDigitizer());releasedAndClosed(controller);
    controller=startHeld();displayActive=NO;[controller tick:nil];releasedAndClosed(controller);
    // The vendor's six-byte report3 must reach the actual production dispatcher.
    resetFakes();controller=[BTTouchController new];CHECK([controller startWithDisplay:42 postEvents:YES error:NULL]);
    uint8_t single[6]={3,0x80,0x00,0x20,0xc0,0x12};
    reportCallback(reportContext,kIOReturnSuccess,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,3,single,6);
    CHECK(![controller.snapshot[@"pointerDown"] boolValue]);CHECK(postedDowns==0);CHECK([controller.snapshot[@"validFrames"] unsignedIntegerValue]==1);
    single[1]=0;reportCallback(reportContext,kIOReturnSuccess,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,3,single,6);
    CHECK(![controller.snapshot[@"pointerDown"] boolValue]);CHECK(postedDowns==1);CHECK(postedUps==1);[controller stop];

    // Unknown reports are diagnostic evidence, not accepted touch frames.
    resetFakes();controller=[BTTouchController new];CHECK([controller startWithDisplay:42 postEvents:YES error:NULL]);
    uint8_t unknown[1]={99};reportCallback(reportContext,kIOReturnSuccess,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,99,unknown,1);
    CHECK([controller.snapshot[@"rawReports"] unsignedIntegerValue]==1);CHECK([controller.snapshot[@"rawReportIDs"][@"99"] unsignedIntegerValue]==1);
    CHECK([controller.snapshot[@"validFrames"] unsignedIntegerValue]==0);CHECK(postedDowns==0);[controller stop];

    // Simultaneous vendor3/multitouch4 streams must not prematurely lift a finger.
    resetFakes();controller=[BTTouchController new];CHECK([controller startWithDisplay:42 postEvents:YES error:NULL]);
    single[1]=0x80;reportCallback(reportContext,kIOReturnSuccess,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,3,single,6);
    single[2]=0x40;reportCallback(reportContext,kIOReturnSuccess,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,3,single,6);
    pressFakeFinger();CHECK(postedDowns==1);CHECK(postedUps==0);CHECK([controller.snapshot[@"activeReportID"] unsignedIntValue]==3);
    single[1]=0;reportCallback(reportContext,kIOReturnSuccess,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,3,single,6);
    CHECK(postedUps==1);CHECK(![controller.snapshot[@"pointerDown"] boolValue]);[controller stop];

    // Report4 takes over when report3 cannot represent the two real contacts.
    // Native scroll phases survive dispatch, and report3 cannot lift the pan.
    resetFakes();controller=[BTTouchController new];CHECK([controller startWithDisplay:42 postEvents:YES error:NULL]);
    single[1]=0x80;single[2]=0;
    reportCallback(reportContext,kIOReturnSuccess,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,3,single,6);
    single[2]=0x40;reportCallback(reportContext,kIOReturnSuccess,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,3,single,6);
    CHECK(postedDowns==1);sendFakeTouches(2,4000,8000);
    CHECK(postedUps==1);CHECK([controller.snapshot[@"activeReportID"] unsignedIntValue]==4);
    sendFakeTouches(2,4500,8500);CHECK(postedEvents[postedEvents.count-2].phase==NSEventPhaseBegan);
    CHECK(postedEvents.lastObject.type==NSEventTypeScrollWheel);CHECK(postedEvents.lastObject.phase==NSEventPhaseChanged);
    CHECK(postedEvents.lastObject.hasPreciseScrollingDeltas);CHECK(postedEvents.lastObject.scrollingDeltaX>0);
    NSUInteger before=postedEvents.count;
    single[1]=0;reportCallback(reportContext,kIOReturnSuccess,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,3,single,6);
    CHECK(postedEvents.count==before);sendFakeTouches(0,0,0);CHECK(postedEvents.lastObject.phase==NSEventPhaseEnded);
    CHECK(postedDowns==1);[controller stop];CHECK(boundaryViolations==0);

    // Stop, permission revocation, and timeout cancel native multi-finger output.
    for(int cause=0;cause<3;cause++) {
        resetFakes();controller=[BTTouchController new];CHECK([controller startWithDisplay:42 postEvents:YES error:NULL]);
        sendFakeTouches(2,4000,8000);sendFakeTouches(2,3000,9000);
        CHECK(postedEvents[postedEvents.count-2].phase==NSEventPhaseBegan);
        CHECK(postedEvents.lastObject.type==NSEventTypeMagnify);CHECK(postedEvents.lastObject.phase==NSEventPhaseChanged);
        CHECK(fabs(postedEvents.lastObject.magnification-0.5)<0.000001);
        if(cause==0)[controller stop];
        else {if(cause==1)postAccess=NO;else [controller setValue:@(NSProcessInfo.processInfo.systemUptime-0.6) forKey:@"lastFrameAt"];[controller tick:nil];}
        CHECK(!controller.running);CHECK(postedEvents.lastObject.type==NSEventTypeMagnify);CHECK(postedEvents.lastObject.phase==NSEventPhaseCancelled);
        before=postedEvents.count;[controller stop];CHECK(postedEvents.count==before);CHECK(closeCalls==1);CHECK(penCloseCalls==1);CHECK(boundaryViolations==0);
    }

    // Real observer callbacks cancel output and keep existing palms blocked.
    controller=startHeld();sendFakePen(BTPenInRange);CHECK(postedUps==1);CHECK(controller.running);
    sendFakePen(BTPenOutOfRange);pressFakeFinger();CHECK(postedDowns==1); // Default two-second cooldown.
    CHECK([controller updateResumeDelay:0]);pressFakeFinger();CHECK(postedDowns==1); // Must still lift.
    sendFakeTouches(0,0,0);pressFakeFinger();CHECK(postedDowns==2);
    sendFakePen(BTPenUnknown);CHECK(postedUps==2);CHECK([controller.snapshot[@"penObserver"][@"presence"] isEqual:@"unknown"]);
    [controller stop];CHECK(boundaryViolations==0);

    // Promotion must not turn a suppressed palm into a fresh two-finger gesture.
    resetFakes();initialPen=BTPenInRange;controller=[BTTouchController new];CHECK([controller startWithDisplay:42 postEvents:YES error:NULL]);
    CHECK([controller updateResumeDelay:0]);single[1]=0x80;
    reportCallback(reportContext,kIOReturnSuccess,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,3,single,6);
    sendFakePen(BTPenOutOfRange);sendFakeTouches(2,4000,8000);sendFakeTouches(2,3000,9000);
    CHECK(symbolicPosts==0);sendFakeTouches(0,0,0);sendFakeTouches(2,4000,8000);sendFakeTouches(2,3000,9000);
    CHECK(postedEvents.lastObject.type==NSEventTypeMagnify);[controller stop];

    // Delay persistence/validation uses only the in-memory defaults boundary.
    resetFakes();controller=[BTTouchController new];CHECK(controller.resumeDelay==2);
    CHECK([controller updateResumeDelay:0.5]);controller=[BTTouchController new];CHECK(controller.resumeDelay==0.5);
    CHECK(![controller updateResumeDelay:NAN]);CHECK(![controller updateResumeDelay:31]);CHECK(controller.resumeDelay==0.5);
    CHECK(openCalls==0);CHECK(penOpenCalls==0);

    // Callback report ID and packet ID must agree before an event is generated.
    resetFakes();controller=[BTTouchController new];CHECK([controller startWithDisplay:42 postEvents:YES error:NULL]);
    uint8_t mismatch[64]={4,0x41,0x00,0x20,0xc0,0x12};mismatch[55]=1;
    reportCallback(reportContext,kIOReturnSuccess,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,3,mismatch,64);
    CHECK([controller.snapshot[@"invalidFrames"] unsignedIntegerValue]==1);CHECK(postedDowns==0);[controller stop];
    // Exact verified vendor initializer; never target a pen or an unknown firmware.
    resetFakes();controller=[BTTouchController new];CHECK([controller startWithDisplay:42 postEvents:YES error:NULL]);
    CHECK(featureReads==1);CHECK(featureWrites==1);CHECK(writtenCommand[0]==3);CHECK(writtenCommand[1]==0x0b);CHECK(writtenCommand[2]==0);
    CHECK(writtenDevice && ReviewDeviceGetProperty(writtenDevice,CFSTR(kIOHIDVendorIDKey)) && [(__bridge NSNumber *)ReviewDeviceGetProperty(writtenDevice,CFSTR(kIOHIDVendorIDKey)) unsignedIntValue]==0x6066);[controller stop];
    resetFakes();firmwareReply[1]=2;controller=[BTTouchController new];CHECK(![controller startWithDisplay:42 postEvents:YES error:NULL]);
    CHECK(featureWrites==0);CHECK(closeCalls==1);CHECK(!controller.running);[controller stop];
    resetFakes();featureReadResult=kIOReturnError;controller=[BTTouchController new];CHECK(![controller startWithDisplay:42 postEvents:YES error:NULL]);
    CHECK(featureWrites==0);CHECK(closeCalls==1);[controller stop];
    resetFakes();featureWriteResult=kIOReturnUnsupported;controller=[BTTouchController new];CHECK(![controller startWithDisplay:42 postEvents:YES error:NULL]);
    CHECK(closeCalls==1);CHECK(!controller.running);[controller stop];
    CFSetRef originalDevices=fakeDevices;
    NSDictionary *secondDigitizer=@{@kIOHIDVendorIDKey:@0x6066,@kIOHIDProductIDKey:@1,@kIOHIDPrimaryUsagePageKey:@13,@kIOHIDPrimaryUsageKey:@4,@"LocationID":@2};
    const void *ambiguous[]={(__bridge const void *)testDigitizer(),(__bridge const void *)secondDigitizer};
    fakeDevices=CFSetCreate(NULL,ambiguous,2,&kCFTypeSetCallBacks);resetFakes();controller=[BTTouchController new];
    CHECK(![controller startWithDisplay:42 postEvents:YES error:NULL]);CHECK(openCalls==0);CHECK(featureWrites==0);[controller stop];
    CFRelease(fakeDevices);fakeDevices=originalDevices;
    CFRelease(fakeDevices);
    printf("Mock-I/O production lifecycle: %d checks, %d failures\n",checks,failures);return failures?1:0;
} }
