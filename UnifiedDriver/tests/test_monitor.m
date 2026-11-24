// Test-owned HID, permission and posting boundaries; never call a live device.
#import <Foundation/Foundation.h>
static double fakeUptime=100;
@interface UPTestProcessInfo : NSObject
+ (instancetype)processInfo;
- (NSTimeInterval)systemUptime;
@end
@implementation UPTestProcessInfo
+ (instancetype)processInfo {static UPTestProcessInfo *info; if(!info)info=[self new];return info;}
- (NSTimeInterval)systemUptime {return fakeUptime;}
@end
#define NSProcessInfo UPTestProcessInfo
#define IOHIDManagerCreate FakeManager
#define IOHIDManagerSetDeviceMatching FakeMatch
#define IOHIDManagerCopyDevices FakeDevices
#define IOHIDManagerRegisterDeviceRemovalCallback FakeRemoval
#define IOHIDManagerRegisterDeviceMatchingCallback FakeAdded
#define IOHIDManagerScheduleWithRunLoop FakeManagerSchedule
#define IOHIDManagerUnscheduleFromRunLoop FakeManagerUnschedule
#define IOHIDDeviceGetProperty FakeProperty
#define IOHIDDeviceOpen FakeOpen
#define IOHIDDeviceClose FakeClose
#define IOHIDDeviceRegisterInputReportCallback FakeReport
#define IOHIDDeviceRegisterRemovalCallback FakeDeviceRemoval
#define IOHIDDeviceScheduleWithRunLoop FakeDeviceSchedule
#define IOHIDDeviceUnscheduleFromRunLoop FakeDeviceUnschedule
#define IOHIDCheckAccess FakeAccess
#define CGPreflightPostEventAccess FakePostAccess
#define CGDisplayIsActive FakeActive
#define CGDisplayBounds FakeBounds
#define CGEventPost FakePost
#import "../UnifiedMonitor.m"
#include <assert.h>
static NSArray *devices;
static NSDictionary *match;
static IOHIDReportCallback callback;
static void *callbackContext;
static IOHIDDeviceCallback removal,matching;
static void *matchingContext;
static void *removalContext;
static IOHIDCallback deviceRemoval;
static void *deviceRemovalContext;
static int opens,closes,posts,ups,exits,closesInsideCallback;
static bool insideCallback;
static int keyDowns,keyUps;
static double postedPressure;
static int64_t upButtons;

static bool allowed=true;
static IOReturn openResult=kIOReturnSuccess;
IOHIDManagerRef FakeManager(CFAllocatorRef a,IOOptionBits o){(void)a;assert(o==kIOHIDManagerOptionIndependentDevices);return (IOHIDManagerRef)CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);}
void FakeMatch(IOHIDManagerRef m,CFDictionaryRef d){(void)m;match=[(__bridge NSDictionary *)d copy];}
CFSetRef FakeDevices(IOHIDManagerRef m){(void)m;return (__bridge_retained CFSetRef)[NSSet setWithArray:devices];}
void FakeRemoval(IOHIDManagerRef m,IOHIDDeviceCallback cb,void *ctx){(void)m;removal=cb;removalContext=ctx;}
void FakeAdded(IOHIDManagerRef m,IOHIDDeviceCallback cb,void *ctx){(void)m;matching=cb;matchingContext=ctx;}
void FakeManagerSchedule(IOHIDManagerRef m,CFRunLoopRef l,CFStringRef mode){(void)m;(void)l;assert(CFEqual(mode,kCFRunLoopCommonModes));}
void FakeManagerUnschedule(IOHIDManagerRef m,CFRunLoopRef l,CFStringRef mode){(void)m;(void)l;(void)mode;}
CFTypeRef FakeProperty(IOHIDDeviceRef d,CFStringRef key){return CFDictionaryGetValue((CFDictionaryRef)d,key);}
IOReturn FakeOpen(IOHIDDeviceRef d,IOOptionBits o){assert(exact(d));assert(o==kIOHIDOptionsTypeSeizeDevice);opens++;return openResult;}
IOReturn FakeClose(IOHIDDeviceRef d,IOOptionBits o){assert(exact(d));assert(o==kIOHIDOptionsTypeSeizeDevice);if(insideCallback)closesInsideCallback++;closes++;return 0;}
void FakeReport(IOHIDDeviceRef d,uint8_t *buf,CFIndex n,IOHIDReportCallback cb,void *ctx){(void)d;(void)buf;assert(n==8);callback=cb;callbackContext=ctx;}
void FakeDeviceRemoval(IOHIDDeviceRef d,IOHIDCallback cb,void *ctx){(void)d;deviceRemoval=cb;deviceRemovalContext=ctx;}
void FakeDeviceSchedule(IOHIDDeviceRef d,CFRunLoopRef l,CFStringRef mode){(void)d;(void)l;assert(CFEqual(mode,kCFRunLoopCommonModes));}
void FakeDeviceUnschedule(IOHIDDeviceRef d,CFRunLoopRef l,CFStringRef mode){(void)d;(void)l;(void)mode;}
IOHIDAccessType FakeAccess(IOHIDRequestType type){(void)type;return allowed?kIOHIDAccessTypeGranted:kIOHIDAccessTypeDenied;}
bool FakePostAccess(void){return allowed;}
boolean_t FakeActive(CGDirectDisplayID d){return d==7;}
CGRect FakeBounds(CGDirectDisplayID d){(void)d;return CGRectMake(-1920,0,1920,1080);}
void FakePost(CGEventTapLocation tap,CGEventRef event){(void)tap;posts++;
    if(CGEventGetType(event)==kCGEventKeyDown){keyDowns++;assert(CGEventGetFlags(event)==kCGEventFlagMaskCommand);}
    if(CGEventGetType(event)==kCGEventKeyUp){keyUps++;assert(CGEventGetFlags(event)==0);}
    if(CGEventGetType(event)==kCGEventLeftMouseDragged || CGEventGetType(event)==kCGEventLeftMouseDown)postedPressure=CGEventGetDoubleValueField(event,kCGTabletEventPointPressure);
    if(CGEventGetType(event)==kCGEventLeftMouseUp){ups++;upButtons=CGEventGetIntegerValueField(event,kCGTabletEventPointButtons);}if(CGEventGetType(event)==kCGEventTabletProximity && !CGEventGetIntegerValueField(event,kCGTabletProximityEventEnterProximity))exits++;}
