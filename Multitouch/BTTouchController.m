#import "BTTouchController.h"
#import "BTGestureEvents.h"
#import "BTPenMonitor.h"
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#include <math.h>
#ifdef BT_UNIFIED_DRIVER
#import <os/log.h>
#import "UnifiedPen.h"
#import "UnifiedMonitor.h"
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
#ifdef BT_UNIFIED_DRIVER
// Validate the nearest physical USB device, not an arbitrary ancestor (such as a hub).
// HID usage/VID/PID alone also describe lookalikes and do not prove siblinghood.
static BOOL unsignedPropertyEquals(CFTypeRef value, uint32_t expected) {
    int64_t n=0;
    return value && CFGetTypeID(value)==CFNumberGetTypeID() && !CFNumberIsFloatType(value) &&
        CFNumberGetValue(value,kCFNumberSInt64Type,&n) && n==expected;
}
static BOOL usbPropertyEquals(io_registry_entry_t usb, CFStringRef key, uint32_t expected) {
    CFTypeRef value=IORegistryEntryCreateCFProperty(usb,key,NULL,0);
    BOOL matches=unsignedPropertyEquals(value,expected);
    if(value)CFRelease(value);
    return matches;
}
static uint64_t touchUSBIdentity(IOHIDDeviceRef device, BOOL companion) {
    CFTypeRef transport=IOHIDDeviceGetProperty(device,CFSTR(kIOHIDTransportKey));
    CFTypeRef location=IOHIDDeviceGetProperty(device,CFSTR(kIOHIDLocationIDKey));
    int64_t port=0;
    if(!transport || !CFEqual(transport,CFSTR("USB")) || !location || CFGetTypeID(location)!=CFNumberGetTypeID() ||
       CFNumberIsFloatType(location) || !CFNumberGetValue(location,kCFNumberSInt64Type,&port) || port<=0 || port>UINT32_MAX)return 0;
    io_registry_entry_t service=IOHIDDeviceGetService(device),parent=IO_OBJECT_NULL;
    if(!service || IORegistryEntryGetParentEntry(service,kIOServicePlane,&parent)!=KERN_SUCCESS)return 0;
    BOOL verifiedInterface=!companion;
    while(parent){
        // Interface 0 is the documented native gesture companion, not just
        // any mouse collection provided by this composite USB device.
        if(companion && IOObjectConformsTo(parent,"IOUSBHostInterface")){
            if(!usbPropertyEquals(parent,CFSTR("bInterfaceNumber"),0)){IOObjectRelease(parent);return 0;}
            verifiedInterface=YES;
        }
        if(IOObjectConformsTo(parent,"IOUSBHostDevice")){
            uint64_t identity=0;
            BOOL valid=verifiedInterface && usbPropertyEquals(parent,CFSTR("idVendor"),0x6066) && usbPropertyEquals(parent,CFSTR("idProduct"),1) &&
                usbPropertyEquals(parent,CFSTR("locationID"),(uint32_t)port) && IORegistryEntryGetRegistryEntryID(parent,&identity)==KERN_SUCCESS;
            IOObjectRelease(parent);return valid?identity:0;
        }
        io_registry_entry_t next=IO_OBJECT_NULL;
        kern_return_t result=IORegistryEntryGetParentEntry(parent,kIOServicePlane,&next);
        IOObjectRelease(parent);if(result!=KERN_SUCCESS)return 0;
        parent=next;
    }
    return 0;
}
// Pin the actual retained HID objects before the first exclusive open. No opened
// manager or matching notification can extend these claims to hot-plugged devices.
static NSArray *selectedTouchDevices(BOOL requireCompanion){
    IOHIDManagerRef discovery=IOHIDManagerCreate(NULL,kIOHIDManagerOptionIndependentDevices);
    if(!discovery)return nil;
    // Only Compatibility with the pen muted can work without the companion.
    NSArray *matches=requireCompanion?matching():@[matching().firstObject];
    IOHIDManagerSetDeviceMatchingMultiple(discovery,(__bridge CFArrayRef)matches);
    NSSet *devices=CFBridgingRelease(IOHIDManagerCopyDevices(discovery));
    CFRelease(discovery);
    if(devices.count!=(requireCompanion?2:1))return nil;
    id digitizer=nil,companion=nil;uint64_t physical=0;
    for(id object in devices){
        IOHIDDeviceRef device=(__bridge IOHIDDeviceRef)object;
        if(!isTouch(device))return nil;
        BOOL isCompanion=property(device,kIOHIDPrimaryUsagePageKey)==1;
        uint64_t identity=touchUSBIdentity(device,isCompanion);
        if(!identity || (physical && physical!=identity))return nil;
        physical=identity;
        if(isCompanion)companion=object;else digitizer=object;
    }
    if(!digitizer || (requireCompanion && !companion))return nil;
    return requireCompanion?@[digitizer,companion]:@[digitizer];
}
NSArray<NSNumber *> *BTTabletRegistryIdentity(void) {
    IOHIDManagerRef manager=IOHIDManagerCreate(NULL,kIOHIDManagerOptionIndependentDevices);
    if(!manager)return nil;
    IOHIDManagerSetDeviceMatchingMultiple(manager,(__bridge CFArrayRef)@[matching().firstObject]);
    NSSet *devices=CFBridgingRelease(IOHIDManagerCopyDevices(manager));
    CFRelease(manager);
    if(devices.count!=1)return nil;
    IOHIDDeviceRef d=(__bridge IOHIDDeviceRef)devices.anyObject;
    uint64_t identity=0;
    if(!isTouch(d) || property(d,kIOHIDPrimaryUsagePageKey)!=13 || !touchUSBIdentity(d,NO) ||
       IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(d),&identity)!=KERN_SUCCESS || !identity)return nil;
    // A pen change must neither block startup nor rearm a previously failed session.
    return @[@(identity)];
}
#endif
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
    CFRunLoopRef _ownerLoop;
