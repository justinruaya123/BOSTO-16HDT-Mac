#import "UnifiedMonitor.h"
#import "UnifiedPen.h"
#import "PenBattery.h"
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <os/log.h>
NSString *const UPFailureNotification=@"UnifiedPenFailed";
static CGDirectDisplayID selectedDisplay;
static double pressureExponent=1;
static NSArray *shortcutBindings;
NSArray *UPValidatedBindings(id value) {
    NSMutableArray *result=[NSMutableArray array];
    for(NSUInteger i=0;i<2;i++) {
        id binding=[value isKindOfClass:NSArray.class] && [value count]==2?value[i]:nil;
        [result addObject:UPValidatedShortcut(binding)?:NSNull.null];
    }
    return result;
}
static uint32_t penUnsignedNumber(CFTypeRef v) {
    int64_t n=0;
    if(!v || CFGetTypeID(v)!=CFNumberGetTypeID() || CFNumberIsFloatType(v) || !CFNumberGetValue(v,kCFNumberSInt64Type,&n) || n<0 || n>UINT32_MAX)return UINT32_MAX;
    return (uint32_t)n;
}
static uint32_t number(IOHIDDeviceRef d,CFStringRef key) {
    return penUnsignedNumber(IOHIDDeviceGetProperty(d,key));
}
static BOOL penUSBPropertyMatches(io_registry_entry_t node,CFStringRef key,uint32_t expected) {
    CFTypeRef value=IORegistryEntryCreateCFProperty(node,key,NULL,0);
    BOOL matches=penUnsignedNumber(value)==expected;
    if(value)CFRelease(value);
    return matches;
}
static BOOL penHasUSBParent(IOHIDDeviceRef d,uint32_t location) {
    io_registry_entry_t service=IOHIDDeviceGetService(d),parent=IO_OBJECT_NULL;
    if(!service || IORegistryEntryGetParentEntry(service,kIOServicePlane,&parent)!=KERN_SUCCESS)return NO;
    while(parent){
        // Stop at the nearest physical device; a matching hub cannot vouch for its child.
        if(IOObjectConformsTo(parent,"IOUSBHostDevice")){
            BOOL matches=penUSBPropertyMatches(parent,CFSTR("idVendor"),0xed1) &&
                penUSBPropertyMatches(parent,CFSTR("idProduct"),0x7821) &&
                penUSBPropertyMatches(parent,CFSTR("locationID"),location);
            IOObjectRelease(parent);return matches;
        }
        io_registry_entry_t next=IO_OBJECT_NULL;
        kern_return_t result=IORegistryEntryGetParentEntry(parent,kIOServicePlane,&next);
        IOObjectRelease(parent);if(result!=KERN_SUCCESS)return NO;
        parent=next;
    }
    return NO;
}
uint64_t UPVerifiedPenRegistryID(IOHIDDeviceRef d) {
    if(!d)return 0;
    CFTypeRef transport=IOHIDDeviceGetProperty(d,CFSTR(kIOHIDTransportKey));
    uint32_t location=number(d,CFSTR(kIOHIDLocationIDKey));
    if(!transport || !CFEqual(transport,CFSTR("USB")) || !location || location==UINT32_MAX ||
       number(d,CFSTR(kIOHIDVendorIDKey))!=0xed1 || number(d,CFSTR(kIOHIDProductIDKey))!=0x7821 ||
       number(d,CFSTR(kIOHIDPrimaryUsagePageKey))!=13 || number(d,CFSTR(kIOHIDPrimaryUsageKey))!=2 || !penHasUSBParent(d,location))return 0;
    uint64_t identity=0;
    return IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(d),&identity)==KERN_SUCCESS?identity:0;
}
// Do not open the manager: it only enumerates exact HID candidates and notifies.
static IOHIDManagerRef UPCreatePenDiscoveryManager(void) {
    IOHIDManagerRef manager=IOHIDManagerCreate(NULL,kIOHIDManagerOptionIndependentDevices);
    if(manager){
        NSDictionary *match=@{@kIOHIDTransportKey:@"USB",@kIOHIDVendorIDKey:@0xed1,@kIOHIDProductIDKey:@0x7821,@kIOHIDPrimaryUsagePageKey:@13,@kIOHIDPrimaryUsageKey:@2};
        IOHIDManagerSetDeviceMatching(manager,(__bridge CFDictionaryRef)match);
    }
    return manager;
}
@interface BTPenMonitor () {
    IOHIDManagerRef _manager;
    IOHIDDeviceRef _device;
    CFRunLoopRef _loop;
    BOOL _seized,_managerScheduled,_deviceScheduled,_stopping,_penInputEnabled;
    BOOL _allowUnavailable,_unavailable;
    unsigned _retries;
    double _retryAfter;
    uint64_t _failedOpenID,_ownedID;
    uint8_t _buffer[8];
    UPState _state;
    UPButtonState _buttons;
    NSUInteger _presses[2],_shortcuts,_shortcutFailures;
    UPPacket _acceptedPacket;
    double _effectivePressure;
    BOOL _hasPacket,_awaitingTipRelease;
    CGRect _bounds;
    NSUInteger _reports,_ignored,_heldTipTimeouts;
    double _lastValidReportAt,_lastHeldTipTimeoutGap;
}
@property(nonatomic,readwrite) BOOL running;
@property(nonatomic,readwrite) BTPenPresence presence;
@property(nonatomic,readwrite,copy) NSString *status;
@property(nonatomic,strong) NSTimer *timer;
- (void)report:(uint8_t *)bytes length:(CFIndex)n reportID:(uint32_t)rid result:(IOReturn)result;
- (void)removed:(IOHIDDeviceRef)device;
- (void)added:(IOHIDDeviceRef)device result:(IOReturn)result;
@end
static void input(void *ctx,IOReturn result,void *sender,IOHIDReportType type,uint32_t rid,uint8_t *bytes,CFIndex n) {
    (void)sender;if(type==kIOHIDReportTypeInput)[(__bridge BTPenMonitor *)ctx report:bytes length:n reportID:rid result:result];
}
static void removed(void *ctx,IOReturn result,void *sender,IOHIDDeviceRef d) {
    (void)sender;(void)result;[(__bridge BTPenMonitor *)ctx removed:d];
}
static void deviceGone(void *ctx,IOReturn result,void *sender) {
    (void)result;[(__bridge BTPenMonitor *)ctx removed:(IOHIDDeviceRef)sender];
}
static void added(void *ctx,IOReturn result,void *sender,IOHIDDeviceRef d) {
    (void)sender;[(__bridge BTPenMonitor *)ctx added:d result:result];
}
@implementation BTPenMonitor
+ (void)configureDisplay:(CGDirectDisplayID)display pressureExponent:(double)exponent {selectedDisplay=display;[self updatePressureExponent:exponent];}
+ (void)updatePressureExponent:(double)exponent {pressureExponent=UPValidatedExponent(@(exponent));}
+ (void)updateShortcutBindings:(NSArray *)bindings {shortcutBindings=UPValidatedBindings(bindings);}
+ (void)setShortcutCapture:(BOOL)capturing {UPSetShortcutCapture(capturing);}
- (instancetype)init {if((self=[super init])){_penInputEnabled=YES;_presence=BTPenUnknown;_status=@"Disabled";}return self;}
- (BOOL)unavailable {return _unavailable;}
- (BOOL)penInputEnabled {return _penInputEnabled;}
- (void)setPenInputEnabled:(BOOL)enabled {
    if(_penInputEnabled==enabled)return;
    _penInputEnabled=enabled;
    if(!self.running)return;
    // End the old stroke before accepting input in a different mode. Do not
    // replay a tip or barrel shortcut held across an in-session unmute.
    if(!enabled)[self releasePenEvents];
    _buttons=(UPButtonState){0};_hasPacket=NO;_effectivePressure=0;_awaitingTipRelease=enabled;
    self.status=[self penStatusBeforeReport];
    [self publish:enabled?BTPenUnknown:BTPenOutOfRange];
}
- (void)dealloc {[self cleanup];}
- (void)publish:(BTPenPresence)p {self.presence=p;if(self.presenceChanged)self.presenceChanged(p);}
- (void)post:(UPBatch *)batch {
    if(!self.running){UPClear(batch);return;}
    for(size_t i=0;i<batch->count;i++)CGEventPost(kCGHIDEventTap,batch->events[i]);
    UPClear(batch);
}
- (void)abort:(NSString *)message {
    os_log_error(OS_LOG_DEFAULT,"BostoTablet pen failure: %{public}@",message);
    [self stop];self.status=message;
    // Stop the owning touch stream before any presence dispatch can emit there.
    [NSNotificationCenter.defaultCenter postNotificationName:UPFailureNotification object:self userInfo:@{@"reason":message}];
    [self publish:BTPenUnknown];
}
- (BOOL)fail:(NSString *)message error:(NSError **)error {
    os_log_error(OS_LOG_DEFAULT,"BostoTablet pen failure: %{public}@",message);
    [self stop];self.status=message;
    if(error)*error=[NSError errorWithDomain:@"local.BostoTablet" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];return NO;
}
- (NSString *)penStatusBeforeReport {
    if(_unavailable)return self.status;
    if(!_device)return @"Waiting for the Bosto USB pen interface.";
    return _penInputEnabled?@"Waiting for the first pen report.":@"Pen input muted.";
}
// The caller has validated a unique physical pen. Publish no synthetic proximity:
// only the first actual report can interrupt a working touch session.
- (IOReturn)attachPen:(IOHIDDeviceRef)device identity:(uint64_t)identity {
    // Pin before the OS call: a synchronous matching/removal callback must see
    // the pending claim, but no report/property access is authorized until success.
    _device=(IOHIDDeviceRef)CFRetain(device);_ownedID=identity;
    IOReturn result=IOHIDDeviceOpen(device,kIOHIDOptionsTypeSeizeDevice);
    if(result!=kIOReturnSuccess){
        CFRelease(_device);_device=NULL;_ownedID=0;_failedOpenID=identity;
        return result;
    }
    _seized=YES;
    _unavailable=NO;_failedOpenID=0;
    if(!self.running)return result;
    self.status=[self penStatusBeforeReport];
    IOHIDDeviceRegisterRemovalCallback(_device,deviceGone,(__bridge void *)self);
    IOHIDDeviceRegisterInputReportCallback(_device,_buffer,sizeof _buffer,input,(__bridge void *)self);
    _deviceScheduled=YES;
    IOHIDDeviceScheduleWithRunLoop(_device,_loop,kCFRunLoopCommonModes);
    return kIOReturnSuccess;
}
// No synthetic exit, callbacks, battery reads or events from a refused candidate.
- (BOOL)initialPenUnavailable:(NSString *)reason error:(NSError **)error {
    if(!_allowUnavailable)return [self fail:reason error:error];
    _unavailable=YES;self.status=reason;self.presence=BTPenUnknown;
    _retryAfter=NSProcessInfo.processInfo.systemUptime+(1u<<_retries);
    return YES;
}
// A notification is not authority to open. Verify the unique inventory entry and,
// for a notification, compare its registry ID against a fresh inventory.
- (BOOL)inspect:(IOHIDManagerRef)inventory notification:(IOHIDDeviceRef)d retry:(BOOL)retry error:(NSError **)error {
    if(!inventory)return [self initialPenUnavailable:@"Pen discovery unavailable." error:error];
    __attribute__((objc_precise_lifetime)) NSSet *devices=CFBridgingRelease(IOHIDManagerCopyDevices(inventory));
    IOHIDDeviceRef candidate=(__bridge IOHIDDeviceRef)devices.anyObject;
    if(!self.running || _device)return YES; // A synchronous callback already stopped or attached.
    if(!devices.count && !d){_unavailable=NO;_failedOpenID=0;self.status=[self penStatusBeforeReport];return YES;}
    uint64_t identity=devices.count==1?UPVerifiedPenRegistryID(candidate):0;
    if(!identity || (d && UPVerifiedPenRegistryID(d)!=identity))
        return [self initialPenUnavailable:@"Pen interface ambiguous or unverified; no pen opened." error:error];
    if(!retry && identity==_failedOpenID)return YES; // Same failed arrival, not a new attempt.
    if(!self.running || _device || ![self accessStillValid])return YES;
    IOReturn result=[self attachPen:d?:candidate identity:identity];
    if(self.running && result!=kIOReturnSuccess)return [self initialPenUnavailable:[NSString stringWithFormat:@"Exact pen seize failed (0x%08x).",result] error:error];
    return YES;
}
- (BOOL)beginDiscovery:(NSError **)error {
    _manager=UPCreatePenDiscoveryManager();
    if(!self.running)return YES;
    if(!_manager)return [self initialPenUnavailable:@"Could not create pen discovery manager." error:error];
    IOHIDManagerRegisterDeviceRemovalCallback(_manager,removed,(__bridge void *)self);
    IOHIDManagerRegisterDeviceMatchingCallback(_manager,added,(__bridge void *)self);
    if(![self inspect:_manager notification:NULL retry:NO error:error])return NO;
    if(self.running){
        _managerScheduled=YES;
        IOHIDManagerScheduleWithRunLoop(_manager,_loop,kCFRunLoopCommonModes);
    }
    return YES;
}
- (BOOL)startWithError:(NSError **)error {return [self startAllowingUnavailablePen:NO error:error];}
- (BOOL)startAllowingUnavailablePen:(BOOL)allow error:(NSError **)error {
    if(!NSThread.isMainThread){if(error)*error=[NSError errorWithDomain:@"local.BostoTablet" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Unified sessions require the main run loop."}];return NO;}
    [self stop];
    if(_stopping){if(error)*error=[NSError errorWithDomain:@"local.BostoTablet" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Previous pen session is stopping; retry after cleanup."}];return NO;}
    _reports=_ignored=_heldTipTimeouts=0;
    _buttons=(UPButtonState){0};_hasPacket=NO;_awaitingTipRelease=NO;
    _presses[0]=_presses[1]=_shortcuts=_shortcutFailures=0;_lastValidReportAt=_lastHeldTipTimeoutGap=0;
    if(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)!=kIOHIDAccessTypeGranted || !CGPreflightPostEventAccess())return [self fail:@"Input Monitoring and Accessibility required; grant access then Enable again." error:error];
    if(!selectedDisplay || !CGDisplayIsActive(selectedDisplay) || !isfinite(pressureExponent) || pressureExponent<0.25 || pressureExponent>4)return [self fail:@"Select an active display and a pressure exponent from 0.25 to 4." error:error];
    _bounds=CGDisplayBounds(selectedDisplay);
    _allowUnavailable=allow;_unavailable=NO;_failedOpenID=_ownedID=0;_retries=0;
    _loop=(CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
    self.running=YES;self.status=[self penStatusBeforeReport];
    [self publish:_penInputEnabled?BTPenUnknown:BTPenOutOfRange];
    if(self.running && ![self beginDiscovery:error])return NO;
    if(!self.running)return [self fail:self.status error:error];
    self.timer=[NSTimer timerWithTimeInterval:0.05 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [NSRunLoop.currentRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];return YES;
}
- (void)report:(uint8_t *)bytes length:(CFIndex)n reportID:(uint32_t)rid result:(IOReturn)result {
    if(!self.running || !_seized)return;
    if(result!=kIOReturnSuccess){[self abort:@"Pen report transport failed; disabled."];return;}
    if(!_penInputEnabled || rid!=1){_ignored++;return;}
    UPPacket packet={0};
    if(n!=8 || !UPParse(bytes,(size_t)n,&packet)){[self abort:@"Malformed exact pen report 1; disabled."];return;}
    _reports++;
    // Cancel touch before posting pen down/proximity. Both consume this report.
    self.status=packet.inRange?@"Pen in range — touch suppressed.":@"Pen exited — touch resume delay active.";
    [self publish:packet.inRange?BTPenInRange:BTPenOutOfRange];
    if(!self.running || !_penInputEnabled)return;
    _lastValidReportAt=NSProcessInfo.processInfo.systemUptime;
    BOOL recovering=_awaitingTipRelease;
    if(recovering && packet.inRange && packet.tip) {
        // Observe button levels without edges; a held tip cannot become a new stroke.
        (void)UPButtonPresses(&_buttons,packet,true);
        return;
    }
    _awaitingTipRelease=NO; // Only a real tip-up or out-of-range report rearms.
    UPBatch batch={0};
    double exponent=pressureExponent;
    if(!UPAdvance(&_state,packet,_bounds,exponent,&batch)){[self abort:@"Could not construct native pen events; disabled."];return;}
    [self post:&batch];
    // Keep the tester tied to this submitted packet and its curve, not later edits.
    _acceptedPacket=packet;_effectivePressure=UPPressure(packet,exponent);_hasPacket=YES;
    // Capture observes held/released state without emitting; edits preserve it.
    uint8_t presses=UPButtonPresses(&_buttons,packet,UPShortcutCaptureActive() || recovering);
    for(NSUInteger i=0;i<2;i++)if(presses & (1<<i)) {
        _presses[i]++;
        id binding=shortcutBindings.count==2?shortcutBindings[i]:NSNull.null;
        if(binding==NSNull.null)continue;
        UPBatch keys={0};
        if(UPShortcutEvents([binding[@"key"] unsignedShortValue],[binding[@"modifiers"] unsignedLongLongValue],&keys)){
            [self post:&keys];_shortcuts++;
        }else _shortcutFailures++;
    }
}
- (BOOL)accessStillValid {
    if(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)!=kIOHIDAccessTypeGranted || !CGPreflightPostEventAccess()) {[self abort:@"Pen permission lost; disabled."];return NO;}
    if(!CGDisplayIsActive(selectedDisplay) || !CGRectEqualToRect(_bounds,CGDisplayBounds(selectedDisplay))){[self abort:@"Pen display changed; disabled. Select display and Enable again."];return NO;}
    return YES;
}
- (void)tick:(NSTimer *)timer {
    (void)timer;if(!self.running || ![self accessStillValid])return;
    // Recover transient contention without polling HID indefinitely. Matching remains
    // active after the three timed retries; a new physical arrival can still attach.
    if(_unavailable && _retries<3 && NSProcessInfo.processInfo.systemUptime>=_retryAfter){
        _retries++;
        if(!_manager)[self beginDiscovery:NULL];
        else [self rescanForNotification:NULL retry:YES];
    }
    // Separate from palm cooldown. Only a posted held tip arms this watchdog;
    // unrelated reports never refresh it, and mere hover never expires.
    double gap=NSProcessInfo.processInfo.systemUptime-_lastValidReportAt;
    if(_state.down && gap>=2.0) {
        _heldTipTimeouts++;_lastHeldTipTimeoutGap=gap;
        // Release the synthetic tip without inventing a proximity exit. Keep the
        // confirmed presence for palm rejection and the exact HID session open.
        UPPacket released=_state.last;released.tip=false;released.pressure=0;
        UPBatch batch={0};
        if(!UPAdvance(&_state,released,_bounds,pressureExponent,&batch)){
            [self abort:@"Could not construct native pen events; disabled."];return;
        }
        [self post:&batch];
        _acceptedPacket=released;_effectivePressure=0;_awaitingTipRelease=YES;
        self.status=@"Pen tip released after report silence — waiting for real tip up or exit; touch suppressed.";
        NSLog(@"BostoTablet: held-tip report gap %.3f s; tip released, session remains enabled.",gap);
    }
}
- (void)removed:(IOHIDDeviceRef)d {
    if(!self.running)return;
    if(_device && d==_device){[self abort:@"Pen disconnected; disabled. Reconnect and Enable again."];return;}
    if(_unavailable && !_device)[self rescanForNotification:NULL retry:NO];
}
- (void)added:(IOHIDDeviceRef)d result:(IOReturn)result {
    if(!self.running)return;
    if(result!=kIOReturnSuccess){
        if(_allowUnavailable && !_device)[self initialPenUnavailable:@"Pen discovery notification failed." error:NULL];
        else [self abort:@"Pen discovery failed; disabled."];
        return;
    }
    if(_device && (d==_device || (_ownedID && UPVerifiedPenRegistryID(d)==_ownedID)))return;
    if(_device){[self abort:@"Pen connection changed; disabled."];return;}
    [self rescanForNotification:d retry:NO];
}
- (void)rescanForNotification:(IOHIDDeviceRef)d retry:(BOOL)retry {
    if(![self accessStillValid])return;
    IOHIDManagerRef inventory=UPCreatePenDiscoveryManager();
    NSError *error=nil;BOOL ok=[self inspect:inventory notification:d retry:retry error:&error];
    if(inventory)CFRelease(inventory);
    if(!ok)[self abort:error.localizedDescription];
}
- (void)stop {
    self.running=NO;_buttons=(UPButtonState){0};[self.timer invalidate];self.timer=nil;
    self.presence=BTPenUnknown;
    if(_stopping || (!_device && !_manager && !_loop))return;
    _stopping=YES;self.status=@"Disabled";
    // Strong capture owns the callback context/buffer until deferred disposal.
    // Restart is rejected while pending, so this block cannot target a new session.
    dispatch_async(dispatch_get_main_queue(),^{[self cleanup];});
}
- (void)releasePenEvents {
    _state.last.barrel=false;_state.last.secondary=false;
    UPBatch batch={0};UPCancel(&_state,&batch);
    // Only terminal releases may post during cleanup; normal posting is blocked.
    for(size_t i=0;i<batch.count;i++)CGEventPost(kCGHIDEventTap,batch.events[i]);
    UPClear(&batch);
}
- (void)cleanup {
    [self releasePenEvents];
    if(_device){
        IOHIDDeviceRegisterRemovalCallback(_device,NULL,NULL);
        IOHIDDeviceRegisterInputReportCallback(_device,_buffer,sizeof _buffer,NULL,NULL);
        if(_deviceScheduled)IOHIDDeviceUnscheduleFromRunLoop(_device,_loop,kCFRunLoopCommonModes);
        (void)IOHIDDeviceClose(_device,kIOHIDOptionsTypeSeizeDevice);
        CFRelease(_device);_device=NULL;
    }
    if(_manager){
        IOHIDManagerRegisterDeviceRemovalCallback(_manager,NULL,NULL);IOHIDManagerRegisterDeviceMatchingCallback(_manager,NULL,NULL);
        if(_managerScheduled)IOHIDManagerUnscheduleFromRunLoop(_manager,_loop,kCFRunLoopCommonModes);
        CFRelease(_manager);_manager=NULL;
    }
    if(_loop){CFRelease(_loop);_loop=NULL;}
    _seized=_managerScheduled=_deviceScheduled=NO;_stopping=NO;self.presence=BTPenUnknown;
}
- (NSDictionary *)snapshot {
    // Only a property on the already acquired exact pen. Never probe reports.
    NSNumber *battery=self.running && _seized?UPBatteryPercent((__bridge id)IOHIDDeviceGetProperty(_device,CFSTR("BatteryPercent"))):nil;
    return @{@"batteryPercent":battery?:NSNull.null,@"running":@(self.running),@"stopping":@(_stopping),@"presence":self.presence==BTPenInRange?@"inRange":self.presence==BTPenOutOfRange?@"outOfRange":@"unknown",@"status":self.status?:@"",@"reports":@(_reports),@"ignoredReports":@(_ignored),@"seized":@(_seized),@"waitingForDevice":@(self.running && !_device && !_unavailable),@"configurationWrites":@0,@"tipDown":@(_state.down),@"pressureExponent":@(pressureExponent),
        @"penInputEnabled":@(_penInputEnabled),@"pressureState":(!self.running || _unavailable)?@"inactive":!_penInputEnabled?@"muted":!_hasPacket?@"noData":!_acceptedPacket.inRange?@"outOfRange":_acceptedPacket.tip?@"tipDown":@"tipUp",
        @"rawPressure":@(self.running && _hasPacket && _acceptedPacket.inRange && _acceptedPacket.tip?_acceptedPacket.pressure:0),
        @"effectivePressure":@(self.running && _hasPacket?_effectivePressure:0),
        @"sideButtonPresses":@[@(_presses[0]),@(_presses[1])],@"shortcutPairs":@(_shortcuts),@"shortcutFailures":@(_shortcutFailures),@"shortcutCapture":@(UPShortcutCaptureActive()),@"heldTipReportTimeout":@2.0,@"heldTipTimeouts":@(_heldTipTimeouts),@"lastHeldTipTimeoutGap":@(_lastHeldTipTimeoutGap),@"lastValidReportUptime":@(_lastValidReportAt)};
}
@end
