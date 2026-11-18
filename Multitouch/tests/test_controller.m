// Opt-in live lifecycle test: touch capture and shared, read-only pen observation.
// Never run by the offline suite; never posts input or writes configuration.
#import <Cocoa/Cocoa.h>
#import "../BTTouchController.h"
static int checks, failures;
#define CHECK(x) do { checks++; if(!(x)){failures++;fprintf(stderr,"line %d: FAIL %s\n",__LINE__,#x);} }while(0)
int main(void) {
 @autoreleasepool {
    BTTouchController *controller=[BTTouchController new];NSError *error=nil;
    CHECK(![controller startWithDisplay:0 postEvents:NO error:&error]);CHECK(!controller.running);
    CGDirectDisplayID target=0;
    for(NSDictionary *display in BTAvailableDisplays())if([display[@"name"] rangeOfString:@"bosto" options:NSCaseInsensitiveSearch].location!=NSNotFound)target=[display[@"id"] unsignedIntValue];
    CHECK(target!=0);error=nil;
    BOOL started=[controller startWithDisplay:target postEvents:NO error:&error];CHECK(started);
    double deadline=NSProcessInfo.processInfo.systemUptime+0.4;
    while(NSProcessInfo.processInfo.systemUptime<deadline)CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.05,false);
    CHECK(controller.running);CHECK([controller.snapshot[@"interfaces"] unsignedIntegerValue]==2);
    CHECK(![controller.snapshot[@"postsMouseEvents"] boolValue]);
    if(!controller.running)fprintf(stderr,"Unexpected stop: %s\n",controller.status.UTF8String);
    [controller stop];CHECK(!controller.running);CHECK(![controller.snapshot[@"pointerDown"] boolValue]);
    printf("Live touch-only controller lifecycle: %d checks, %d failures\n",checks,failures);
    return failures?1:0;
 }
}