#ifndef BT_UNIFIED_DRIVER
    IOHIDManagerRef _manager;
    BOOL _openAttempted;
    NSMutableSet<NSValue *> *_initialDevices;
#endif
#ifdef BT_UNIFIED_DRIVER
    BOOL _unifiedStopping,_unifiedCleaning,_touchReportExpired,_sessionPenEnabled;
    BOOL _sessionTouchEnabled,_sessionNativeTouchEnabled;
    BOOL _nativeAwaitingLift; // Contact already in progress at startup or an unreadable report 4.
    NSArray *_pinnedTouches;
    NSUInteger _openedTouchCount,_scheduledTouchCount;
    BOOL _initializingTouch,_palmCompanionHeld,_touchLevelKnown;
    unsigned _unclearedStreams; // Held or uncertain level per format, including ignored duplicates.
    uint8_t _reportBuffer[BT_TOUCH_REPORT_SIZE];
#endif
    BTGestureState _gestures;
    BTGestureEvent _heldEvent;
    BTPenMonitor *_penMonitor;
    BTDisplayBounds _bounds;
    CGDirectDisplayID _display;
    BOOL _postEvents;
    NSUInteger _devices, _reports, _rawReports, _valid, _invalid, _downs, _drags, _ups, _contacts;
    NSUInteger _multiContactFrames, _peakContacts, _moves;
#ifdef BT_UNIFIED_DRIVER
    id _activeGestureAction;
    BOOL _gestureShortcutConsumed;
#endif
    NSUInteger _scrollEvents, _magnifyEvents, _cancelEvents;
    uint32_t _activeReportID;
    BOOL _report4Seen, _vendorNeedsLift;
    double _report4PreferredUntil;
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
#ifndef BT_UNIFIED_DRIVER
- (void)controllerAdded:(IOHIDDeviceRef)device;
#endif
- (void)penChanged:(BTPenPresence)presence;
@end
static void received(void *context,IOReturn result,void *sender,IOHIDReportType type,uint32_t reportID,uint8_t *bytes,CFIndex length) {
    if(type==kIOHIDReportTypeInput) [(__bridge BTTouchController *)context received:bytes length:length reportID:reportID sender:sender result:result];
}
#ifdef BT_UNIFIED_DRIVER
static void touchDeviceRemoved(void *context,IOReturn result,void *sender){
    (void)result;[(__bridge BTTouchController *)context controllerRemoved:(IOHIDDeviceRef)sender];
}
#else
static void removed(void *context,IOReturn result,void *sender,IOHIDDeviceRef device) {
    (void)result;(void)sender;[(__bridge BTTouchController *)context controllerRemoved:device];
}
static void added(void *context,IOReturn result,void *sender,IOHIDDeviceRef device) {
    (void)result;(void)sender;[(__bridge BTTouchController *)context controllerAdded:device];
}

#endif

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
        _touchInputEnabled=_penInputEnabled=_nativeTouchEnabled=_sessionNativeTouchEnabled=YES;
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
// Synchronous HID calls during startup may deliver a pen/removal callback.
// A failed callback must not be overwritten by the rest of startup.
- (BOOL)startupStopped:(NSError **)error {
    if(!_unifiedStopping && _pinnedTouches)return NO;
    if(error)*error=[NSError errorWithDomain:@"local.BostoTablet" code:10 userInfo:@{NSLocalizedDescriptionKey:self.status}];
    return YES;
}
- (void)unifiedPenFailed:(NSNotification *)note {
    if(note.object!=_penMonitor)return;
    [self stop];self.status=note.userInfo[@"reason"]?:@"Unified pen failed; both streams disabled.";
}
#endif
- (BOOL)initializeDigitizer:(IOHIDDeviceRef)digitizer configure:(BOOL)configure error:(NSError **)error {
    _firmware[0]=9;CFIndex versionLength=sizeof _firmware;
    IOReturn result=IOHIDDeviceGetReport(digitizer,kIOHIDReportTypeFeature,9,_firmware,&versionLength);
#ifdef BT_UNIFIED_DRIVER
    if([self startupStopped:error])return NO;
#endif
    if(result!=kIOReturnSuccess || versionLength!=3 || _firmware[0]!=9 || _firmware[1]!=1 || _firmware[2]!=26){
        return [self fail:@"Unexpected touch-controller firmware; no configuration written." code:5 error:error];
    }
    if(configure){
        // Exact signed manufacturer command; approved for this firmware only.
        // Enables touch on 6066:0001. Never sent to a pen, and never a firmware flash.
        const uint8_t command[3]={3,0x0b,0};_configurationWrites++;
        result=IOHIDDeviceSetReport(digitizer,kIOHIDReportTypeFeature,3,command,sizeof command);
#ifdef BT_UNIFIED_DRIVER
        if([self startupStopped:error])return NO;
#endif
        if(result!=kIOReturnSuccess){
            return [self fail:[NSString stringWithFormat:@"Touch initialization failed (0x%08x); pen unchanged.",result] code:result error:error];
        }
        _touchConfigurationAccepted=YES;
    }
    return YES;
}
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
    _multiContactFrames=_peakContacts=_moves=0;
