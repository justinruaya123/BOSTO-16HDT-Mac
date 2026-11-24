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
#ifdef BT_UNIFIED_DRIVER
#import <IOKit/IOKitLib.h>
kern_return_t ReviewRegistryID(io_registry_entry_t,uint64_t *);
kern_return_t ReviewParent(io_registry_entry_t,const io_name_t,io_registry_entry_t *);
boolean_t ReviewConforms(io_object_t,const io_name_t);
CFTypeRef ReviewRegistryProperty(io_registry_entry_t,CFStringRef,CFAllocatorRef,IOOptionBits);
kern_return_t ReviewObjectRelease(io_object_t);
#define IOHIDDeviceGetService ReviewGetService
#define IORegistryEntryGetParentEntry ReviewParent
#define IORegistryEntryGetRegistryEntryID ReviewRegistryID
#define IORegistryEntryCreateCFProperty ReviewRegistryProperty
#define IOObjectConformsTo ReviewConforms
#define IOObjectRelease ReviewObjectRelease
#define IOHIDDeviceOpen ReviewDeviceOpen
#define IOHIDDeviceClose ReviewDeviceClose
#define IOHIDDeviceRegisterRemovalCallback ReviewDeviceRemoval
#define IOHIDDeviceRegisterInputReportCallback ReviewDeviceReports
#define IOHIDDeviceScheduleWithRunLoop ReviewDeviceSchedule
#define IOHIDDeviceUnscheduleFromRunLoop ReviewDeviceUnschedule
#endif
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
#ifdef BT_UNIFIED_DRIVER
static NSMutableArray *touchOpenAttempts,*touchClosed;
static NSNumber *penModeAtOpen,*requestedPenMode;
static io_service_t failTouchOpenService;
static IOHIDDeviceRef unpluggedDevice;
static NSMutableDictionary<NSNumber *,NSNumber *> *parents;
static NSMutableDictionary<NSNumber *,NSDictionary *> *usbNodes,*usbInterfaces;
static IOHIDCallback touchRemoved;
static void *touchRemovedContext;
// The fixture links the old shared pen observer, not UnifiedMonitor.m.
@implementation BTPenMonitor (FixtureOutputMode)
- (void)setPenInputEnabled:(BOOL)enabled {requestedPenMode=@(enabled);}
@end
io_service_t ReviewGetService(IOHIDDeviceRef d){return [((__bridge NSDictionary *)d)[@"service"] unsignedIntValue];}
kern_return_t ReviewParent(io_registry_entry_t child,const io_name_t plane,io_registry_entry_t *parent){
    assert(!strcmp(plane,kIOServicePlane));*parent=[parents[@(child)] unsignedIntValue];return *parent?KERN_SUCCESS:KERN_FAILURE;
}
boolean_t ReviewConforms(io_object_t node,const io_name_t type){
    return (!strcmp(type,"IOUSBHostDevice") && usbNodes[@(node)]!=nil) || (!strcmp(type,"IOUSBHostInterface") && usbInterfaces[@(node)]!=nil);
}
kern_return_t ReviewRegistryID(io_registry_entry_t node,uint64_t *identifier){*identifier=node;return node?KERN_SUCCESS:KERN_FAILURE;}
CFTypeRef ReviewRegistryProperty(io_registry_entry_t node,CFStringRef key,CFAllocatorRef allocator,IOOptionBits options){
    (void)allocator;(void)options;return (__bridge_retained CFTypeRef)(usbNodes[@(node)]?:usbInterfaces[@(node)])[(__bridge NSString *)key];
}
kern_return_t ReviewObjectRelease(io_object_t node){(void)node;return KERN_SUCCESS;}
IOReturn ReviewDeviceOpen(IOHIDDeviceRef device,IOOptionBits options){
    assert(options==kIOHIDOptionsTypeSeizeDevice);openCalls++;[touchOpenAttempts addObject:(__bridge id)device];
    return ReviewGetService(device)==failTouchOpenService?kIOReturnExclusiveAccess:openResult;
}
IOReturn ReviewDeviceClose(IOHIDDeviceRef device,IOOptionBits options){
    assert(options==kIOHIDOptionsTypeSeizeDevice);closeCalls++;[touchClosed addObject:(__bridge id)device];return kIOReturnSuccess;
}
void ReviewDeviceRemoval(IOHIDDeviceRef device,IOHIDCallback callback,void *context){(void)device;touchRemoved=callback;touchRemovedContext=context;}
void ReviewDeviceSchedule(IOHIDDeviceRef device,CFRunLoopRef loop,CFStringRef mode){(void)device;(void)loop;assert(CFEqual(mode,kCFRunLoopCommonModes));}
void ReviewDeviceUnschedule(IOHIDDeviceRef device,CFRunLoopRef loop,CFStringRef mode){ReviewDeviceSchedule(device,loop,mode);}
#endif
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
#ifdef BT_UNIFIED_DRIVER
void ReviewDeviceReports(IOHIDDeviceRef device,uint8_t *buffer,CFIndex size,IOHIDReportCallback callback,void *context){
    (void)device;if(callback)assert(buffer && size>=64);reportCallback=callback;reportContext=context;
}
#endif
@implementation BTTestDefaults
+ (instancetype)standardUserDefaults {static BTTestDefaults *defaults; if(!defaults)defaults=[BTTestDefaults new];return defaults;}
- (id)objectForKey:(NSString *)key {return testDefaults[key];}
- (NSString *)stringForKey:(NSString *)key {return testDefaults[key];}
- (void)setDouble:(double)value forKey:(NSString *)key {testDefaults[key]=@(value);}
- (void)setObject:(id)value forKey:(NSString *)key {testDefaults[key]=value;}
@end
static BOOL penManager(IOHIDManagerRef manager) {return [((__bridge NSDictionary *)manager)[@"pen"] boolValue];}
CFTypeRef ReviewDeviceGetProperty(IOHIDDeviceRef device, CFStringRef key) {
#ifdef BT_UNIFIED_DRIVER
    if(device==unpluggedDevice)return NULL;
#endif
    return CFDictionaryGetValue((CFDictionaryRef)device,key);
}
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
    NSArray *rows=(__bridge NSArray *)matches;
    ((__bridge NSMutableDictionary *)manager)[@"matches"]=rows;
