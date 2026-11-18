// TEST ONLY. All device access, permissions, display access and input posting below are fakes.
#import <Foundation/Foundation.h>
// Persistence stays in memory: offline tests must not change the user's defaults.
@interface BTTestDefaults : NSObject
+ (instancetype)standardUserDefaults;
- (id)objectForKey:(NSString *)key;
- (NSString *)stringForKey:(NSString *)key;
- (void)setDouble:(double)value forKey:(NSString *)key;
- (void)setObject:(id)value forKey:(NSString *)key;
@end
#define NSUserDefaults BTTestDefaults
#define IOHIDDeviceGetProperty ReviewDeviceGetProperty
#define IOHIDDeviceGetReport ReviewGetReport
#define IOHIDDeviceSetReport ReviewSetReport
#define IOHIDDeviceCopyMatchingElements ReviewElements
#define IOHIDDeviceGetValueWithOptions ReviewCachedValue
#define IOHIDElementGetDevice ReviewElementDevice
#define IOHIDElementGetUsagePage ReviewElementPage
#define IOHIDElementGetUsage ReviewElementUsage
#define IOHIDElementGetReportID ReviewElementReport
#define IOHIDElementGetReportSize ReviewElementSize
#define IOHIDElementGetReportCount ReviewElementCount
#define IOHIDElementGetLogicalMin ReviewElementMin
#define IOHIDElementGetLogicalMax ReviewElementMax
#define IOHIDElementGetType ReviewElementType
#define IOHIDValueGetElement ReviewValueElement
#define IOHIDValueGetIntegerValue ReviewValueInteger
#define IOHIDValueGetTimeStamp ReviewValueTime
#define IOHIDManagerCreate ReviewManagerCreate
#define IOHIDManagerSetDeviceMatching ReviewPenMatching
#define IOHIDManagerSetDeviceMatchingMultiple ReviewSetMatching
#define IOHIDManagerSetInputValueMatching ReviewValueMatching
#define IOHIDManagerCopyDevices ReviewCopyDevices
#define IOHIDManagerRegisterInputReportCallback ReviewRegisterReports
#define IOHIDManagerRegisterInputValueCallback ReviewRegisterValues
#define IOHIDManagerRegisterDeviceRemovalCallback ReviewRegisterRemoved
#define IOHIDManagerRegisterDeviceMatchingCallback ReviewRegisterAdded
#define IOHIDManagerScheduleWithRunLoop ReviewSchedule
#define IOHIDManagerUnscheduleFromRunLoop ReviewUnschedule
#define IOHIDManagerOpen ReviewOpen
#define IOHIDManagerClose ReviewClose
#define IOHIDCheckAccess ReviewCheckAccess
#define CGPreflightPostEventAccess ReviewPostAccess
#define CGEventPost ReviewNoPost
#define CGDisplayIsActive ReviewDisplayActive
#define CGDisplayBounds ReviewDisplayBounds
#define BTAvailableDisplays BTTestSystemDisplays
#import "../BTPenMonitor.m"
#import "../BTTouchController.m"
#undef BTAvailableDisplays

