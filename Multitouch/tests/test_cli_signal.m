// Executes the actual production CLI with fake HID/event-post boundaries, then signals a held drag.
#import "hardware_fakes.h"
#include <signal.h>
#define main BTProductionMain
#import "../main.m"
#undef main
int main(int argc,const char **argv) { @autoreleasepool {
    int signo=argc==2 && strcmp(argv[1],"TERM")==0?SIGTERM:SIGINT;
    createFakeDevices();resetFakes();
    CFRunLoopTimerRef timer=CFRunLoopTimerCreateWithHandler(NULL,CFAbsoluteTimeGetCurrent()+0.05,0,0,0,^(CFRunLoopTimerRef t){
        (void)t;pressFakeFinger();raise(signo);
    });
    CFRunLoopAddTimer(CFRunLoopGetCurrent(),timer,kCFRunLoopDefaultMode);
    const char *arguments[]={"BostoMultitouch","--run","1",NULL};
    int result=BTProductionMain(3,arguments);
    CFRunLoopTimerInvalidate(timer);CFRelease(timer);CFRelease(fakeDevices);
    BOOL passed=result==128+signo && openCalls==1 && closeCalls==1 && penOpenCalls==1 && penCloseCalls==1 && boundaryViolations==0 && postedDowns==1 && postedUps==1;
    fprintf(stdout,"Mock-I/O CLI signal %d: result=%d open=%d close=%d down=%d up=%d — %s\n",signo,result,openCalls,closeCalls,postedDowns,postedUps,passed?"PASS":"FAIL");
    return passed?0:1;
} }