#ifdef BT_UNIFIED_DRIVER
    _gestureShortcutConsumed=NO;
#endif
    _scrollEvents=_magnifyEvents=_cancelEvents=0;_heldEvent=(BTGestureEvent){0};
    BTGestureConfig config=BTGestureDefaultConfig();config.resumeDelay=self.resumeDelay;
#ifdef BT_UNIFIED_DRIVER
    _sessionNativeTouchEnabled=self.nativeTouchEnabled;
    config.nativeSinglePointer=_sessionNativeTouchEnabled;
    config.allowTouchBeforePenReport=true;
#endif
    (void)BTGestureInit(&_gestures,config);
#ifdef BT_UNIFIED_DRIVER
    _touchReportExpired=NO;
#endif
    _activeReportID=0;_report4Seen=_vendorNeedsLift=NO;_report4PreferredUntil=-INFINITY;
    _rawReportIDs=[NSMutableDictionary dictionary];
    memset(_firmware,0,sizeof _firmware);_configurationWrites=0;_touchConfigurationAccepted=NO;
    _lastFrameAt=now();_lastDownAt=-INFINITY;_clickCount=1;
#ifdef BT_UNIFIED_DRIVER
    _sessionTouchEnabled=self.touchInputEnabled;
    _nativeAwaitingLift=NO;
    _postEvents=_sessionTouchEnabled;
    _sessionPenEnabled=self.penInputEnabled;
    _pinnedTouches=selectedTouchDevices(!_sessionTouchEnabled || _sessionNativeTouchEnabled || _sessionPenEnabled);
    if(!_pinnedTouches)return [self fail:@"Could not identify the exact Bosto USB touch interfaces for this mode; nothing opened." code:4 error:error];
    _touchLevelKnown=NO;_unclearedStreams=0;
    IOHIDDeviceRef digitizer=(__bridge IOHIDDeviceRef)_pinnedTouches[0];
#else
    _postEvents=postEvents;
    _initialDevices=[NSMutableSet set];
    _manager=IOHIDManagerCreate(NULL,kIOHIDOptionsTypeNone);
    if(!_manager)return [self fail:@"Could not create touchscreen connection." code:4 error:error];
    IOHIDManagerSetDeviceMatchingMultiple(_manager,(__bridge CFArrayRef)matching());
    __attribute__((objc_precise_lifetime)) NSSet *devices=CFBridgingRelease(IOHIDManagerCopyDevices(_manager));
    IOHIDDeviceRef digitizer=NULL;NSUInteger digitizers=0;BOOL unexpected=NO;
    for(id object in devices) {
        IOHIDDeviceRef device=(__bridge IOHIDDeviceRef)object;
        if(isTouch(device)) {
            [_initialDevices addObject:[NSValue valueWithPointer:device]];
            _devices++;if(property(device,kIOHIDPrimaryUsagePageKey)==13){digitizer=device;digitizers++;}
        } else unexpected=YES;
    }
    if(digitizers!=1 || _devices>2 || unexpected) {
        return [self fail:@"Expected one Bosto touch controller. Check its USB connection." code:4 error:error];
    }
#endif
    __weak BTTouchController *weakSelf=self;