static void drainMain(void) {
    __block bool done=false;dispatch_async(dispatch_get_main_queue(),^{done=true;});
    double until=CFAbsoluteTimeGetCurrent()+1;
    while(!done && CFAbsoluteTimeGetCurrent()<until)CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
    assert(done);
}
static void deliver(uint8_t flags){uint8_t b[]={1,flags,0,0x23,0,0x14,0,0x10};assert(callback);callback(callbackContext,0,NULL,kIOHIDReportTypeInput,1,b,8);}
int main(void){@autoreleasepool{
    NSDictionary *pen=@{@kIOHIDVendorIDKey:@0xed1,@kIOHIDProductIDKey:@0x7821,@kIOHIDPrimaryUsagePageKey:@13,@kIOHIDPrimaryUsageKey:@2,@kIOHIDTransportKey:@"USB",@kIOHIDLocationIDKey:@0x12340000};devices=@[pen];
    [BTPenMonitor configureDisplay:7 pressureExponent:1];BTPenMonitor *m=[BTPenMonitor new];
    assert(opens==0);assert([m startWithError:NULL]);assert(m.presence==BTPenUnknown);assert([match[@kIOHIDPrimaryUsageKey] isEqual:@2] && [match[@kIOHIDTransportKey] isEqual:@"USB"]);
    __block BTPenPresence seen=BTPenUnknown;m.presenceChanged=^(BTPenPresence p){seen=p;};
    deliver(0x11);assert(seen==BTPenInRange);assert(posts==2);[m stop];drainMain();assert(ups==1 && exits==1 && closes==1);[m stop];drainMain();assert(closes==1);
    assert([m startWithError:NULL]);deliver(0x11);assert(removal && removalContext);deviceRemoval(deviceRemovalContext,0,(__bridge void *)pen);drainMain();assert(!m.running && seen==BTPenUnknown);assert(ups==2 && exits==2 && closes==2);
    assert([m startWithError:NULL]);deliver(0x11);allowed=false;[m tick:nil];drainMain();assert(!m.running);assert(ups==3 && exits==3 && closes==3);
    int before=opens;assert(![m startWithError:NULL]);drainMain();assert(opens==before);allowed=true;
    openResult=kIOReturnExclusiveAccess;assert(![m startWithError:NULL]);drainMain();assert(closes==4);openResult=0;
    devices=@[];before=opens;assert(![m startWithError:NULL]);drainMain();assert(opens==before);
    NSMutableDictionary *wrong=[pen mutableCopy];wrong[@kIOHIDProductIDKey]=@0x782c;devices=@[wrong];assert(![m startWithError:NULL]);drainMain();assert(opens==before);
    wrong[@kIOHIDProductIDKey]=@0x7821;wrong[@kIOHIDPrimaryUsagePageKey]=@1;assert(![m startWithError:NULL]);drainMain();assert(opens==before);
    // Discovery does not confer authority to open: independently verify USB identity.
    for(id transport in @[@"Bluetooth",NSNull.null]) {
        wrong=[pen mutableCopy];wrong[@kIOHIDTransportKey]=transport==NSNull.null?nil:transport;devices=@[wrong];
        assert(![m startWithError:NULL]);drainMain();assert(opens==before);
    }
    for(id location in @[@0,@(-1),@YES,@"123",NSNull.null]) {
        wrong=[pen mutableCopy];wrong[@kIOHIDLocationIDKey]=location==NSNull.null?nil:location;devices=@[wrong];
        assert(![m startWithError:NULL]);drainMain();assert(opens==before);
    }
    wrong=[pen mutableCopy];wrong[@kIOHIDLocationIDKey]=@0x12350000;devices=@[pen,wrong];
    assert(![m startWithError:NULL]);drainMain();assert(opens==before);
    devices=@[pen];assert([m startWithError:NULL]);deliver(0);assert(seen==BTPenOutOfRange);deliver(0x11);
    uint8_t malformed[]={1,0x11};callback(callbackContext,0,NULL,kIOHIDReportTypeInput,1,malformed,2);drainMain();assert(!m.running);assert(ups==4 && exits==4 && closes==5);
    assert([m startWithError:NULL]);
    __block BTGestureState gestures={0};assert(BTGestureInit(&gestures,BTGestureDefaultConfig()));assert(gestures.config.resumeDelay==2);
    __block double time=10;
    m.presenceChanged=^(BTPenPresence presence){BTGestureBatch batch={0};assert(BTGestureHandlePen(&gestures,(BTGesturePenInput){presence,time},&batch));};
    deliver(0x10);time=11;deliver(0);assert(gestures.penOutAt==11);time=12;deliver(0);assert(gestures.penOutAt==11);
    BTGestureBatch touchBatch={0};BTGestureTouchInput touch={.frame={.count=1,.contacts={{.identifier=1,.x=100,.y=100}}},.bounds={0,0,1920,1080},.time=12.99};
    assert(BTGestureHandleTouch(&gestures,touch,&touchBatch));assert(touchBatch.count==0);
    touch.frame.count=0;touch.time=13;assert(BTGestureHandleTouch(&gestures,touch,&touchBatch));
    touch.frame.count=1;touch.time=13.1;assert(BTGestureHandleTouch(&gestures,touch,&touchBatch));
    assert(BTGestureTick(&gestures,13.5,&touchBatch));assert(touchBatch.count>0 && touchBatch.events[0].kind==BTGesturePointerDown);
    [m stop];drainMain();
    // Silence expires only a posted held tip, measured from the last valid report 1.
    [BTPenMonitor updateShortcutBindings:@[@{@"key":@6,@"modifiers":@(kCGEventFlagMaskCommand)},NSNull.null]];
    m.presenceChanged=nil;fakeUptime=1000;assert([m startWithError:NULL]);deliver(0x10);
    fakeUptime=1010;[m tick:nil];drainMain();assert(m.running); // Mere hover must not expire.
    deliver(0x11);fakeUptime=1011;deliver(0x11); // A valid stationary tip report refreshes.
    fakeUptime=1012.9;uint8_t unrelated[]={2,0};callback(callbackContext,0,NULL,kIOHIDReportTypeInput,2,unrelated,2);
    fakeUptime=1012.999;[m tick:nil];drainMain();assert(m.running);
    int oldUps=ups,oldExits=exits,oldCloses=closes,oldOpens=opens;
    IOHIDReportCallback heldCallback=callback;void *heldContext=callbackContext;
    __block int failures=0;
    id timeoutObserver=[NSNotificationCenter.defaultCenter addObserverForName:UPFailureNotification object:m queue:nil usingBlock:^(NSNotification *note){(void)note;failures++;}];
    fakeUptime=1013;[m tick:nil];drainMain();
    fprintf(stderr,"pen silence: running=%d ups=%d exits=%d closes=%d failures=%d\n",m.running,ups-oldUps,exits-oldExits,closes-oldCloses,failures);
    assert(m.running && ups==oldUps+1 && exits==oldExits && closes==oldCloses && failures==0);
    assert(callback==heldCallback && callbackContext==heldContext && opens==oldOpens);
    assert(m.presence==BTPenInRange && ![m.snapshot[@"tipDown"] boolValue]);
    assert([m.snapshot[@"effectivePressure"] doubleValue]==0 && [m.snapshot[@"rawPressure"] intValue]==0);
    assert([m.snapshot[@"heldTipTimeouts"] unsignedIntValue]==1);
    int quietPosts=posts,quietKeys=keyDowns;
    for(int i=0;i<3;i++){fakeUptime+=10;[m tick:nil];deliver(0x17);}
    assert(posts==quietPosts && keyDowns==quietKeys && ups==oldUps+1 && exits==oldExits);
    assert([m.snapshot[@"heldTipTimeouts"] unsignedIntValue]==1);
    deliver(0x10);deliver(0x11);assert([m.snapshot[@"tipDown"] boolValue] && opens==oldOpens);
    fakeUptime+=2;[m tick:nil];assert(ups==oldUps+2 && exits==oldExits && m.presence==BTPenInRange);
    quietPosts=posts;deliver(0x19);assert(posts==quietPosts); // Tool change while held cannot rearm.
    deliver(0);assert(m.presence==BTPenOutOfRange && exits==oldExits+1);
    quietPosts=posts;fakeUptime+=100;[m tick:nil];
    assert(m.running && posts==quietPosts && m.presence==BTPenOutOfRange);
    deliver(0x11);assert([m.snapshot[@"tipDown"] boolValue] && m.running && opens==oldOpens);
    [NSNotificationCenter.defaultCenter removeObserver:timeoutObserver];
    [BTPenMonitor updateShortcutBindings:nil];
    [m stop];drainMain();assert(ups==oldUps+3 && exits==oldExits+2 && closes==oldCloses+1);
    puts("Pen silence recovers once without close, proximity exit, shortcuts or held-tip replay; real up/out rearms.");
    // Real main queue: callback teardown must be deferred, with output blocked now.
    assert([m startWithError:NULL]);deliver(0x11);oldCloses=closes;oldUps=ups;oldExits=exits;int oldPosts=posts;
    __block bool ownerStopped=false;
    id failureObserver=[NSNotificationCenter.defaultCenter addObserverForName:UPFailureNotification object:m queue:nil usingBlock:^(NSNotification *note){(void)note;ownerStopped=true;}];
    m.presenceChanged=^(BTPenPresence presence){if(presence==BTPenUnknown)assert(ownerStopped);};
    insideCallback=true;callback(callbackContext,0,NULL,kIOHIDReportTypeInput,1,malformed,2);insideCallback=false;
    [NSNotificationCenter.defaultCenter removeObserver:failureObserver];m.presenceChanged=nil;
    assert(!m.running && closesInsideCallback==0 && closes==oldCloses && posts==oldPosts);
    NSString *reason=m.status;
    assert(![m startWithError:NULL]); // No new session may overtake deferred cleanup.
    deliver(0x11);assert(posts==oldPosts);
    drainMain();assert(closes==oldCloses+1 && ups==oldUps+1 && exits==oldExits+1);
    assert([m.status isEqual:reason]);
    assert([m startWithError:NULL]);drainMain();assert(m.running); // No stale stop.
    [m stop];drainMain();
    // Real monitor integration: only accepted packets produce edges, with no reopen
    // for pressure changes. All posting still terminates at FakePost above.
    NSArray *valid=@[@{@"key":@6,@"modifiers":@(kCGEventFlagMaskCommand)},@{@"key":@7,@"modifiers":@(kCGEventFlagMaskCommand)}];
    assert(([UPValidatedBindings(nil) isEqual:@[NSNull.null,NSNull.null]]));
    for(id bad in @[@"bad",@[@{}],@[@{@"key":@6.5,@"modifiers":@0},@{@"key":@55,@"modifiers":@0}],@[@{@"key":@6,@"modifiers":@(-1)},@{@"key":@6,@"modifiers":@0.5}]])
        assert(([UPValidatedBindings(bad) isEqual:@[NSNull.null,NSNull.null]]));
    [BTPenMonitor updateShortcutBindings:valid];
    assert([m startWithError:NULL]);assert([m.snapshot[@"pressureState"] isEqual:@"noData"]);
    assert([m.snapshot[@"effectivePressure"] doubleValue]==0);
    before=opens;deliver(0x17);assert(keyDowns==0); // Unknown initial held state.
    assert(fabs(postedPressure-0.5)<0.0001);
    [BTPenMonitor updatePressureExponent:2];
    fprintf(stderr,"pressure after slider, before packet: expected 0.5, actual %.8f\n",[m.snapshot[@"effectivePressure"] doubleValue]);
    assert([m.snapshot[@"effectivePressure"] doubleValue]==0.5);
    deliver(0x17);
    fprintf(stderr,"pressure fresh packet: expected 0.25, meter %.8f, native event %.8f\n",[m.snapshot[@"effectivePressure"] doubleValue],postedPressure);
    assert([m.snapshot[@"effectivePressure"] doubleValue]==0.25);
    assert(fabs(postedPressure-[m.snapshot[@"effectivePressure"] doubleValue])<0.0001 && opens==before);
    assert([m.snapshot[@"rawPressure"] intValue]==4096);
    deliver(0x10);assert([m.snapshot[@"rawPressure"] intValue]==0);
    assert([m.snapshot[@"effectivePressure"] doubleValue]==0);
    [BTPenMonitor updatePressureExponent:0.5];assert([m.snapshot[@"effectivePressure"] doubleValue]==0);
    deliver(0);assert([m.snapshot[@"effectivePressure"] doubleValue]==0);
    [BTPenMonitor updatePressureExponent:2];
    deliver(0x17);assert(keyDowns==0); // Return to proximity already held.
    deliver(0x11);deliver(0x17);assert(keyDowns==2 && keyUps==2);
    deliver(0x17);deliver(0x11);assert(keyDowns==2);
#define REVIEW_KEYS(name,expected) do { \
    fprintf(stderr,"%s: expected %d pairs, down %d up %d\n",name,expected,keyDowns,keyUps); \
    assert(keyDowns==(expected) && keyUps==(expected)); \
} while(0)
    // Capture observes a release. The first genuine press after ending must fire.
    [BTPenMonitor setShortcutCapture:YES];deliver(0x17);deliver(0x11);
    REVIEW_KEYS("capture suppresses presses and observes release",2);
    [BTPenMonitor setShortcutCapture:NO];REVIEW_KEYS("capture end emits nothing",2);
    deliver(0x17);REVIEW_KEYS("capture released -> next press",4);
    // Last observation held: ending capture and held reports cannot retrigger.
    [BTPenMonitor setShortcutCapture:YES];deliver(0x17);
    [BTPenMonitor setShortcutCapture:NO];deliver(0x17);REVIEW_KEYS("capture held -> held",4);
    deliver(0x11);REVIEW_KEYS("capture held -> release",4);
    deliver(0x17);REVIEW_KEYS("capture held -> release -> press",6);
    // No reports during capture: preserve the previously known released state.
    deliver(0x11);[BTPenMonitor setShortcutCapture:YES];[BTPenMonitor setShortcutCapture:NO];
    deliver(0x17);REVIEW_KEYS("capture no packets, known released -> press",8);
    // Binding edits preserve known released and held observations in the same way.
    deliver(0x11);[BTPenMonitor updateShortcutBindings:valid];REVIEW_KEYS("rebind released emits nothing",8);
    deliver(0x17);REVIEW_KEYS("rebind released -> next press",10);
    [BTPenMonitor updateShortcutBindings:valid];deliver(0x17);REVIEW_KEYS("rebind held -> held",10);
    deliver(0x11);REVIEW_KEYS("rebind held -> release",10);
    deliver(0x17);REVIEW_KEYS("rebind held -> release -> press",12);
    deliver(0x1f);REVIEW_KEYS("tool change held",12);
    deliver(0x19);deliver(0x1f);REVIEW_KEYS("new tool released -> press",14);
    deliver(0);[BTPenMonitor updateShortcutBindings:valid];
    deliver(0x17);REVIEW_KEYS("proximity return held after edit",14);
    callback(callbackContext,0,NULL,kIOHIDReportTypeInput,1,malformed,2);drainMain();
    assert(!m.running);REVIEW_KEYS("invalid packet and cleanup",14);
    assert([m.snapshot[@"pressureState"] isEqual:@"inactive"]);
    assert([m.snapshot[@"effectivePressure"] doubleValue]==0);
    assert([m.snapshot[@"rawPressure"] intValue]==0);
    assert([m.snapshot[@"shortcutPairs"] intValue]==14);
    assert(([m.snapshot[@"sideButtonPresses"] isEqual:@[@7,@7]]));
    [m stop];drainMain();REVIEW_KEYS("repeated stop",14);
    assert([m startWithError:NULL]);
    [BTPenMonitor setShortcutCapture:YES];[BTPenMonitor setShortcutCapture:NO];[BTPenMonitor updateShortcutBindings:valid];
    deliver(0x17);REVIEW_KEYS("unknown initial state after capture and rebind",14);
    [m stop];drainMain();
    [BTPenMonitor updateShortcutBindings:nil];[BTPenMonitor updatePressureExponent:1];
    assert([m startWithError:NULL]);deliver(0x10);deliver(0x17);REVIEW_KEYS("unassigned bindings",14);
    [m stop];drainMain();
#undef REVIEW_KEYS
    NSMutableDictionary *batteryPen=[pen mutableCopy];devices=@[batteryPen];
    assert([m startWithError:NULL]);int batteryOpens=opens;
    assert(m.snapshot[@"batteryPercent"]==NSNull.null);
    batteryPen[@"BatteryPercent"]=@19;assert([m.snapshot[@"batteryPercent"] isEqual:@19]);
    batteryPen[@"BatteryPercent"]=@20;assert([m.snapshot[@"batteryPercent"] isEqual:@20]);
    batteryPen[@"BatteryPercent"]=@YES;assert(m.snapshot[@"batteryPercent"]==NSNull.null);
    batteryPen[@"BatteryPercent"]=@101;assert(m.snapshot[@"batteryPercent"]==NSNull.null);
    batteryPen[@"BatteryPercent"]=@19;[m stop];assert(m.snapshot[@"batteryPercent"]==NSNull.null);
    drainMain();assert(opens==batteryOpens);
    // Pen mute keeps the seize but never sends pen packets into either output path.
    devices=@[pen];[BTPenMonitor updateShortcutBindings:valid];
    oldOpens=opens;oldCloses=closes;oldPosts=posts;quietKeys=keyDowns;
    __block int presenceChanges=0;m.presenceChanged=^(BTPenPresence p){(void)p;presenceChanges++;};
    m.penInputEnabled=NO;
    assert([m startWithError:NULL]);int startupPresenceChanges=presenceChanges;
    deliver(0x10);deliver(0x17);deliver(0);fakeUptime+=10;[m tick:nil];
    assert(posts==oldPosts && keyDowns==quietKeys && presenceChanges==startupPresenceChanges);
    assert(m.running && opens==oldOpens+1 && closes==oldCloses && m.presence==BTPenOutOfRange);
    assert(![m.snapshot[@"tipDown"] boolValue] && [m.snapshot[@"effectivePressure"] doubleValue]==0);
    assert(([m.snapshot[@"sideButtonPresses"] isEqual:@[@0,@0]]));
    m.penInputEnabled=YES;
    deliver(0x17);assert(posts==oldPosts && keyDowns==quietKeys); // No replay of tip/shortcuts held across enable.
    deliver(0x10);deliver(0x17);assert(m.presence==BTPenInRange && [m.snapshot[@"tipDown"] boolValue]);
    assert(keyDowns==quietKeys+2 && [m.snapshot[@"effectivePressure"] doubleValue]>0);
    oldPosts=posts;oldUps=ups;oldExits=exits;m.penInputEnabled=NO;
    assert(posts==oldPosts+2 && ups==oldUps+1 && upButtons==0 && exits==oldExits+1);
    assert(m.presence==BTPenOutOfRange && ![m.snapshot[@"tipDown"] boolValue] && [m.snapshot[@"rawPressure"] intValue]==0);
    assert([m.snapshot[@"effectivePressure"] doubleValue]==0);
    m.penInputEnabled=NO;deliver(0x17);[m tick:nil];[m stop];drainMain();
    assert(posts==oldPosts+2 && opens==oldOpens+1 && closes==oldCloses+1);
    // A matching hotplug is never opened as a fallback, even while muted.
    assert([m startWithError:NULL]);oldOpens=opens;oldPosts=posts;
    assert(matching);matching(matchingContext,0,NULL,(__bridge IOHIDDeviceRef)wrong);
    drainMain();assert(!m.running && opens==oldOpens && posts==oldPosts);
    puts("Pen mute: exclusive open retained, zero muted reports posted, tip/buttons and proximity released once.");
    puts("Unified monitor exact-device, shared presence and cleanup checks passed (fake HID/posting).");
}return 0;}
