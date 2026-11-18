// Test only: real observer logic, fake HID/permission boundary; no device opens.
#define IOHIDManagerCreate PMCreate
#define IOHIDManagerSetDeviceMatching PMMatch
#define IOHIDManagerSetInputValueMatching PMValueMatch
#define IOHIDManagerCopyDevices PMDevices
#define IOHIDManagerRegisterInputValueCallback PMValueCallback
#define IOHIDManagerRegisterDeviceMatchingCallback PMAddedCallback
#define IOHIDManagerRegisterDeviceRemovalCallback PMRemovedCallback
#define IOHIDManagerScheduleWithRunLoop PMSchedule
#define IOHIDManagerUnscheduleFromRunLoop PMUnschedule
#define IOHIDManagerOpen PMOpen
#define IOHIDManagerClose PMClose
#define IOHIDDeviceGetProperty PMProperty
#define IOHIDDeviceCopyMatchingElements PMElements
#define IOHIDDeviceGetValueWithOptions PMGet
#define IOHIDElementGetDevice PMElementDevice
#define IOHIDElementGetUsagePage PMUsagePage
#define IOHIDElementGetUsage PMUsage
#define IOHIDElementGetReportID PMReportID
#define IOHIDElementGetReportSize PMReportSize
#define IOHIDElementGetReportCount PMReportCount
#define IOHIDElementGetLogicalMin PMMin
#define IOHIDElementGetLogicalMax PMMax
#define IOHIDElementGetType PMType
#define IOHIDValueGetElement PMValueElement
#define IOHIDValueGetIntegerValue PMInteger
#define IOHIDValueGetTimeStamp PMTime
#define IOHIDCheckAccess PMAccess
#import "../BTPenMonitor.m"
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/hidsystem/IOHIDLib.h>
static int checks,failures,opens,closes,reads;static IOOptionBits openOptions,readOptions;
static IOHIDAccessType accessResult=kIOHIDAccessTypeGranted;
static IOReturn openResult,readResult;
static NSArray *devices,*elements;static NSDictionary *seed,*match,*valueMatch;
static IOHIDValueCallback valueCallback;static IOHIDDeviceCallback removedCallback;
static void *valueContext,*removedContext;
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x);failures++;}}while(0)
IOHIDManagerRef PMCreate(CFAllocatorRef a,IOOptionBits o){(void)a;(void)o;return (IOHIDManagerRef)CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);}
void PMMatch(IOHIDManagerRef m,CFDictionaryRef d){(void)m;match=[(__bridge NSDictionary *)d copy];}
void PMValueMatch(IOHIDManagerRef m,CFDictionaryRef d){(void)m;valueMatch=[(__bridge NSDictionary *)d copy];}
CFSetRef PMDevices(IOHIDManagerRef m){(void)m;return (__bridge_retained CFSetRef)[NSSet setWithArray:devices];}
void PMValueCallback(IOHIDManagerRef m,IOHIDValueCallback c,void *x){(void)m;valueCallback=c;valueContext=x;}
void PMAddedCallback(IOHIDManagerRef m,IOHIDDeviceCallback c,void *x){(void)m;(void)c;(void)x;}
void PMRemovedCallback(IOHIDManagerRef m,IOHIDDeviceCallback c,void *x){(void)m;removedCallback=c;removedContext=x;}
void PMSchedule(IOHIDManagerRef m,CFRunLoopRef l,CFStringRef s){(void)m;(void)l;(void)s;}
void PMUnschedule(IOHIDManagerRef m,CFRunLoopRef l,CFStringRef s){(void)m;(void)l;(void)s;}
IOReturn PMOpen(IOHIDManagerRef m,IOOptionBits o){(void)m;opens++;openOptions=o;return openResult;}
IOReturn PMClose(IOHIDManagerRef m,IOOptionBits o){(void)m;(void)o;closes++;return 0;}
CFTypeRef PMProperty(IOHIDDeviceRef d,CFStringRef k){return CFDictionaryGetValue((CFDictionaryRef)d,k);}
CFArrayRef PMElements(IOHIDDeviceRef d,CFDictionaryRef m,IOOptionBits o){(void)d;(void)m;(void)o;return (__bridge_retained CFArrayRef)[elements copy];}
IOReturn PMGet(IOHIDDeviceRef d,IOHIDElementRef e,IOHIDValueRef *v,IOOptionBits o){(void)d;(void)e;reads++;readOptions=o;*v=(__bridge IOHIDValueRef)seed;return readResult;}
IOHIDDeviceRef PMElementDevice(IOHIDElementRef e){return (__bridge IOHIDDeviceRef)((__bridge NSDictionary *)e)[@"device"];}
uint32_t PMUsagePage(IOHIDElementRef e){return [((__bridge NSDictionary *)e)[@"page"] unsignedIntValue];}
uint32_t PMUsage(IOHIDElementRef e){return [((__bridge NSDictionary *)e)[@"usage"] unsignedIntValue];}
uint32_t PMReportID(IOHIDElementRef e){return [((__bridge NSDictionary *)e)[@"report"] unsignedIntValue];}
uint32_t PMReportSize(IOHIDElementRef e){return [((__bridge NSDictionary *)e)[@"size"] unsignedIntValue];}
uint32_t PMReportCount(IOHIDElementRef e){return [((__bridge NSDictionary *)e)[@"count"] unsignedIntValue];}
CFIndex PMMin(IOHIDElementRef e){return [((__bridge NSDictionary *)e)[@"min"] longLongValue];}
CFIndex PMMax(IOHIDElementRef e){return [((__bridge NSDictionary *)e)[@"max"] longLongValue];}
IOHIDElementType PMType(IOHIDElementRef e){return (IOHIDElementType)[((__bridge NSDictionary *)e)[@"type"] unsignedIntValue];}
IOHIDElementRef PMValueElement(IOHIDValueRef v){return (__bridge IOHIDElementRef)((__bridge NSDictionary *)v)[@"element"];}
CFIndex PMInteger(IOHIDValueRef v){return [((__bridge NSDictionary *)v)[@"value"] longLongValue];}
uint64_t PMTime(IOHIDValueRef v){return [((__bridge NSDictionary *)v)[@"time"] unsignedLongLongValue];}
IOHIDAccessType PMAccess(IOHIDRequestType t){(void)t;return accessResult;}
static NSDictionary *sample(NSDictionary *element,int n,uint64_t time){return @{@"element":element,@"value":@(n),@"time":@(time)};}
static void reset(void){
    opens=closes=reads=0;openResult=readResult=0;openOptions=readOptions=999;accessResult=kIOHIDAccessTypeGranted;
    NSDictionary *d=@{@kIOHIDVendorIDKey:@0x0ed1,@kIOHIDProductIDKey:@0x7821,@kIOHIDPrimaryUsagePageKey:@13,@kIOHIDPrimaryUsageKey:@2};
    devices=@[d];NSDictionary *e=@{@"device":d,@"page":@13,@"usage":@0x32,@"report":@1,@"size":@1,@"count":@1,@"min":@0,@"max":@1,@"type":@(kIOHIDElementTypeInput_Button)};
    elements=@[e];seed=sample(e,0,100);valueCallback=NULL;removedCallback=NULL;match=valueMatch=nil;
}
static void deliver(NSDictionary *v,IOReturn result){if(valueCallback)valueCallback(valueContext,result,NULL,(__bridge IOHIDValueRef)v);}
int main(void){@autoreleasepool{
    reset();BTPenMonitor *p=[BTPenMonitor new];__block int notices=0;p.presenceChanged=^(BTPenPresence s){(void)s;notices++;};
    CHECK([p startWithError:NULL]);CHECK(p.running);CHECK(p.presence==BTPenOutOfRange);CHECK(openOptions==kIOHIDOptionsTypeNone);CHECK(readOptions==kIOHIDDeviceGetValueWithoutUpdate);
    CHECK([match[@kIOHIDVendorIDKey] isEqual:@0x0ed1]);CHECK([match[@kIOHIDProductIDKey] isEqual:@0x7821]);CHECK([match[@kIOHIDPrimaryUsagePageKey] isEqual:@13]);CHECK([match[@kIOHIDPrimaryUsageKey] isEqual:@2]);
    CHECK([valueMatch[@kIOHIDElementUsageKey] isEqual:@0x32]);CHECK([valueMatch[@kIOHIDElementReportIDKey] isEqual:@1]);
    deliver(sample(elements[0],1,200),0);CHECK(p.presence==BTPenInRange);CHECK(notices>=2);
    deliver(sample(elements[0],0,150),0);CHECK(p.presence==BTPenInRange); // older queued OUT must not override IN
    deliver(sample(elements[0],0,201),0);CHECK(p.presence==BTPenOutOfRange);
    deliver(sample(elements[0],2,202),0);CHECK(p.presence==BTPenUnknown);
    [p stop];CHECK(!p.running);CHECK(closes==1);[p stop];CHECK(closes==1);
    reset();p=[BTPenMonitor new];accessResult=kIOHIDAccessTypeDenied;CHECK(![p startWithError:NULL]);CHECK(opens==0);CHECK(p.presence==BTPenUnknown);
    reset();p=[BTPenMonitor new];openResult=kIOReturnExclusiveAccess;CHECK(![p startWithError:NULL]);CHECK(opens==1);CHECK(closes==1);CHECK(p.presence==BTPenUnknown);
    reset();p=[BTPenMonitor new];seed=sample(elements[0],0,0);CHECK([p startWithError:NULL]);CHECK(p.presence==BTPenUnknown);[p stop];
    reset();p=[BTPenMonitor new];readResult=kIOReturnError;CHECK([p startWithError:NULL]);CHECK(p.presence==BTPenUnknown);[p stop];
    reset();p=[BTPenMonitor new];CHECK([p startWithError:NULL]);if(removedCallback)removedCallback(removedContext,0,NULL,(__bridge IOHIDDeviceRef)devices[0]);CHECK(p.presence==BTPenUnknown);[p stop];
    reset();p=[BTPenMonitor new];CHECK([p startWithError:NULL]);deliver(nil,kIOReturnError);CHECK(p.presence==BTPenUnknown);[p stop];
    // Protected devices and malformed/ambiguous advertised fields never open.
    NSArray *bad=@[@{@kIOHIDVendorIDKey:@0x6066,@kIOHIDProductIDKey:@1,@kIOHIDPrimaryUsagePageKey:@13,@kIOHIDPrimaryUsageKey:@4},
                   @{@kIOHIDVendorIDKey:@0x0ed1,@kIOHIDProductIDKey:@0x7821,@kIOHIDPrimaryUsagePageKey:@1,@kIOHIDPrimaryUsageKey:@2}];
    for(NSDictionary *d in bad){reset();devices=@[d];p=[BTPenMonitor new];CHECK(![p startWithError:NULL]);CHECK(opens==0);}
    for(NSString *key in @[@"report",@"size",@"count",@"usage",@"page",@"max"]){reset();NSMutableDictionary *e=[elements[0] mutableCopy];e[key]=@99;elements=@[e];p=[BTPenMonitor new];CHECK(![p startWithError:NULL]);CHECK(opens==0);}
    reset();elements=@[elements[0],elements[0]];p=[BTPenMonitor new];CHECK(![p startWithError:NULL]);CHECK(opens==0);
    reset();devices=@[];p=[BTPenMonitor new];CHECK(![p startWithError:NULL]);CHECK(opens==0);
    printf("Shared pen observer policy (mock HID): %d checks, %d failures\n",checks,failures);return failures?1:0;
}}