#ifdef BT_UNIFIED_DRIVER
    _initializingTouch=_sessionTouchEnabled;
    _ownerLoop=(CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
    for(id object in _pinnedTouches){
        IOHIDDeviceRef device=(__bridge IOHIDDeviceRef)object;
        // Monitor the pinned companion for removal. Only mute or palm rejection may seize it.
        if(device==digitizer || !_sessionTouchEnabled){
            IOReturn result=IOHIDDeviceOpen(device,kIOHIDOptionsTypeSeizeDevice);
            if(result!=kIOReturnSuccess){
                return [self fail:[NSString stringWithFormat:@"Cannot claim the selected Bosto touch interface (0x%08x).",result] code:result error:error];
            }
            _openedTouchCount++;_devices=_openedTouchCount+(_palmCompanionHeld?1:0);
        }
        IOHIDDeviceRegisterRemovalCallback(device,touchDeviceRemoved,(__bridge void *)self);
        if(device==digitizer && _sessionTouchEnabled)IOHIDDeviceRegisterInputReportCallback(device,_reportBuffer,sizeof _reportBuffer,received,(__bridge void *)self);
        IOHIDDeviceScheduleWithRunLoop(device,_ownerLoop,kCFRunLoopCommonModes);
        _scheduledTouchCount++;
        if([self startupStopped:error])return NO;
    }
#else
    _penMonitor=[BTPenMonitor new];
    _penMonitor.presenceChanged=^(BTPenPresence presence){[weakSelf penChanged:presence];};
    NSError *penError=nil;
    if(![_penMonitor startWithError:&penError])return [self fail:penError.localizedDescription code:6 error:error];
    IOHIDManagerRegisterInputReportCallback(_manager,received,(__bridge void *)self);
    IOHIDManagerRegisterDeviceRemovalCallback(_manager,removed,(__bridge void *)self);
    IOHIDManagerRegisterDeviceMatchingCallback(_manager,added,(__bridge void *)self);
    // Reports and watchdog must both run during AppKit tracking/modal loops.
    _ownerLoop=(CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
    IOHIDManagerScheduleWithRunLoop(_manager,_ownerLoop,kCFRunLoopCommonModes);
    _openAttempted=YES;
    IOReturn result=IOHIDManagerOpen(_manager,kIOHIDOptionsTypeSeizeDevice);
    if(result!=kIOReturnSuccess){
        return [self fail:[NSString stringWithFormat:@"Cannot open touchscreen (0x%08x); pen observation was shared only.",result] code:result error:error];
    }
#endif
#ifdef BT_UNIFIED_DRIVER
    // Seizing both exact interfaces is sufficient to mute; do not configure them.
    if(_sessionTouchEnabled && ![self initializeDigitizer:digitizer configure:YES error:error])return NO;
    _initializingTouch=NO;
    self.running=YES; // Finger reports can be processed before any pen discovery or open.
    _penMonitor=[BTPenMonitor new];
    _penMonitor.penInputEnabled=_sessionPenEnabled;
    _penMonitor.presenceChanged=^(BTPenPresence presence){[weakSelf penChanged:presence];};
    if(_sessionTouchEnabled){
        // Return the initialized touch session before attempting pen discovery. Keep
        // both producers on the owner loop for synchronous palm-before-pen ordering.
        BTPenMonitor *sessionMonitor=_penMonitor;
        dispatch_async(dispatch_get_main_queue(),^{
            if(!self.running || self->_penMonitor!=sessionMonitor)return;
            NSError *failure=nil;
            if(![sessionMonitor startAllowingUnavailablePen:YES error:&failure] && self.running){
                [self stop];self.status=failure.localizedDescription;
            }
        });
    }else{
        NSError *failure=nil;
        if(![_penMonitor startWithError:&failure])return [self fail:failure.localizedDescription code:6 error:error];
    }
#else
    if(![self initializeDigitizer:digitizer configure:postEvents error:error])return NO;
    self.running=YES;
#endif
    [self penChanged:_penMonitor.presence];
#ifdef BT_UNIFIED_DRIVER
    if([self startupStopped:error])return NO;
#endif
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
    if(self.running)[self refreshTouchState];
    return YES;
}
- (BOOL)emit:(BTGestureEvent)event {
#ifdef BT_UNIFIED_DRIVER
    if(!_postEvents)return YES; // Mute: no posted events or posted counters.
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
        case BTGesturePointerMove:_moves++;break;
    }
    if(event.phase==BTGesturePhaseCancelled)_cancelEvents++;
    return YES;
}
#ifdef BT_UNIFIED_DRIVER
@synthesize gestureActions=_gestureActions;
- (void)setGestureActions:(NSDictionary *)actions {
    NSMutableDictionary *checked=[NSMutableDictionary dictionary];
    if([actions isKindOfClass:NSDictionary.class]) {
        for(NSString *key in @[@"swipe",@"pinch"]){
            id value=actions[key];
            if([value isEqual:@"off"] || [value isEqual:@"shortcut"])checked[key]=[value copy];
            else checked[key]=UPValidatedShortcut(value);
        }
    }
    _gestureActions=[checked copy];
}
- (id)actionForGesture:(BTGestureEvent)event {
    if(event.kind==BTGestureScroll)return self.gestureActions[@"swipe"];
    if(event.kind==BTGestureMagnify)return self.gestureActions[@"pinch"];
    return nil;
}
- (BOOL)consumeGestureOverride:(BTGestureEvent)event {
    if(event.kind!=BTGestureScroll && event.kind!=BTGestureMagnify)return NO;
    if(event.phase==BTGesturePhaseBegan){
        _activeGestureAction=[self actionForGesture:event];
        if(UPShortcutCaptureActive())_gestureShortcutConsumed=YES;
    }
    if(event.phase==BTGesturePhaseChanged && !_gestureShortcutConsumed){
        // A resumed native gesture is fine after a gap; a held contact sequence
        // must not play a new shortcut until report 4 confirms a lift.
        _gestureShortcutConsumed=YES;
        if(_postEvents && !UPShortcutCaptureActive() && [_activeGestureAction isKindOfClass:NSDictionary.class]){
            NSDictionary *binding=_activeGestureAction;
            UPBatch keys={0};
            if(UPShortcutEvents([binding[@"key"] unsignedShortValue],[binding[@"modifiers"] unsignedLongLongValue],&keys)){
                for(size_t i=0;i<keys.count;i++)CGEventPost(kCGHIDEventTap,keys.events[i]);
                UPClear(&keys);
            } else os_log_error(OS_LOG_DEFAULT,"BostoTablet: could not construct touch gesture shortcut.");
        }
    }
    BOOL overridden=_activeGestureAction!=nil;
    if(event.phase==BTGesturePhaseEnded || event.phase==BTGesturePhaseCancelled)_activeGestureAction=nil;
    return overridden;
}
#endif
- (BOOL)dispatchBatch:(BTGestureBatch)batch valid:(BOOL)valid {
    for(size_t i=0;i<batch.count;i++) {
#ifdef BT_UNIFIED_DRIVER
        // Never route an anchor for a gesture that the driver will not post.
        BTGestureEvent event=batch.events[i];
        if(event.kind==BTGesturePointerMove && i+1<batch.count &&
           batch.events[i+1].phase==BTGesturePhaseBegan &&
           (_sessionNativeTouchEnabled || [self actionForGesture:batch.events[i+1]]))continue;
        if(_sessionNativeTouchEnabled){
            if(event.kind==BTGestureScroll || event.kind==BTGestureMagnify)continue;
        }else if([self consumeGestureOverride:event])continue;
#endif
        if(![self emit:batch.events[i]]) {
            [self stop];self.status=@"Could not create gesture event; multitouch disabled.";return NO;
        }
    }
    if(!valid){[self stop];self.status=@"Invalid gesture state; multitouch disabled.";return NO;}
    return YES;
}
- (BOOL)releaseHeldGesture {
#ifdef BT_UNIFIED_DRIVER
    _activeGestureAction=nil;
#endif
    // Policy can already be idle after a tap batch. Release actual output.
    if(_heldEvent.phase==BTGesturePhaseNone)return YES;
    BTGestureEvent terminal=_heldEvent;terminal.phase=BTGesturePhaseCancelled;
    terminal.deltaX=terminal.deltaY=terminal.magnification=0;
    if(terminal.kind==BTGesturePointerDown || terminal.kind==BTGesturePointerDrag)terminal.kind=BTGesturePointerUp;
    return [self emit:terminal];
}
- (void)cancelGesture {
    BTGestureBatch batch={0};BTGestureCancel(&_gestures,&batch);
    (void)[self releaseHeldGesture];
}
#ifdef BT_UNIFIED_DRIVER
@synthesize flipTouchY=_flipTouchY;
- (void)setFlipTouchY:(BOOL)flipTouchY {
    if(_flipTouchY==flipTouchY)return;
    if(self.running){
        // If release cannot be constructed, keep the current mapping and
        // gesture so the real lift can finish it. Do not interrupt the pen.
        if(![self releaseHeldGesture])return;
        BTGestureBatch batch={0};BTGestureCancel(&_gestures,&batch);
        [self refreshTouchState];
    }
    _flipTouchY=flipTouchY;
}
// A resumed report can beat a delayed watchdog on the run loop. In Native,
// expire the old sequence before accepting that report as a click or drag.
- (BOOL)expireSilentTouchAt:(double)time {
    if(!_contacts || _touchReportExpired || time-_lastFrameAt<0.5)return YES;
    _touchReportExpired=YES;
    BTGestureBatch cancelled={0};BTGestureCancelForReportGap(&_gestures,time,&cancelled);
    if([self releaseHeldGesture])return YES;
    [self stop];self.status=@"Could not cancel silent touch stream; disabled.";return NO;
}
// The pen monitor publishes proximity synchronously on the owner loop before posting pen events.
- (BOOL)acquirePalmCompanion {
    if(_palmCompanionHeld)return YES;
    IOHIDDeviceRef device=(__bridge IOHIDDeviceRef)_pinnedTouches[1];
    IOReturn result=IOHIDDeviceOpen(device,kIOHIDOptionsTypeSeizeDevice);
    if(result!=kIOReturnSuccess){
        [self stop];self.status=[NSString stringWithFormat:@"Cannot claim the Bosto native touch companion (0x%08x); palm rejection unavailable, driver stopped.",result];return NO;
    }
    _palmCompanionHeld=YES;_devices=_openedTouchCount+1;return YES;
}
- (BOOL)releasePalmCompanionIfReady:(double)time {
    if(!_palmCompanionHeld || _gestures.pen!=BTPenOutOfRange || !_gestures.penOutSeen ||
       time-_gestures.penOutAt<_gestures.config.resumeDelay || !_touchLevelKnown || _unclearedStreams)return YES;
    IOHIDDeviceRef device=(__bridge IOHIDDeviceRef)_pinnedTouches[1];
    IOReturn result=IOHIDDeviceClose(device,kIOHIDOptionsTypeSeizeDevice);
    if(result!=kIOReturnSuccess){
        [self stop];self.status=[NSString stringWithFormat:@"Cannot release the Bosto native touch companion (0x%08x); driver stopped.",result];return NO;
    }
    _palmCompanionHeld=NO;_devices=_openedTouchCount;
    // Proximity already cancelled any gesture. End its blocked contact sequence
    // only on a known clean boundary, never by synthesizing a timeout lift.
    _contacts=0;_activeReportID=0;_vendorNeedsLift=NO;_touchReportExpired=NO;_gestureShortcutConsumed=NO;
    BTGestureBatch batch={0};
    BOOL valid=BTGestureHandleTouch(&_gestures,(BTGestureTouchInput){.bounds=_bounds,.time=time},&batch);
    return [self dispatchBatch:batch valid:valid];
}
#endif
- (void)refreshTouchState {
#ifdef BT_UNIFIED_DRIVER
    if(![self releasePalmCompanionIfReady:now()])return;
    if(!_sessionTouchEnabled){self.status=_sessionPenEnabled?@"Touch muted — pen enabled.":@"Touch and pen muted — driver running.";return;}
#endif
    if([self touchReadiness]==BTGestureReadinessUnknown){self.status=_penMonitor.status;return;}
    if(_gestures.pen==BTPenInRange){self.status=@"Pen in range — touch suppressed.";return;}
    double remaining=_gestures.penOutSeen?_gestures.config.resumeDelay-(now()-_gestures.penOutAt):0;
    if(remaining>0){self.status=[NSString stringWithFormat:@"Pen left — touch resumes in %.1f seconds. Lift resting fingers.",remaining];return;}
#ifdef BT_UNIFIED_DRIVER
    if(_palmCompanionHeld){self.status=@"Lift all fingers to resume native Bosto touch.";return;}
    if(_sessionNativeTouchEnabled){
        self.status=([self touchReadiness]==BTGestureReadinessLiftRequired)?@"Lift all fingers to resume the absolute pointer; macOS handles gestures.":
            (_report4Seen?@"Single-finger pointer uses report 4; macOS handles multitouch gestures.":
             @"Waiting for report 4 for the absolute pointer; macOS handles multitouch gestures.");
        return;
    }
#endif
    if(_gestures.mode==BTGestureBlocked){self.status=@"Lift all fingers to resume touch.";return;}
    self.status=_postEvents?@"Multitouch ready — tap/drag, two-finger pan or pinch.":@"Observing touch and shared pen proximity — no configuration writes or input posting.";
}
- (void)penChanged:(BTPenPresence)presence {
#ifdef BT_UNIFIED_DRIVER
    if(!self.running)return;
    if(!_sessionTouchEnabled || !_sessionPenEnabled){[self refreshTouchState];return;}
    if(presence==BTPenInRange && ![self acquirePalmCompanion])return;
#else
    if(!self.running)return;
#endif
    BTGestureBatch batch={0};
    BOOL valid=BTGestureHandlePen(&_gestures,(BTGesturePenInput){presence,now()},&batch);
    if([self dispatchBatch:batch valid:valid])[self refreshTouchState];
}
- (void)received:(uint8_t *)bytes length:(CFIndex)length reportID:(uint32_t)reportID sender:(void *)sender result:(IOReturn)result {
#ifdef BT_UNIFIED_DRIVER
    if((!self.running && !_initializingTouch) || !_sessionTouchEnabled || sender!=(__bridge void *)_pinnedTouches.firstObject)return;
#else
    if(!self.running || !isTouch((IOHIDDeviceRef)sender))return;
#endif
    _rawReports++;
    NSString *key=[NSString stringWithFormat:@"%u",reportID];
    _rawReportIDs[key]=@([_rawReportIDs[key] unsignedIntegerValue]+1);
    if(reportID!=3 && reportID!=4)return;
    if(property((IOHIDDeviceRef)sender,kIOHIDPrimaryUsagePageKey)!=13)return;
    _reports++;BTTouchFrame frame={0};
    if(result!=kIOReturnSuccess || length<=0 || !bytes || bytes[0]!=reportID || !BTParseTouchReport(bytes,(size_t)length,&frame)){
#ifdef BT_UNIFIED_DRIVER
        // A missing/malformed sample may be a down. Do not hand a potentially
        // held contact to macOS based on an older clear from either format.
        _unclearedStreams|=1u<<reportID;
        if(_sessionNativeTouchEnabled && reportID==4){
            _nativeAwaitingLift=YES;
            [self cancelGesture]; // The unreadable frame might have added a second finger.
            if(_heldEvent.phase!=BTGesturePhaseNone){[self stop];self.status=@"Could not release interrupted touch; disabled.";}
        }
#endif
        _invalid++;return;
    }
    _valid++;
    _peakContacts=MAX(_peakContacts,frame.count);
    if(frame.count>=2)_multiContactFrames++;
    if(reportID==4 && frame.count)_report4Seen=YES;
    double time=now();
#ifdef BT_UNIFIED_DRIVER
    // Observe both formats before arbitration: the losing stream can still
    // report a held finger, and a zero from the other is not proof of its lift.
    unsigned stream=1u<<reportID;
    _touchLevelKnown=YES;
    if(frame.count)_unclearedStreams|=stream;else _unclearedStreams&=~stream;
    if(_sessionNativeTouchEnabled && reportID==3){
        // A vendor mouse packet has no contact count. It cannot start, extend
        // or lift a direct pointer; it is still evidence for the palm guard.
        [self refreshTouchState];return;
    }
    if(_sessionNativeTouchEnabled && (!self.running || !frame.count))_nativeAwaitingLift=frame.count!=0;
    if(_palmCompanionHeld || !self.running || _nativeAwaitingLift){
        // During startup remember contacts but never synthesize touch events.
        if(reportID==4 && (frame.count || _activeReportID==4))_report4PreferredUntil=time+0.5;
        _contacts=_sessionNativeTouchEnabled?frame.count:(frame.count?:(_unclearedStreams?1:0));_lastFrameAt=time;
        [self refreshTouchState];return;
    }
    if(_sessionNativeTouchEnabled && ![self expireSilentTouchAt:time])return;
#endif
    if(reportID==4) {
        // A live contact or its release may have trailing duplicates. Idle
        // empty report 4 packets must not keep the fallback locked out.
        if(frame.count || _activeReportID==4)_report4PreferredUntil=time+0.5;
    } else {
        if(!frame.count)_vendorNeedsLift=NO;
        else if(_activeReportID==4 || (!_activeReportID && time<_report4PreferredUntil))_vendorNeedsLift=YES;
        if(_vendorNeedsLift)return;
    }
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
        _vendorNeedsLift=YES;
        _activeReportID=4;
    }
    if(!_activeReportID) {
        if(frame.count)_activeReportID=reportID;
    }
    if(_activeReportID && reportID!=_activeReportID)return;