static IOHIDAccessType listenAccess = kIOHIDAccessTypeGranted;
static BOOL postAccess = YES, displayActive = YES;
static IOReturn openResult = kIOReturnSuccess;
static IOReturn featureReadResult=kIOReturnSuccess,featureWriteResult=kIOReturnSuccess;
static int featureReads,featureWrites;
static uint8_t firmwareReply[3]={9,1,26},writtenCommand[3];
static IOHIDDeviceRef writtenDevice;
static int openCalls, closeCalls, symbolicPosts, postedDowns, postedUps;
static int penOpenCalls,penCloseCalls,boundaryViolations;
static NSMutableArray<NSEvent *> *postedEvents;
static NSMutableDictionary *testDefaults;
static NSDictionary *fakePen,*fakeRange;
static BTPenPresence initialPen=BTPenOutOfRange;
static uint64_t penStamp;
static CFSetRef fakeDevices;
static IOHIDDeviceCallback addedCallback;
static IOHIDDeviceCallback removedCallback;
static IOHIDReportCallback reportCallback;
static void *addedContext, *removedContext, *reportContext;
static IOHIDValueCallback valueCallback;
static IOHIDDeviceCallback penRemovedCallback;
static void *valueContext,*penRemovedContext;
@implementation BTTestDefaults
+ (instancetype)standardUserDefaults {static BTTestDefaults *defaults; if(!defaults)defaults=[BTTestDefaults new];return defaults;}
- (id)objectForKey:(NSString *)key {return testDefaults[key];}
- (NSString *)stringForKey:(NSString *)key {return testDefaults[key];}
- (void)setDouble:(double)value forKey:(NSString *)key {testDefaults[key]=@(value);}
- (void)setObject:(id)value forKey:(NSString *)key {testDefaults[key]=value;}
@end
static BOOL penManager(IOHIDManagerRef manager) {return [((__bridge NSDictionary *)manager)[@"pen"] boolValue];}
CFTypeRef ReviewDeviceGetProperty(IOHIDDeviceRef device, CFStringRef key) { return CFDictionaryGetValue((CFDictionaryRef)device,key); }
IOReturn ReviewGetReport(IOHIDDeviceRef d,IOHIDReportType type,CFIndex rid,uint8_t *bytes,CFIndex *length) {
    (void)d;featureReads++;if(type!=kIOHIDReportTypeFeature || rid!=9 || *length<3)return kIOReturnBadArgument;
    memcpy(bytes,firmwareReply,3);*length=3;return featureReadResult;
}
IOReturn ReviewSetReport(IOHIDDeviceRef d,IOHIDReportType type,CFIndex rid,const uint8_t *bytes,CFIndex length) {
    featureWrites++;writtenDevice=d;if(type!=kIOHIDReportTypeFeature || rid!=3 || length!=3)return kIOReturnBadArgument;
    memcpy(writtenCommand,bytes,3);return featureWriteResult;
}
IOHIDManagerRef ReviewManagerCreate(CFAllocatorRef allocator, IOOptionBits options) { (void)allocator;(void)options;return (IOHIDManagerRef)CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks); }
void ReviewSetMatching(IOHIDManagerRef manager, CFArrayRef matches) {
    (void)manager;NSArray *rows=(__bridge NSArray *)matches;
    if(rows.count!=2)boundaryViolations++;
    for(NSDictionary *row in rows)if(![row[@kIOHIDVendorIDKey] isEqual:@0x6066] || ![row[@kIOHIDProductIDKey] isEqual:@1] ||
        !(([row[@kIOHIDPrimaryUsagePageKey] isEqual:@13] && [row[@kIOHIDPrimaryUsageKey] isEqual:@4]) ||
          ([row[@kIOHIDPrimaryUsagePageKey] isEqual:@1] && [row[@kIOHIDPrimaryUsageKey] isEqual:@2])))boundaryViolations++;
}
void ReviewPenMatching(IOHIDManagerRef manager,CFDictionaryRef match) {
    ((__bridge NSMutableDictionary *)manager)[@"pen"]=@YES;
    NSDictionary *row=(__bridge NSDictionary *)match;
    if(![row[@kIOHIDVendorIDKey] isEqual:@0x0ed1] || ![row[@kIOHIDProductIDKey] isEqual:@0x7821] ||
       ![row[@kIOHIDPrimaryUsagePageKey] isEqual:@13] || ![row[@kIOHIDPrimaryUsageKey] isEqual:@2])boundaryViolations++;
}
void ReviewValueMatching(IOHIDManagerRef manager,CFDictionaryRef match) {(void)manager;(void)match;}
CFSetRef ReviewCopyDevices(IOHIDManagerRef manager) {
    if(penManager(manager))return (__bridge_retained CFSetRef)[NSSet setWithObject:fakePen];
    return CFSetCreateCopy(NULL,fakeDevices);
}
void ReviewRegisterReports(IOHIDManagerRef manager,IOHIDReportCallback callback,void *context) { (void)manager;reportCallback=callback;reportContext=context; }
void ReviewRegisterValues(IOHIDManagerRef manager,IOHIDValueCallback callback,void *context) {(void)manager;valueCallback=callback;valueContext=context;}
void ReviewRegisterRemoved(IOHIDManagerRef manager,IOHIDDeviceCallback callback,void *context) {
    if(penManager(manager)){penRemovedCallback=callback;penRemovedContext=context;return;}
    removedCallback=callback;removedContext=context;
}
void ReviewRegisterAdded(IOHIDManagerRef manager,IOHIDDeviceCallback callback,void *context) {if(penManager(manager))return;addedCallback=callback;addedContext=context;}
void ReviewSchedule(IOHIDManagerRef manager,CFRunLoopRef loop,CFStringRef mode) {
    (void)loop;if(!CFEqual(mode,kCFRunLoopCommonModes))boundaryViolations++;
    ((__bridge NSMutableDictionary *)manager)[@"mode"]=(__bridge NSString *)mode;
}
void ReviewUnschedule(IOHIDManagerRef manager,CFRunLoopRef loop,CFStringRef mode) {
    (void)loop;if(!((__bridge NSDictionary *)manager)[@"mode"] || !CFEqual(mode,kCFRunLoopCommonModes))boundaryViolations++;
}
IOReturn ReviewOpen(IOHIDManagerRef manager,IOOptionBits options) {
    if(penManager(manager)){penOpenCalls++;if(options!=kIOHIDOptionsTypeNone)boundaryViolations++;return kIOReturnSuccess;}
    openCalls++;if(options!=kIOHIDOptionsTypeSeizeDevice)boundaryViolations++;return openResult;
}
IOReturn ReviewClose(IOHIDManagerRef manager,IOOptionBits options) {
    if(penManager(manager)){penCloseCalls++;if(options!=kIOHIDOptionsTypeNone)boundaryViolations++;}
    else {closeCalls++;if(options!=kIOHIDOptionsTypeSeizeDevice)boundaryViolations++;}
    return kIOReturnSuccess;
}
CFArrayRef ReviewElements(IOHIDDeviceRef device,CFDictionaryRef match,IOOptionBits options) {
    (void)device;(void)match;(void)options;return (__bridge_retained CFArrayRef)@[fakeRange];
}
IOReturn ReviewCachedValue(IOHIDDeviceRef device,IOHIDElementRef element,IOHIDValueRef *value,IOOptionBits options) {
    (void)device;(void)element;
    if(options!=kIOHIDDeviceGetValueWithoutUpdate)boundaryViolations++;
    static NSDictionary *seed;
    seed=@{@"element":fakeRange,@"value":@(initialPen==BTPenInRange),@"time":@(initialPen==BTPenUnknown?0:++penStamp)};
    *value=(__bridge IOHIDValueRef)seed;return kIOReturnSuccess;
}
IOHIDDeviceRef ReviewElementDevice(IOHIDElementRef e) {return (__bridge IOHIDDeviceRef)((__bridge NSDictionary *)e)[@"device"];}
uint32_t ReviewElementPage(IOHIDElementRef e) {(void)e;return 13;}
uint32_t ReviewElementUsage(IOHIDElementRef e) {(void)e;return 0x32;}
uint32_t ReviewElementReport(IOHIDElementRef e) {(void)e;return 1;}
uint32_t ReviewElementSize(IOHIDElementRef e) {(void)e;return 1;}
uint32_t ReviewElementCount(IOHIDElementRef e) {(void)e;return 1;}
CFIndex ReviewElementMin(IOHIDElementRef e) {(void)e;return 0;}
CFIndex ReviewElementMax(IOHIDElementRef e) {(void)e;return 1;}
IOHIDElementType ReviewElementType(IOHIDElementRef e) {(void)e;return kIOHIDElementTypeInput_Button;}
IOHIDElementRef ReviewValueElement(IOHIDValueRef v) {return (__bridge IOHIDElementRef)((__bridge NSDictionary *)v)[@"element"];}
CFIndex ReviewValueInteger(IOHIDValueRef v) {return [((__bridge NSDictionary *)v)[@"value"] longLongValue];}
uint64_t ReviewValueTime(IOHIDValueRef v) {return [((__bridge NSDictionary *)v)[@"time"] unsignedLongLongValue];}
IOHIDAccessType ReviewCheckAccess(IOHIDRequestType type) { (void)type;return listenAccess; }
bool ReviewPostAccess(void) { return postAccess; }
void ReviewNoPost(CGEventTapLocation tap,CGEventRef event) {
    (void)tap;symbolicPosts++;if(CGEventGetType(event)==kCGEventLeftMouseDown)postedDowns++;if(CGEventGetType(event)==kCGEventLeftMouseUp)postedUps++;
    NSEvent *native=[NSEvent eventWithCGEvent:event];if(native)[postedEvents addObject:native];
}
boolean_t ReviewDisplayActive(CGDirectDisplayID display) { return display==42 && displayActive; }
CGRect ReviewDisplayBounds(CGDirectDisplayID display) { (void)display;return CGRectMake(-1920,-1080,1920,1080); }


