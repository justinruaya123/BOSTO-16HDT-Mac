#import "BTPenMonitor.h"
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/hidsystem/IOHIDLib.h>

static uint32_t penProperty(IOHIDDeviceRef device,CFStringRef key) {
    CFTypeRef value=IOHIDDeviceGetProperty(device,key);int64_t n=0;
    if(!value || CFGetTypeID(value)!=CFNumberGetTypeID() || !CFNumberGetValue(value,kCFNumberSInt64Type,&n) || n<0 || n>UINT32_MAX)return UINT32_MAX;
    return (uint32_t)n;
}
static BOOL exactPen(IOHIDDeviceRef d) {
    return d && penProperty(d,CFSTR(kIOHIDVendorIDKey))==0x0ed1 && penProperty(d,CFSTR(kIOHIDProductIDKey))==0x7821 &&
        penProperty(d,CFSTR(kIOHIDPrimaryUsagePageKey))==13 && penProperty(d,CFSTR(kIOHIDPrimaryUsageKey))==2;
}
static NSDictionary *rangeMatch(void) {
    return @{@kIOHIDElementUsagePageKey:@13,@kIOHIDElementUsageKey:@0x32,@kIOHIDElementReportIDKey:@1};
}
static BOOL isRange(IOHIDElementRef e,IOHIDDeviceRef device) {
    IOHIDElementType type=IOHIDElementGetType(e);
    return IOHIDElementGetDevice(e)==device && IOHIDElementGetUsagePage(e)==13 && IOHIDElementGetUsage(e)==0x32 &&
        IOHIDElementGetReportID(e)==1 && IOHIDElementGetReportSize(e)==1 && IOHIDElementGetReportCount(e)==1 &&
        IOHIDElementGetLogicalMin(e)==0 && IOHIDElementGetLogicalMax(e)==1 &&
        type>=kIOHIDElementTypeInput_Misc && type<=kIOHIDElementTypeInput_ScanCodes;
}
@interface BTPenMonitor () {
    IOHIDManagerRef _manager;
    IOHIDDeviceRef _device;
    IOHIDElementRef _element;
    CFRunLoopRef _ownerLoop;
    BOOL _openAttempted,_invalidConnection,_seenValue;
    uint64_t _lastStamp;
    CFIndex _lastValue;
    NSUInteger _valueEvents,_staleEvents;
}
@property(nonatomic,readwrite) BOOL running;
@property(nonatomic,readwrite) BTPenPresence presence;
@property(nonatomic,readwrite,copy) NSString *status;
- (void)acceptValue:(IOHIDValueRef)value result:(IOReturn)result;
- (void)deviceAdded:(IOHIDDeviceRef)device result:(IOReturn)result;
- (void)deviceRemoved:(IOHIDDeviceRef)device;
@end
static void penValue(void *ctx,IOReturn result,void *sender,IOHIDValueRef value) {
    (void)sender;[(__bridge BTPenMonitor *)ctx acceptValue:value result:result];
}
static void penAdded(void *ctx,IOReturn result,void *sender,IOHIDDeviceRef device) {
    (void)sender;[(__bridge BTPenMonitor *)ctx deviceAdded:device result:result];
}
static void penRemoved(void *ctx,IOReturn result,void *sender,IOHIDDeviceRef device) {
    (void)sender;(void)result;[(__bridge BTPenMonitor *)ctx deviceRemoved:device];
}
@implementation BTPenMonitor
- (instancetype)init {
    if((self=[super init])){_presence=BTPenUnknown;_status=@"Pen observer stopped.";}return self;
}
- (void)dealloc {[self stop];}
- (void)publish:(BTPenPresence)presence status:(NSString *)status {
    self.presence=presence;self.status=status;
    if(self.presenceChanged)self.presenceChanged(presence);
}
- (BOOL)fail:(NSString *)message code:(NSInteger)code error:(NSError **)error {
    [self stop];self.status=message;
    if(error)*error=[NSError errorWithDomain:@"local.BostoMultitouch.Pen" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
- (BOOL)startWithError:(NSError **)error {
    [self stop];_lastStamp=0;_lastValue=0;_seenValue=NO;_invalidConnection=NO;_valueEvents=_staleEvents=0;
    if(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)!=kIOHIDAccessTypeGranted)
        return [self fail:@"Input Monitoring required for shared pen proximity; no pen opened." code:1 error:error];
    _manager=IOHIDManagerCreate(NULL,kIOHIDOptionsTypeNone);
    if(!_manager)return [self fail:@"Could not create shared pen observer." code:2 error:error];
    NSDictionary *match=@{@kIOHIDVendorIDKey:@0x0ed1,@kIOHIDProductIDKey:@0x7821,@kIOHIDPrimaryUsagePageKey:@13,@kIOHIDPrimaryUsageKey:@2};
    IOHIDManagerSetDeviceMatching(_manager,(__bridge CFDictionaryRef)match);
    CFSetRef devices=IOHIDManagerCopyDevices(_manager);
    if(!devices || CFSetGetCount(devices)!=1){
        if(devices)CFRelease(devices);return [self fail:@"Expected one exact Bosto pen for palm rejection; touch remains suppressed." code:3 error:error];
    }
    IOHIDDeviceRef device=(__bridge IOHIDDeviceRef)[(__bridge NSSet *)devices anyObject];
    if(!exactPen(device)){CFRelease(devices);return [self fail:@"Unexpected device in pen observer; no pen opened." code:4 error:error];}
    _device=(IOHIDDeviceRef)CFRetain(device);CFRelease(devices);
    CFArrayRef elements=IOHIDDeviceCopyMatchingElements(_device,(__bridge CFDictionaryRef)rangeMatch(),kIOHIDOptionsTypeNone);
    NSUInteger count=0;
    for(id object in (__bridge NSArray *)elements){IOHIDElementRef e=(__bridge IOHIDElementRef)object;if(isRange(e,_device)){_element=e;count++;}}
    if(count==1)CFRetain(_element);else _element=NULL;
    if(elements)CFRelease(elements);
    if(!_element)return [self fail:@"No unique valid Bosto InRange input; no pen opened." code:5 error:error];
    IOHIDManagerSetInputValueMatching(_manager,(__bridge CFDictionaryRef)rangeMatch());
    IOHIDManagerRegisterInputValueCallback(_manager,penValue,(__bridge void *)self);
    IOHIDManagerRegisterDeviceMatchingCallback(_manager,penAdded,(__bridge void *)self);
    IOHIDManagerRegisterDeviceRemovalCallback(_manager,penRemoved,(__bridge void *)self);
    _ownerLoop=(CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
    IOHIDManagerScheduleWithRunLoop(_manager,_ownerLoop,kCFRunLoopCommonModes);
    _openAttempted=YES;IOReturn opened=IOHIDManagerOpen(_manager,kIOHIDOptionsTypeNone);
    if(opened!=kIOReturnSuccess)
        return [self fail:[NSString stringWithFormat:@"Shared pen observation failed (0x%08x); pen was not seized.",opened] code:opened error:error];
    self.running=YES;
    IOHIDValueRef initial=NULL;
    IOReturn got=IOHIDDeviceGetValueWithOptions(_device,_element,&initial,kIOHIDDeviceGetValueWithoutUpdate);
    [self acceptValue:initial result:got];
    return YES;
}
- (void)acceptValue:(IOHIDValueRef)value result:(IOReturn)result {
    if(!self.running || _invalidConnection)return;
    if(result!=kIOReturnSuccess || !value){[self publish:BTPenUnknown status:@"Pen state unavailable — touch suppressed."];return;}
    IOHIDElementRef element=IOHIDValueGetElement(value);
    if(!element || element!=_element || !isRange(element,_device))return;
    _valueEvents++;
    uint64_t stamp=IOHIDValueGetTimeStamp(value);CFIndex n=IOHIDValueGetIntegerValue(value);
    if(stamp && stamp<_lastStamp){_staleEvents++;return;}
    if(!stamp || (n!=0 && n!=1) || (_seenValue && stamp==_lastStamp && n!=_lastValue)){
        if(stamp>_lastStamp)_lastStamp=stamp;
        [self publish:BTPenUnknown status:@"Invalid/uninitialized pen state — touch suppressed."];return;
    }
    if(_seenValue && stamp==_lastStamp && n==_lastValue)return;
    _lastStamp=stamp;_lastValue=n;_seenValue=YES;
    [self publish:n?BTPenInRange:BTPenOutOfRange status:n?@"Pen in range — touch suppressed.":@"Pen out of range (shared observer)."];
}
- (void)deviceAdded:(IOHIDDeviceRef)device result:(IOReturn)result {
    if(!self.running)return;
    if(result==kIOReturnSuccess && device==_device && exactPen(device))return;
    _invalidConnection=YES;[self publish:BTPenUnknown status:@"Pen connection changed — touch suppressed; Enable again."];
}
- (void)deviceRemoved:(IOHIDDeviceRef)device {
    if(!self.running || device!=_device)return;
    _invalidConnection=YES;[self publish:BTPenUnknown status:@"Pen disconnected — touch suppressed; reconnect and Enable."];
}
- (void)stop {
    self.running=NO;self.presence=BTPenUnknown;
    if(_manager){
        IOHIDManagerRegisterInputValueCallback(_manager,NULL,NULL);
        IOHIDManagerRegisterDeviceMatchingCallback(_manager,NULL,NULL);
        IOHIDManagerRegisterDeviceRemovalCallback(_manager,NULL,NULL);
        if(_ownerLoop)IOHIDManagerUnscheduleFromRunLoop(_manager,_ownerLoop,kCFRunLoopCommonModes);
        if(_openAttempted)(void)IOHIDManagerClose(_manager,kIOHIDOptionsTypeNone);
        CFRelease(_manager);_manager=NULL;
    }
    if(_ownerLoop){CFRelease(_ownerLoop);_ownerLoop=NULL;}
    if(_element){CFRelease(_element);_element=NULL;}
    if(_device){CFRelease(_device);_device=NULL;}
    _openAttempted=NO;self.status=@"Pen observer stopped.";
}
- (NSDictionary *)snapshot {
    NSString *presence=self.presence==BTPenInRange?@"inRange":self.presence==BTPenOutOfRange?@"outOfRange":@"unknown";
    return @{@"running":@(self.running),@"presence":presence,@"status":self.status?:@"",@"valueEvents":@(_valueEvents),
             @"staleEvents":@(_staleEvents),@"lastValueTimestamp":@(_lastStamp),@"sharedOpen":@(self.running && _openAttempted),@"seized":@NO,@"configurationWrites":@0};
}
@end