#ifdef BT_UNIFIED_DRIVER
    if(reportID==4 && !frame.count)_gestureShortcutConsumed=NO;
    if(self.flipTouchY) {
        for(size_t i=0;i<frame.count;i++)
            frame.contacts[i].y=(uint16_t)(BT_TOUCH_Y_MAX-MIN(frame.contacts[i].y,BT_TOUCH_Y_MAX));
    }
#endif
    _contacts=frame.count;_lastFrameAt=time;
    BTGestureBatch batch={0};
    BOOL valid=BTGestureHandleTouch(&_gestures,(BTGestureTouchInput){frame,_bounds,time},&batch);
    if(![self dispatchBatch:batch valid:valid])return;
    if(!frame.count)_activeReportID=0;
#ifdef BT_UNIFIED_DRIVER
    if(!frame.count || (frame.count==2 && _gestures.mode==BTGestureTwoPending))_touchReportExpired=NO;
#endif
    [self refreshTouchState];
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
#ifdef BT_UNIFIED_DRIVER
    BOOL checkPostAccess=_sessionTouchEnabled;
#else
    BOOL checkPostAccess=_postEvents;
#endif
    if(checkPostAccess && !CGPreflightPostEventAccess()){[self stop];self.status=@"Accessibility permission lost; disabled.";return;}
