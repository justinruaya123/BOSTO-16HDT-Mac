#import "BTTouchController.h"
#import "BTGestureEvents.h"
#import "BTPenMonitor.h"
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#include <math.h>
#ifdef BT_UNIFIED_DRIVER
#import <os/log.h>
#endif

static uint32_t property(IOHIDDeviceRef device, const char *key) {
    CFStringRef name=CFStringCreateWithCString(NULL,key,kCFStringEncodingUTF8);
    CFTypeRef value=IOHIDDeviceGetProperty(device,name); uint32_t number=0;
    if(value && CFGetTypeID(value)==CFNumberGetTypeID()) CFNumberGetValue(value,kCFNumberSInt32Type,&number);
    CFRelease(name); return number;
}
static NSArray *matching(void) {
    return @[@{@kIOHIDVendorIDKey:@0x6066,@kIOHIDProductIDKey:@1,@kIOHIDPrimaryUsagePageKey:@13,@kIOHIDPrimaryUsageKey:@4},
             @{@kIOHIDVendorIDKey:@0x6066,@kIOHIDProductIDKey:@1,@kIOHIDPrimaryUsagePageKey:@1,@kIOHIDPrimaryUsageKey:@2}];
}
static BOOL isTouch(IOHIDDeviceRef device) {
    return device && BTMatchesTouchDevice(property(device,kIOHIDVendorIDKey),property(device,kIOHIDProductIDKey),property(device,kIOHIDPrimaryUsagePageKey),property(device,kIOHIDPrimaryUsageKey));
}
static double now(void) { return NSProcessInfo.processInfo.systemUptime; }
static NSString *const resumeDelayKey=@"TouchResumeDelay";
static BTDisplayBounds boundsFor(CGDirectDisplayID display) {
    if(!display || !CGDisplayIsActive(display)) return (BTDisplayBounds){0};
    CGRect r=CGDisplayBounds(display); return (BTDisplayBounds){r.origin.x,r.origin.y,r.size.width,r.size.height};
}
NSArray<NSDictionary *> *BTAvailableDisplays(void) {
    NSMutableArray *rows=[NSMutableArray array];
    for(NSScreen *screen in NSScreen.screens) {
        CGDirectDisplayID display=[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        CFUUIDRef uuid=CGDisplayCreateUUIDFromDisplayID(display);
        NSString *identifier=uuid?CFBridgingRelease(CFUUIDCreateString(NULL,uuid)):@"";
        if(uuid)CFRelease(uuid);
        CGRect b=CGDisplayBounds(display);
        [rows addObject:@{@"id":@(display),@"uuid":identifier,@"name":screen.localizedName,
                          @"bounds":@[@(b.origin.x),@(b.origin.y),@(b.size.width),@(b.size.height)],
                          @"mirrored":@(CGDisplayIsInMirrorSet(display))}];
    }
    return rows;
}

@interface BTTouchController () {
    IOHIDManagerRef _manager;
    CFRunLoopRef _ownerLoop;
    BOOL _openAttempted;
#ifdef BT_UNIFIED_DRIVER
    BOOL _unifiedStopping,_unifiedCleaning;
#endif
    NSMutableSet<NSValue *> *_initialDevices;
    BTGestureState _gestures;
    BTGestureEvent _heldEvent;
    BTPenMonitor *_penMonitor;
    BTDisplayBounds _bounds;
    CGDirectDisplayID _display;
    BOOL _postEvents;
    NSUInteger _devices, _reports, _rawReports, _valid, _invalid, _downs, _drags, _ups, _contacts;
    NSUInteger _scrollEvents, _magnifyEvents, _cancelEvents;
    uint32_t _activeReportID;
    BOOL _report4Seen;
    uint8_t _firmware[3];
    NSUInteger _configurationWrites;
    BOOL _touchConfigurationAccepted;
    NSMutableDictionary<NSString *,NSNumber *> *_rawReportIDs;
    double _lastFrameAt, _lastDownAt, _lastClickX, _lastClickY;
    int64_t _clickCount;
}
@property(nonatomic, readwrite) BOOL running;
@property(nonatomic, readwrite, copy) NSString *status;
@property(nonatomic, strong) NSTimer *watchdog;
- (void)received:(uint8_t *)bytes length:(CFIndex)length reportID:(uint32_t)reportID sender:(void *)sender result:(IOReturn)result;
- (void)controllerRemoved:(IOHIDDeviceRef)device;
- (void)controllerAdded:(IOHIDDeviceRef)device;
- (void)penChanged:(BTPenPresence)presence;
@end
static void received(void *context,IOReturn result,void *sender,IOHIDReportType type,uint32_t reportID,uint8_t *bytes,CFIndex length) {
    if(type==kIOHIDReportTypeInput) [(__bridge BTTouchController *)context received:bytes length:length reportID:reportID sender:sender result:result];
}
static void removed(void *context,IOReturn result,void *sender,IOHIDDeviceRef device) {
    (void)result;(void)sender;[(__bridge BTTouchController *)context controllerRemoved:device];
}
static void added(void *context,IOReturn result,void *sender,IOHIDDeviceRef device) {
    (void)result;(void)sender;[(__bridge BTTouchController *)context controllerAdded:device];
}

@implementation BTTouchController
#ifdef BT_UNIFIED_DRIVER
@synthesize status=_status;
- (void)setStatus:(NSString *)status {
    _status=[status copy];
    // Failure paths assign their reason after stop, while still in the callback.
    if(_unifiedStopping && ![status isEqual:@"Disabled"])
        os_log_error(OS_LOG_DEFAULT,"BostoTablet touch failure: %{public}@",status);
}
#endif
- (instancetype)init {
    if((self=[super init])) {
        BTGestureConfig config=BTGestureDefaultConfig();
        id saved=[NSUserDefaults.standardUserDefaults objectForKey:resumeDelayKey];
        if([saved isKindOfClass:NSNumber.class])config.resumeDelay=[saved doubleValue];
        if(!BTGestureInit(&_gestures,config))(void)BTGestureInit(&_gestures,BTGestureDefaultConfig());
        self.status=@"Disabled — pen driver unchanged.";
#ifdef BT_UNIFIED_DRIVER
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(unifiedPenFailed:) name:@"UnifiedPenFailed" object:nil];
#endif
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(displayChanged:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
        [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(suspend:) name:NSWorkspaceWillSleepNotification object:nil];
        [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(suspend:) name:NSWorkspaceSessionDidResignActiveNotification object:nil];
    }
    return self;
}
- (void)dealloc {
#ifdef BT_UNIFIED_DRIVER
    [self unifiedCleanup];
#else
    [self stop];
#endif
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}
+ (NSDictionary *)diagnostics {
    IOHIDManagerRef manager=IOHIDManagerCreate(NULL,kIOHIDOptionsTypeNone);
    IOHIDManagerSetDeviceMatchingMultiple(manager,(__bridge CFArrayRef)matching());
    CFSetRef devices=IOHIDManagerCopyDevices(manager); NSMutableArray *rows=[NSMutableArray array];
    for(id object in (__bridge NSSet *)devices) {
        IOHIDDeviceRef device=(__bridge IOHIDDeviceRef)object;
        if(isTouch(device)) [rows addObject:@{@"vendorID":@(property(device,kIOHIDVendorIDKey)),@"productID":@(property(device,kIOHIDProductIDKey)),
                                             @"usagePage":@(property(device,kIOHIDPrimaryUsagePageKey)),@"usage":@(property(device,kIOHIDPrimaryUsageKey))}];
    }
    if(devices)CFRelease(devices);CFRelease(manager);
    return @{@"touchInterfaces":rows,@"displays":BTAvailableDisplays(),
             @"listenAccess":@(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)),@"postEventAccess":@(CGPreflightPostEventAccess()),
             @"penAccessed":@NO};
}
- (BOOL)fail:(NSString *)message code:(NSInteger)code error:(NSError **)error {
    [self stop];self.status=message;
    if(error)*error=[NSError errorWithDomain:@"local.BostoMultitouch" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
#ifdef BT_UNIFIED_DRIVER
- (void)unifiedPenFailed:(NSNotification *)note {
    if(note.object!=_penMonitor)return;
    [self stop];self.status=note.userInfo[@"reason"]?:@"Unified pen failed; both streams disabled.";
}
#endif
- (BOOL)startWithDisplay:(CGDirectDisplayID)display postEvents:(BOOL)postEvents error:(NSError **)error {
#ifdef BT_UNIFIED_DRIVER
    // The replacement monitor owns native pen output and cannot observe safely.
    // Reject before even stop: rejection itself must not open or post anything.
    if(!postEvents) {
        if(error)*error=[NSError errorWithDomain:@"local.BostoTablet" code:7 userInfo:@{NSLocalizedDescriptionKey:@"Unified observe mode is unsupported; no devices opened."}];
        return NO;
    }
#endif
#ifdef BT_UNIFIED_DRIVER
    if(!NSThread.isMainThread){if(error)*error=[NSError errorWithDomain:@"local.BostoTablet" code:8 userInfo:@{NSLocalizedDescriptionKey:@"Unified sessions require the main run loop."}];return NO;}
    [self stop];
    if(_unifiedStopping){if(error)*error=[NSError errorWithDomain:@"local.BostoTablet" code:9 userInfo:@{NSLocalizedDescriptionKey:@"Previous unified session is stopping; retry after cleanup."}];return NO;}
    _display=display; _bounds=boundsFor(display);
#else
    [self stop]; _display=display; _bounds=boundsFor(display);
#endif
    double x,y;
    if(!BTMapTouchPoint((BTContact){0},_bounds,&x,&y))return [self fail:@"Selected display is unavailable; no Retina fallback." code:1 error:error];
    if(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)!=kIOHIDAccessTypeGranted)return [self fail:@"Input Monitoring permission required. Grant it, then Enable again." code:2 error:error];
    if(postEvents && !CGPreflightPostEventAccess())return [self fail:@"Accessibility permission required. Grant it, then Enable again." code:3 error:error];
    _reports=_rawReports=_valid=_invalid=_downs=_drags=_ups=_contacts=0; _devices=0;
    _scrollEvents=_magnifyEvents=_cancelEvents=0;_heldEvent=(BTGestureEvent){0};
    BTGestureConfig config=BTGestureDefaultConfig();config.resumeDelay=self.resumeDelay;
    (void)BTGestureInit(&_gestures,config);
    _activeReportID=0;_report4Seen=NO;_rawReportIDs=[NSMutableDictionary dictionary];
    memset(_firmware,0,sizeof _firmware);_configurationWrites=0;_touchConfigurationAccepted=NO;
    _postEvents=postEvents; _lastFrameAt=now(); _lastDownAt=-INFINITY;_clickCount=1;
    _initialDevices=[NSMutableSet set];
    _manager=IOHIDManagerCreate(NULL,kIOHIDOptionsTypeNone);
    if(!_manager)return [self fail:@"Could not create touchscreen connection." code:4 error:error];
    IOHIDManagerSetDeviceMatchingMultiple(_manager,(__bridge CFArrayRef)matching());
    CFSetRef devices=IOHIDManagerCopyDevices(_manager);IOHIDDeviceRef digitizer=NULL;NSUInteger digitizers=0;BOOL unexpected=NO;
    for(id object in (__bridge NSSet *)devices) {
        IOHIDDeviceRef device=(__bridge IOHIDDeviceRef)object;
        if(isTouch(device)) {
            [_initialDevices addObject:[NSValue valueWithPointer:device]];
            _devices++;if(property(device,kIOHIDPrimaryUsagePageKey)==13){digitizer=device;digitizers++;}
        } else unexpected=YES;
    }
    if(digitizers!=1 || _devices>2 || unexpected) {
        if(devices)CFRelease(devices);
        return [self fail:@"Expected one Bosto touch controller. Check its USB connection." code:4 error:error];
    }
    _penMonitor=[BTPenMonitor new];
    __weak BTTouchController *weakSelf=self;
    _penMonitor.presenceChanged=^(BTPenPresence presence){[weakSelf penChanged:presence];};
    NSError *penError=nil;
    if(![_penMonitor startWithError:&penError]) {
        CFRelease(devices);
        return [self fail:penError.localizedDescription code:6 error:error];
    }
    IOHIDManagerRegisterInputReportCallback(_manager,received,(__bridge void *)self);
    IOHIDManagerRegisterDeviceRemovalCallback(_manager,removed,(__bridge void *)self);
    IOHIDManagerRegisterDeviceMatchingCallback(_manager,added,(__bridge void *)self);
    // Reports and watchdog must both run during AppKit tracking/modal loops.
    _ownerLoop=(CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
    IOHIDManagerScheduleWithRunLoop(_manager,_ownerLoop,kCFRunLoopCommonModes);
    _openAttempted=YES;
    IOReturn result=IOHIDManagerOpen(_manager,kIOHIDOptionsTypeSeizeDevice);
    if(result!=kIOReturnSuccess){
        CFRelease(devices);
        return [self fail:[NSString stringWithFormat:@"Cannot open touchscreen (0x%08x); pen observation was shared only.",result] code:result error:error];
    }
    _firmware[0]=9;CFIndex versionLength=sizeof _firmware;
    result=IOHIDDeviceGetReport(digitizer,kIOHIDReportTypeFeature,9,_firmware,&versionLength);
    if(result!=kIOReturnSuccess || versionLength!=3 || _firmware[0]!=9 || _firmware[1]!=1 || _firmware[2]!=26){
        CFRelease(devices);
        return [self fail:@"Unexpected touch-controller firmware; no configuration written." code:5 error:error];
    }
    if(postEvents){
        // Exact signed manufacturer command; approved for this firmware only.
        // Enables touch on 6066:0001. Never sent to a pen, and never a firmware flash.
        const uint8_t command[3]={3,0x0b,0};_configurationWrites++;
        result=IOHIDDeviceSetReport(digitizer,kIOHIDReportTypeFeature,3,command,sizeof command);
        if(result!=kIOReturnSuccess){
            CFRelease(devices);
            return [self fail:[NSString stringWithFormat:@"Touch initialization failed (0x%08x); pen unchanged.",result] code:result error:error];
        }
        _touchConfigurationAccepted=YES;
    }
    CFRelease(devices);
    self.running=YES;[self penChanged:_penMonitor.presence];
    self.watchdog=[NSTimer timerWithTimeInterval:0.05 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [NSRunLoop.currentRunLoop addTimer:self.watchdog forMode:NSRunLoopCommonModes];
    return YES;
}
- (double)resumeDelay {return _gestures.config.resumeDelay;}
- (BOOL)updateResumeDelay:(double)seconds {
    BTGestureBatch batch={0};
    BOOL valid=BTGestureSetResumeDelay(&_gestures,(BTGestureDelayInput){seconds,now()},&batch);
    // Invalid user input keeps the previous setting; still consume any cancellation.
    if(![self dispatchBatch:batch valid:YES])return NO;
    if(!valid)return NO;
    [NSUserDefaults.standardUserDefaults setDouble:seconds forKey:resumeDelayKey];
    if(self.running)[self updateStatus];
    return YES;
}
- (BOOL)emit:(BTGestureEvent)event {
#ifdef BT_UNIFIED_DRIVER
    if(!self.running && !_unifiedCleaning)return NO;
#endif
    int64_t clicks=_clickCount;
    double t=now();
    if(event.kind==BTGesturePointerDown) {
        BOOL repeated=t-_lastDownAt<=[NSEvent doubleClickInterval] && hypot(event.x-_lastClickX,event.y-_lastClickY)<=8;
        clicks=repeated?MIN(_clickCount+1,3):1;
    }
    if(_postEvents) {
        CGEventRef native=BTCreateGestureEvent(event,clicks);
        if(!native)return NO;
        CGEventPost(kCGHIDEventTap,native);CFRelease(native);
    }
    switch(event.kind) {
        case BTGesturePointerDown:
            _clickCount=clicks;_lastDownAt=t;_lastClickX=event.x;_lastClickY=event.y;_downs++;
            _heldEvent=event;break;
        case BTGesturePointerDrag:_drags++;_heldEvent=event;break;
        case BTGesturePointerUp:_ups++;_heldEvent=(BTGestureEvent){0};break;
        case BTGestureScroll:case BTGestureMagnify:
            if(event.kind==BTGestureScroll)_scrollEvents++;else _magnifyEvents++;
            _heldEvent=(event.phase==BTGesturePhaseEnded || event.phase==BTGesturePhaseCancelled)?(BTGestureEvent){0}:event;
            break;
        case BTGesturePointerMove:break;
    }
    if(event.phase==BTGesturePhaseCancelled)_cancelEvents++;
    return YES;
}
- (BOOL)dispatchBatch:(BTGestureBatch)batch valid:(BOOL)valid {
    for(size_t i=0;i<batch.count;i++) {
        if(![self emit:batch.events[i]]) {
            [self stop];self.status=@"Could not create gesture event; multitouch disabled.";return NO;
        }
    }
    if(!valid){[self stop];self.status=@"Invalid gesture state; multitouch disabled.";return NO;}
    return YES;
}
- (void)cancelGesture {
    BTGestureBatch batch={0};BTGestureCancel(&_gestures,&batch);
    // Policy can already be idle after producing a tap batch. Release the output
    // actually dispatched, including when construction failed halfway through it.
    if(_heldEvent.phase!=BTGesturePhaseNone) {
        BTGestureEvent terminal=_heldEvent;terminal.phase=BTGesturePhaseCancelled;
        terminal.deltaX=terminal.deltaY=terminal.magnification=0;
        if(terminal.kind==BTGesturePointerDown || terminal.kind==BTGesturePointerDrag)terminal.kind=BTGesturePointerUp;
        (void)[self emit:terminal];
    }
}
- (void)updateStatus {
    if(_gestures.pen==BTPenUnknown){self.status=_penMonitor.status;return;}
    if(_gestures.pen==BTPenInRange){self.status=@"Pen in range — touch suppressed.";return;}
    double remaining=_gestures.penOutSeen?_gestures.config.resumeDelay-(now()-_gestures.penOutAt):0;
    if(remaining>0){self.status=[NSString stringWithFormat:@"Pen left — touch resumes in %.1f seconds. Lift resting fingers.",remaining];return;}
    if(_gestures.mode==BTGestureBlocked){self.status=@"Lift all fingers to resume touch.";return;}
    self.status=_postEvents?@"Multitouch ready — tap/drag, two-finger pan or pinch.":@"Observing touch and shared pen proximity — no configuration writes or input posting.";
}
- (void)penChanged:(BTPenPresence)presence {
    if(!self.running)return;
    BTGestureBatch batch={0};
    BOOL valid=BTGestureHandlePen(&_gestures,(BTGesturePenInput){presence,now()},&batch);
    if([self dispatchBatch:batch valid:valid])[self updateStatus];
}
- (void)received:(uint8_t *)bytes length:(CFIndex)length reportID:(uint32_t)reportID sender:(void *)sender result:(IOReturn)result {
    if(!self.running || !isTouch((IOHIDDeviceRef)sender))return;
    _rawReports++;
    NSString *key=[NSString stringWithFormat:@"%u",reportID];
    _rawReportIDs[key]=@([_rawReportIDs[key] unsignedIntegerValue]+1);
    if(reportID!=3 && reportID!=4)return;
    if(property((IOHIDDeviceRef)sender,kIOHIDPrimaryUsagePageKey)!=13)return;
    _reports++;BTTouchFrame frame={0};
    if(result!=kIOReturnSuccess || length<=0 || !bytes || bytes[0]!=reportID || !BTParseTouchReport(bytes,(size_t)length,&frame)){_invalid++;return;}
    _valid++;
    double time=now();
    if(reportID==4 && frame.count)_report4Seen=YES;
    if(_activeReportID==3 && reportID==4 && frame.count>1) {
        // Report3 cannot represent multiple contacts. Promote only for that
        // evidence; a duplicate one-contact report must not interrupt a drag.
        if(_gestures.mode!=BTGestureBlocked) {
            [self cancelGesture];
            if(_heldEvent.phase!=BTGesturePhaseNone){[self stop];self.status=@"Could not cancel previous touch stream; disabled.";return;}
            BTGestureBatch cleared={0};
            BOOL valid=BTGestureHandleTouch(&_gestures,(BTGestureTouchInput){.bounds=_bounds,.time=time},&cleared);
            if(![self dispatchBatch:cleared valid:valid])return;
        }
        _activeReportID=4;
    }
    if(!_activeReportID) {
        if(reportID==3 && _report4Seen)return;
        if(frame.count)_activeReportID=reportID;
    }
    if(_activeReportID && reportID!=_activeReportID)return;
    _contacts=frame.count;_lastFrameAt=time;
    BTGestureBatch batch={0};
    BOOL valid=BTGestureHandleTouch(&_gestures,(BTGestureTouchInput){frame,_bounds,time},&batch);
    if(![self dispatchBatch:batch valid:valid])return;
    if(!frame.count)_activeReportID=0;
    [self updateStatus];
}
- (void)tick:(NSTimer *)timer {
    (void)timer;if(!self.running)return;
    if(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)!=kIOHIDAccessTypeGranted) {
        [self stop];self.status=@"Input Monitoring permission lost; disabled. Grant access, then Enable again.";return;
    }
    BTDisplayBounds current=boundsFor(_display);
    if(current.x!=_bounds.x || current.y!=_bounds.y || current.width!=_bounds.width || current.height!=_bounds.height) {
        [self stop];self.status=@"Display changed. Select the Bosto display and Enable again.";return;
    }
    if(_postEvents && !CGPreflightPostEventAccess()){[self stop];self.status=@"Accessibility permission lost; disabled.";return;}
    double time=now();
    // Check freshness before arming a pending one-finger press.
    if(_contacts && time-_lastFrameAt>=0.5) {
        [self stop];
        self.status=@"Touch report timeout; disabled. Press Enable to retry.";
        return;
    }
    BTGestureBatch batch={0};BOOL valid=BTGestureTick(&_gestures,time,&batch);
    if([self dispatchBatch:batch valid:valid])[self updateStatus];
}
- (void)controllerRemoved:(IOHIDDeviceRef)device {
    if(self.running && isTouch(device)){[self stop];self.status=@"Touchscreen disconnected. Reconnect, then Enable.";}
}
- (void)controllerAdded:(IOHIDDeviceRef)device {
    if(self.running && isTouch(device) && ![_initialDevices containsObject:[NSValue valueWithPointer:device]]) {
        [self stop];self.status=@"Touch connection changed. Enable again.";
    }
}
- (void)displayChanged:(NSNotification *)note {(void)note;if(self.running)[self tick:nil];}
- (void)suspend:(NSNotification *)note {(void)note;[self stop];self.status=@"Paused for sleep/session change. Enable again after returning.";}
- (void)stop {
    self.running=NO;[self.watchdog invalidate];self.watchdog=nil;
#ifdef BT_UNIFIED_DRIVER
    if(_unifiedStopping)return;
    _penMonitor.presenceChanged=nil;[_penMonitor stop];
    if(!_manager)return;
    _unifiedStopping=YES;self.status=@"Disabled";
    dispatch_async(dispatch_get_main_queue(),^{[self unifiedCleanup];});
}
- (void)unifiedCleanup {
    _unifiedCleaning=YES;
#endif
    [self cancelGesture];
    _penMonitor.presenceChanged=nil;[_penMonitor stop];
    if(_manager) {
        IOHIDManagerRegisterInputReportCallback(_manager,NULL,NULL);
        IOHIDManagerRegisterDeviceRemovalCallback(_manager,NULL,NULL);
        IOHIDManagerRegisterDeviceMatchingCallback(_manager,NULL,NULL);
        if(_ownerLoop)IOHIDManagerUnscheduleFromRunLoop(_manager,_ownerLoop,kCFRunLoopCommonModes);
        if(_openAttempted)(void)IOHIDManagerClose(_manager,kIOHIDOptionsTypeSeizeDevice);
        CFRelease(_manager);_manager=NULL;
    }
    if(_ownerLoop){CFRelease(_ownerLoop);_ownerLoop=NULL;}
    _openAttempted=NO;_contacts=0;_activeReportID=0;[_initialDevices removeAllObjects];
    _postEvents=NO;
#ifdef BT_UNIFIED_DRIVER
    _unifiedCleaning=NO;_unifiedStopping=NO;
#else
    self.status=@"Disabled — pen driver unchanged.";
#endif
}
- (NSDictionary *)snapshot {
    return @{@"running":@(self.running),@"status":self.status?:@"",@"displayID":@(_display),@"interfaces":@(_devices),
             @"reports":@(_reports),@"rawReports":@(_rawReports),@"rawReportIDs":[_rawReportIDs copy]?:@{},@"activeReportID":@(_activeReportID),
             @"validFrames":@(_valid),@"invalidFrames":@(_invalid),@"activeContacts":@(_contacts),
             @"firmwareReport":@[@(_firmware[0]),@(_firmware[1]),@(_firmware[2])],@"configurationWrites":@(_configurationWrites),@"touchConfigurationAccepted":@(_touchConfigurationAccepted),
             @"pointerDown":@(_heldEvent.phase!=BTGesturePhaseNone && (_heldEvent.kind==BTGesturePointerDown || _heldEvent.kind==BTGesturePointerDrag)),
             @"downEvents":@(_downs),@"dragEvents":@(_drags),@"upEvents":@(_ups),@"scrollEvents":@(_scrollEvents),@"magnifyEvents":@(_magnifyEvents),@"cancelEvents":@(_cancelEvents),
             @"gestureMode":@(_gestures.mode),@"resumeDelay":@(self.resumeDelay),@"report4Seen":@(_report4Seen),
             @"cursorQuartz":@[@(_gestures.x),@(_gestures.y)],@"postsMouseEvents":@(_postEvents),@"postsGestureEvents":@(_postEvents),
             @"penObserver":_penMonitor.snapshot?:@{},@"penAccessed":@(_penMonitor.running),@"penSeized":@NO};
}
@end