NSArray<NSDictionary *> *BTAvailableDisplays(void) { return @[@{@"id":@42,@"name":@"Bosto Test Fixture",@"uuid":@"TEST",@"bounds":@[@(-1920),@(-1080),@1920,@1080]}]; }
static void resetFakes(void) {
    listenAccess=kIOHIDAccessTypeGranted;postAccess=YES;displayActive=YES;openResult=kIOReturnSuccess;
    openCalls=closeCalls=symbolicPosts=postedDowns=postedUps=0;
    penOpenCalls=penCloseCalls=boundaryViolations=0;initialPen=BTPenOutOfRange;penStamp=100;
    postedEvents=[NSMutableArray array];testDefaults=[NSMutableDictionary dictionary];
    fakePen=@{@kIOHIDVendorIDKey:@0x0ed1,@kIOHIDProductIDKey:@0x7821,@kIOHIDPrimaryUsagePageKey:@13,@kIOHIDPrimaryUsageKey:@2};
    fakeRange=@{@"device":fakePen};
    featureReads=featureWrites=0;featureReadResult=featureWriteResult=kIOReturnSuccess;
    firmwareReply[0]=9;firmwareReply[1]=1;firmwareReply[2]=26;memset(writtenCommand,0,3);writtenDevice=NULL;
}
static NSDictionary *testDigitizer(void) {return @{@kIOHIDVendorIDKey:@0x6066,@kIOHIDProductIDKey:@1,@kIOHIDPrimaryUsagePageKey:@13,@kIOHIDPrimaryUsageKey:@4};}
static void createFakeDevices(void) {
    NSDictionary *digitizer=testDigitizer();
    NSDictionary *mouse=@{@kIOHIDVendorIDKey:@0x6066,@kIOHIDProductIDKey:@1,@kIOHIDPrimaryUsagePageKey:@1,@kIOHIDPrimaryUsageKey:@2};
    const void *devices[]={(__bridge const void *)digitizer,(__bridge const void *)mouse};
    fakeDevices=CFSetCreate(NULL,devices,2,&kCFTypeSetCallBacks);
}
static void pressFakeFinger(void) {
    uint8_t packet[64]={4,0x41,0x00,0x20,0xc0,0x12};packet[55]=1;
    reportCallback(reportContext,kIOReturnSuccess,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,4,packet,64);
    // Movement beyond the existing policy's slop arms a drag without sleeping.
    packet[2]=0x40;
    reportCallback(reportContext,kIOReturnSuccess,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,4,packet,64);
}
static void sendFakeTouches(size_t count,uint16_t firstX,uint16_t secondX) __attribute__((unused));
static void sendFakeTouches(size_t count,uint16_t firstX,uint16_t secondX) {
    uint8_t packet[64]={4};packet[55]=(uint8_t)count;
    for(size_t i=0;i<count;i++) {
        uint16_t x=i?secondX:firstX;size_t offset=1+5*i;
        packet[offset]=(uint8_t)(0x41+i);packet[offset+1]=x&255;packet[offset+2]=x>>8;
        packet[offset+3]=0xc0;packet[offset+4]=0x12;
    }
    reportCallback(reportContext,kIOReturnSuccess,(__bridge void *)testDigitizer(),kIOHIDReportTypeInput,4,packet,64);
}
static void sendFakePen(BTPenPresence presence) __attribute__((unused));
static void sendFakePen(BTPenPresence presence) {
    NSDictionary *value=@{@"element":fakeRange,@"value":@(presence==BTPenInRange),@"time":@(++penStamp)};
    valueCallback(valueContext,presence==BTPenUnknown?kIOReturnError:kIOReturnSuccess,NULL,(__bridge IOHIDValueRef)value);
}