#ifdef BT_UNIFIED_DRIVER
    if(!_sessionTouchEnabled)return;
    if(_palmCompanionHeld){[self refreshTouchState];return;}
#endif
    double time=now();
    // Check freshness before arming a pending one-finger press.
#ifdef BT_UNIFIED_DRIVER
    if(![self expireSilentTouchAt:time])return;
#else
    if(_contacts && time-_lastFrameAt>=0.5) {
        [self stop];
        self.status=@"Touch report timeout; disabled. Press Enable to retry.";
        return;
    }
#endif
    BTGestureBatch batch={0};BOOL valid=BTGestureTick(&_gestures,time,&batch);
    if([self dispatchBatch:batch valid:valid])[self refreshTouchState];
}
- (void)controllerRemoved:(IOHIDDeviceRef)device {
#ifdef BT_UNIFIED_DRIVER
    // Pinning starts the ownership window, including startup in muted modes.
    if(!_pinnedTouches || _unifiedStopping)return;
    // Do not re-read properties on an already detached service.
    if([_pinnedTouches indexOfObjectIdenticalTo:(__bridge id)device]==NSNotFound)return;
#else
    if(!self.running || !isTouch(device))return;
#endif
    [self stop];self.status=@"Touchscreen disconnected. Reconnect, then Enable.";
}
#ifndef BT_UNIFIED_DRIVER
- (void)controllerAdded:(IOHIDDeviceRef)device {
    if(self.running && isTouch(device) && ![_initialDevices containsObject:[NSValue valueWithPointer:device]]) {
        [self stop];self.status=@"Touch connection changed. Enable again.";
    }
}
#endif
- (void)displayChanged:(NSNotification *)note {(void)note;if(self.running)[self tick:nil];}
- (void)suspend:(NSNotification *)note {(void)note;[self stop];self.status=@"Paused for sleep/session change. Enable again after returning.";}
- (void)stop {
    self.running=NO;[self.watchdog invalidate];self.watchdog=nil;
#ifdef BT_UNIFIED_DRIVER
    _initializingTouch=NO;
    if(_unifiedStopping)return;
    _penMonitor.presenceChanged=nil;[_penMonitor stop];
    if(!_pinnedTouches)return;
    _unifiedStopping=YES;self.status=@"Disabled";
    dispatch_async(dispatch_get_main_queue(),^{[self unifiedCleanup];});
}
- (void)unifiedCleanup {
    _unifiedCleaning=YES;
#endif
    [self cancelGesture];
    _penMonitor.presenceChanged=nil;[_penMonitor stop];
#ifdef BT_UNIFIED_DRIVER
    for(NSUInteger i=0;i<_pinnedTouches.count;i++){
        IOHIDDeviceRef device=(__bridge IOHIDDeviceRef)_pinnedTouches[i];
        if(i<_scheduledTouchCount){
            if(i==0 && _sessionTouchEnabled)IOHIDDeviceRegisterInputReportCallback(device,_reportBuffer,sizeof _reportBuffer,NULL,NULL);
            IOHIDDeviceRegisterRemovalCallback(device,NULL,NULL);
            IOHIDDeviceUnscheduleFromRunLoop(device,_ownerLoop,kCFRunLoopCommonModes);
        }
        if(i<_openedTouchCount || (i==1 && _palmCompanionHeld)){
            IOReturn result=IOHIDDeviceClose(device,kIOHIDOptionsTypeSeizeDevice);
            if(result!=kIOReturnSuccess)self.status=[NSString stringWithFormat:@"%@ Bosto HID close returned 0x%08x.",self.status,result];
        }
    }
    _palmCompanionHeld=NO;_openedTouchCount=_scheduledTouchCount=0;_pinnedTouches=nil;
#else
    if(_manager) {
        IOHIDManagerRegisterInputReportCallback(_manager,NULL,NULL);
        IOHIDManagerRegisterDeviceRemovalCallback(_manager,NULL,NULL);
        IOHIDManagerRegisterDeviceMatchingCallback(_manager,NULL,NULL);
        if(_ownerLoop)IOHIDManagerUnscheduleFromRunLoop(_manager,_ownerLoop,kCFRunLoopCommonModes);
        if(_openAttempted)(void)IOHIDManagerClose(_manager,kIOHIDOptionsTypeSeizeDevice);
        CFRelease(_manager);_manager=NULL;
    }
    _openAttempted=NO;[_initialDevices removeAllObjects];
#endif
    if(_ownerLoop){CFRelease(_ownerLoop);_ownerLoop=NULL;}
    _contacts=0;_activeReportID=0;
    _postEvents=NO;
#ifdef BT_UNIFIED_DRIVER
    _unifiedCleaning=NO;_unifiedStopping=NO;
#else
    self.status=@"Disabled — pen driver unchanged.";
#endif
}
- (BTGestureReadiness)touchReadiness {
    if(!self.running)return BTGestureReadinessUnknown;
    BTGestureReadiness readiness=BTGestureGetReadiness(&_gestures,now());
#ifdef BT_UNIFIED_DRIVER
    if(_sessionNativeTouchEnabled && _sessionTouchEnabled && !_sessionPenEnabled && !_gestures.clockValid)readiness=BTGestureReadinessReady;
    if((_palmCompanionHeld || _nativeAwaitingLift) && readiness==BTGestureReadinessReady)readiness=BTGestureReadinessLiftRequired;
#endif
    return readiness;
}
- (NSDictionary *)snapshot {
    NSDictionary *pen=_penMonitor.snapshot?:@{};
    return @{
#ifdef BT_UNIFIED_DRIVER
             @"touchRunningWithoutPen":@(self.running && _touchConfigurationAccepted && _penMonitor.unavailable),
             @"palmCompanionHeld":@(_palmCompanionHeld),
             @"nativeTouchEnabled":@(_sessionNativeTouchEnabled),
#endif
             @"running":@(self.running),@"status":self.status?:@"",@"displayID":@(_display),@"interfaces":@(_devices),
             @"reports":@(_reports),@"rawReports":@(_rawReports),@"rawReportIDs":[_rawReportIDs copy]?:@{},@"activeReportID":@(_activeReportID),
             @"validFrames":@(_valid),@"invalidFrames":@(_invalid),@"activeContacts":@(_contacts),@"peakContacts":@(_peakContacts),@"multiContactFrames":@(_multiContactFrames),
             @"firmwareReport":@[@(_firmware[0]),@(_firmware[1]),@(_firmware[2])],@"configurationWrites":@(_configurationWrites),@"touchConfigurationAccepted":@(_touchConfigurationAccepted),
             @"pointerDown":@(_heldEvent.phase!=BTGesturePhaseNone && (_heldEvent.kind==BTGesturePointerDown || _heldEvent.kind==BTGesturePointerDrag)),
             @"moveEvents":@(_moves),@"downEvents":@(_downs),@"dragEvents":@(_drags),@"upEvents":@(_ups),@"scrollEvents":@(_scrollEvents),@"magnifyEvents":@(_magnifyEvents),@"cancelEvents":@(_cancelEvents),
             @"gestureReadiness":@([self touchReadiness]),@"gestureMode":@(_gestures.mode),@"resumeDelay":@(self.resumeDelay),@"report4Seen":@(_report4Seen),
             @"cursorQuartz":@[@(_gestures.x),@(_gestures.y)],
#ifdef BT_UNIFIED_DRIVER
             @"postsMouseEvents":@(self.running && _postEvents),@"postsGestureEvents":@(self.running && _postEvents && !_sessionNativeTouchEnabled),
#else
             @"postsMouseEvents":@(_postEvents),@"postsGestureEvents":@(_postEvents),
#endif
             @"penObserver":pen,
#ifdef BT_UNIFIED_DRIVER
             @"penAccessed":pen[@"seized"]?:@NO,@"penSeized":pen[@"seized"]?:@NO};
#else
             @"penAccessed":@(_penMonitor.running),@"penSeized":@NO};
#endif
}
@end