#ifdef BT_UNIFIED_DRIVER
    if(!rows.count || rows.count>2)boundaryViolations++;
#else
    if(rows.count!=2)boundaryViolations++;
#endif
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
#ifndef BT_UNIFIED_DRIVER
    return CFSetCreateCopy(NULL,fakeDevices);
#else
    NSArray *rows=((__bridge NSDictionary *)manager)[@"matches"];
    NSMutableSet *selected=[NSMutableSet set];
    for(NSDictionary *device in (__bridge NSSet *)fakeDevices)for(NSDictionary *row in rows){
        BOOL match=YES;for(id key in row)if(![row[key] isEqual:device[key]]){match=NO;break;}
        if(match)[selected addObject:device];
    }
    return (__bridge_retained CFSetRef)[selected copy];
#endif
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
    #ifdef BT_UNIFIED_DRIVER
    if(penManager(manager))penModeAtOpen=requestedPenMode;
    else boundaryViolations++; // An opened manager would also seize future matching arrivals.
#endif
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
#ifdef BT_UNIFIED_DRIVER
    touchOpenAttempts=[NSMutableArray array];touchClosed=[NSMutableArray array];requestedPenMode=penModeAtOpen=nil;
    failTouchOpenService=0;unpluggedDevice=NULL;reportCallback=NULL;touchRemoved=NULL;
    parents=[@{@11:@21,@12:@22,@21:@31,@22:@31} mutableCopy];
    usbInterfaces=[@{@21:@{@"bInterfaceNumber":@1},@22:@{@"bInterfaceNumber":@0}} mutableCopy];
    usbNodes=[@{@31:@{@"idVendor":@0x6066,@"idProduct":@1,@"locationID":@0x12340000}} mutableCopy];
#endif
    fakePen=@{@kIOHIDVendorIDKey:@0x0ed1,@kIOHIDProductIDKey:@0x7821,@kIOHIDPrimaryUsagePageKey:@13,@kIOHIDPrimaryUsageKey:@2};
    fakeRange=@{@"device":fakePen};
    featureReads=featureWrites=0;featureReadResult=featureWriteResult=kIOReturnSuccess;
    firmwareReply[0]=9;firmwareReply[1]=1;firmwareReply[2]=26;memset(writtenCommand,0,3);writtenDevice=NULL;
}
#ifdef BT_UNIFIED_DRIVER
static NSDictionary *testDigitizer(void){
    static NSDictionary *device; if(!device)device=@{@kIOHIDVendorIDKey:@0x6066,@kIOHIDProductIDKey:@1,@kIOHIDPrimaryUsagePageKey:@13,@kIOHIDPrimaryUsageKey:@4,@kIOHIDTransportKey:@"USB",@kIOHIDLocationIDKey:@0x12340000,@"service":@11};return device;
}
static NSDictionary *testCompanion(void){
    static NSDictionary *device; if(!device)device=@{@kIOHIDVendorIDKey:@0x6066,@kIOHIDProductIDKey:@1,@kIOHIDPrimaryUsagePageKey:@1,@kIOHIDPrimaryUsageKey:@2,@kIOHIDTransportKey:@"USB",@kIOHIDLocationIDKey:@0x12340000,@"service":@12};return device;
}
#else
static NSDictionary *testDigitizer(void) {return @{@kIOHIDVendorIDKey:@0x6066,@kIOHIDProductIDKey:@1,@kIOHIDPrimaryUsagePageKey:@13,@kIOHIDPrimaryUsageKey:@4};}
#endif
static void createFakeDevices(void) {
    NSDictionary *digitizer=testDigitizer();
#ifdef BT_UNIFIED_DRIVER
    NSDictionary *mouse=testCompanion();
#else
    NSDictionary *mouse=@{@kIOHIDVendorIDKey:@0x6066,@kIOHIDProductIDKey:@1,@kIOHIDPrimaryUsagePageKey:@1,@kIOHIDPrimaryUsageKey:@2};
#endif
#ifdef BT_UNIFIED_DRIVER
    NSDictionary *keyboard=@{@kIOHIDVendorIDKey:@0x6066,@kIOHIDProductIDKey:@1,@kIOHIDPrimaryUsagePageKey:@1,@kIOHIDPrimaryUsageKey:@6};
    NSDictionary *otherMouse=@{@kIOHIDVendorIDKey:@0x046d,@kIOHIDProductIDKey:@2,@kIOHIDPrimaryUsagePageKey:@1,@kIOHIDPrimaryUsageKey:@2};
    fakeDevices=(__bridge_retained CFSetRef)[NSSet setWithObjects:digitizer,mouse,keyboard,otherMouse,nil];
#else
    const void *devices[]={(__bridge const void *)digitizer,(__bridge const void *)mouse};
    fakeDevices=CFSetCreate(NULL,devices,2,&kCFTypeSetCallBacks);
#endif
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
