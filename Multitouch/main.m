#import <Cocoa/Cocoa.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import "BTTouchController.h"
#include <math.h>
#include <signal.h>

static volatile sig_atomic_t BTInterruptedSignal;
static void BTHandleSignal(int signo) { BTInterruptedSignal=signo; }

static void printJSON(NSDictionary *object) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];
    if(data){fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);fflush(stdout);}
}
static NSDictionary *bostoDisplay(void) {
    for(NSDictionary *display in BTAvailableDisplays())if([display[@"name"] rangeOfString:@"bosto" options:NSCaseInsensitiveSearch].location!=NSNotFound)return display;
    return nil;
}
@interface BTTouchPad : NSView
@property(nonatomic,strong) NSBezierPath *stroke;
@property(nonatomic) NSUInteger downs,drags,ups,scrolls,pinches;
@property(nonatomic) double panX,panY,zoom;
@end
@implementation BTTouchPad
- (BOOL)isFlipped{return YES;}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;[NSColor.textBackgroundColor setFill];NSRectFill(self.bounds);
    [NSColor.separatorColor setStroke];NSFrameRect(self.bounds);
    [NSColor.controlAccentColor setStroke];self.stroke.lineWidth=3;[self.stroke stroke];
    NSString *hint=[NSString stringWithFormat:@"Tap/drag · two-finger pan (%.0f, %.0f) · pinch %.0f%%",self.panX,self.panY,100*(1+self.zoom)];
    [hint drawAtPoint:NSMakePoint(12,10) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:14],NSForegroundColorAttributeName:NSColor.secondaryLabelColor}];
}
- (void)mouseDown:(NSEvent *)event {
    self.downs++;self.stroke=[NSBezierPath bezierPath];[self.stroke moveToPoint:[self convertPoint:event.locationInWindow fromView:nil]];[self setNeedsDisplay:YES];
}
- (void)mouseDragged:(NSEvent *)event {self.drags++;[self.stroke lineToPoint:[self convertPoint:event.locationInWindow fromView:nil]];[self setNeedsDisplay:YES];}
- (void)mouseUp:(NSEvent *)event {(void)event;self.ups++;}
- (void)scrollWheel:(NSEvent *)event {
    self.scrolls++;self.panX+=event.scrollingDeltaX;self.panY+=event.scrollingDeltaY;[self setNeedsDisplay:YES];
}
- (void)magnifyWithEvent:(NSEvent *)event {
    self.pinches++;self.zoom=fmax(-0.9,fmin(9,(1+self.zoom)*(1+event.magnification)-1));[self setNeedsDisplay:YES];
}
@end

@interface BTApp : NSObject<NSApplicationDelegate>
@property(nonatomic,strong) BTTouchController *controller;
@property(nonatomic,strong) NSWindow *window;
@property(nonatomic,strong) NSStatusItem *statusItem;
@property(nonatomic,strong) NSPopUpButton *displays;
@property(nonatomic,strong) NSTextField *statusLabel,*counterLabel,*delayField;
@property(nonatomic,strong) NSButton *enable;
@property(nonatomic,strong) BTTouchPad *pad;
@property(nonatomic,strong) NSTimer *refreshTimer;
@property(nonatomic,copy) NSString *stateFile;
@property(nonatomic) BOOL smokeTest;
@end
static NSTextField *label(NSString *text,NSRect frame,CGFloat size) {
    NSTextField *field=[NSTextField labelWithString:text];field.frame=frame;field.font=[NSFont systemFontOfSize:size];return field;
}
@implementation BTApp
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    for(NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:NSBundle.mainBundle.bundleIdentifier]) {
        if(app.processIdentifier!=NSProcessInfo.processInfo.processIdentifier){[app activateWithOptions:0];[NSApp terminate:nil];return;}
    }
    self.controller=[BTTouchController new];
    self.window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,640,520) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"Bosto Multitouch";self.window.releasedWhenClosed=NO;
    NSView *view=self.window.contentView;
    [view addSubview:label(@"Bosto Multitouch",NSMakeRect(20,478,600,25),22)];
    [view addSubview:label(@"Tap/drag, two-finger pan and pinch. Pen proximity pauses touch.",NSMakeRect(20,450,600,20),13)];
    [view addSubview:label(@"Touch display",NSMakeRect(20,413,115,22),13)];
    self.displays=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(135,410,485,27) pullsDown:NO];self.displays.target=self;self.displays.action=@selector(selectDisplay:);[view addSubview:self.displays];
    [view addSubview:label(@"Resume touch after pen leaves",NSMakeRect(20,370,235,22),13)];
    self.delayField=[[NSTextField alloc]initWithFrame:NSMakeRect(260,368,65,25)];
    self.delayField.doubleValue=self.controller.resumeDelay;
    self.delayField.target=self;self.delayField.action=@selector(changeDelay:);
    self.delayField.toolTip=@"Seconds from pen leaving range, 0–30. Saved automatically.";
    [view addSubview:self.delayField];
    NSButton *saveDelay=[NSButton buttonWithTitle:@"Save delay" target:self action:@selector(changeDelay:)];saveDelay.frame=NSMakeRect(330,366,100,29);[view addSubview:saveDelay];
    [view addSubview:label(@"seconds (0–30)",NSMakeRect(440,370,175,22),12)];
    self.statusLabel=label(self.controller.status,NSMakeRect(20,310,600,40),13);self.statusLabel.maximumNumberOfLines=2;[view addSubview:self.statusLabel];
    self.enable=[NSButton buttonWithTitle:@"Enable finger touch" target:self action:@selector(toggle:)];self.enable.frame=NSMakeRect(20,272,190,30);[view addSubview:self.enable];
    NSButton *privacy=[NSButton buttonWithTitle:@"Permissions…" target:self action:@selector(permissions:)];privacy.frame=NSMakeRect(215,272,130,30);[view addSubview:privacy];
    self.pad=[[BTTouchPad alloc]initWithFrame:NSMakeRect(20,38,600,220)];[view addSubview:self.pad];
    self.counterLabel=label(@"Reports 0 · received clicks 0 · drags 0 · releases 0",NSMakeRect(20,10,610,20),12);[view addSubview:self.counterLabel];
    self.statusItem=[NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];self.statusItem.button.title=@"Touch";
    NSMenu *menu=[[NSMenu alloc]initWithTitle:@"Bosto Multitouch"];
    NSMenuItem *show=[menu addItemWithTitle:@"Show touch controls" action:@selector(show:) keyEquivalent:@""];show.target=self;
    NSMenuItem *disable=[menu addItemWithTitle:@"Disable finger touch" action:@selector(disable:) keyEquivalent:@""];disable.target=self;
    [menu addItem:NSMenuItem.separatorItem];[menu addItemWithTitle:@"Quit Bosto Multitouch" action:@selector(terminate:) keyEquivalent:@"q"];self.statusItem.menu=menu;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadDisplays:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
    [self reloadDisplays:nil];[self show:nil];
    self.refreshTimer=[NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
    [self refresh:nil];
    if(self.smokeTest)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.6*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        printJSON(@{@"windowVisible":@(self.window.visible),@"title":self.window.title,@"displayOptions":@(self.displays.numberOfItems),@"enabled":@(self.controller.running),@"resumeDelay":@(self.controller.resumeDelay),@"penAccessed":@NO});[NSApp terminate:nil];
    });
}
- (void)reloadDisplays:(NSNotification *)note {
    (void)note;NSString *uuid=self.displays.selectedItem.representedObject[@"uuid"]?:[NSUserDefaults.standardUserDefaults stringForKey:@"TouchDisplayUUID"];
    [self.displays removeAllItems];NSInteger selection=-1;NSArray *records=BTAvailableDisplays();
    for(NSDictionary *record in records) {
        NSArray *b=record[@"bounds"];
        [self.displays addItemWithTitle:[NSString stringWithFormat:@"%@ — %@ × %@",record[@"name"],b[2],b[3]]];self.displays.lastItem.representedObject=record;
        if(uuid.length && [record[@"uuid"] isEqual:uuid])selection=self.displays.numberOfItems-1;
    }
    if(!uuid.length) {
        NSDictionary *preferred=bostoDisplay();
        for(NSInteger i=0;i<self.displays.numberOfItems;i++)if([self.displays itemAtIndex:i].representedObject[@"id"]==preferred[@"id"] || [[self.displays itemAtIndex:i].representedObject[@"id"] isEqual:preferred[@"id"]])selection=i;
    }
    [self.displays selectItemAtIndex:selection];
    self.enable.enabled=selection>=0;
    if(selection<0){[self.controller stop];self.statusLabel.stringValue=@"Bosto/selected display unavailable. Select it explicitly; no Retina fallback.";}
    if(!self.controller.running && selection>=0) {
        NSNumber *displayID=self.displays.selectedItem.representedObject[@"id"];
        for(NSScreen *screen in NSScreen.screens)if([screen.deviceDescription[@"NSScreenNumber"] isEqual:displayID]) {
            NSRect frame=self.window.frame;frame.origin=NSMakePoint(NSMidX(screen.frame)-NSWidth(frame)/2,NSMidY(screen.frame)-NSHeight(frame)/2);[self.window setFrame:frame display:YES];break;
        }
    }
}
- (void)selectDisplay:(id)sender {
    (void)sender;[self.controller stop];NSDictionary *record=self.displays.selectedItem.representedObject;
    if(record)[NSUserDefaults.standardUserDefaults setObject:record[@"uuid"] forKey:@"TouchDisplayUUID"];
    self.enable.enabled=record!=nil;[self refresh:nil];
}
- (void)changeDelay:(id)sender {
    (void)sender;NSScanner *scanner=[NSScanner scannerWithString:self.delayField.stringValue];double seconds;
    if(![scanner scanDouble:&seconds] || !scanner.isAtEnd || ![self.controller updateResumeDelay:seconds]) {
        self.delayField.doubleValue=self.controller.resumeDelay;
        self.delayField.toolTip=@"Enter a delay from 0 to 30 seconds. Previous delay kept.";
        NSBeep();return;
    }
    self.delayField.toolTip=@"Delay saved. Seconds from pen leaving range, 0–30.";[self refresh:nil];
}
- (void)toggle:(id)sender {
    (void)sender;
    if(self.controller.running){[self.controller stop];[self refresh:nil];return;}
    NSDictionary *record=self.displays.selectedItem.representedObject;if(!record)return;
    if(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)!=kIOHIDAccessTypeGranted) {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);self.statusLabel.stringValue=@"Grant Input Monitoring for Bosto Multitouch, then press Enable again.";return;
    }
    if(!CGPreflightPostEventAccess()) {
        CGRequestPostEventAccess();self.statusLabel.stringValue=@"Grant Accessibility for Bosto Multitouch, then press Enable again.";return;
    }
    NSError *error=nil;[self.controller startWithDisplay:[record[@"id"] unsignedIntValue] postEvents:YES error:&error];[self refresh:nil];
}
- (void)permissions:(id)sender {
    (void)sender;
    NSString *pane=IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)==kIOHIDAccessTypeGranted?@"Privacy_Accessibility":@"Privacy_ListenEvent";
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:[@"x-apple.systempreferences:com.apple.preference.security?" stringByAppendingString:pane]]];
}
- (void)disable:(id)sender{(void)sender;[self.controller stop];[self refresh:nil];}
- (void)show:(id)sender{(void)sender;[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];}
- (void)refresh:(NSTimer *)timer {
    (void)timer;NSDictionary *snapshot=self.controller.snapshot;
    self.enable.title=self.controller.running?@"Disable finger touch":@"Enable finger touch";
    self.statusItem.button.title=self.controller.running?@"Touch On":@"Touch Off";
    self.statusLabel.stringValue=self.displays.indexOfSelectedItem<0?@"Selected display unavailable — choose the Bosto display.":self.controller.status;
    self.counterLabel.stringValue=[NSString stringWithFormat:@"Reports %@ · clicks %lu · drags %lu · ups %lu · pan %lu · pinch %lu",snapshot[@"reports"],(unsigned long)self.pad.downs,(unsigned long)self.pad.drags,(unsigned long)self.pad.ups,(unsigned long)self.pad.scrolls,(unsigned long)self.pad.pinches];
    if(self.stateFile.length) {
        NSMutableDictionary *state=[snapshot mutableCopy];state[@"padDowns"]=@(self.pad.downs);state[@"padDrags"]=@(self.pad.drags);state[@"padUps"]=@(self.pad.ups);state[@"padScrolls"]=@(self.pad.scrolls);state[@"padPinches"]=@(self.pad.pinches);
        state[@"selectedDisplay"]=self.displays.selectedItem.representedObject?:@{};state[@"listenAccess"]=@(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent));state[@"postEventAccess"]=@(CGPreflightPostEventAccess());
        NSData *data=[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];[data writeToFile:self.stateFile atomically:YES];
    }
}
- (void)applicationWillTerminate:(NSNotification *)note {(void)note;[self.controller stop];[self.refreshTimer invalidate];[NSNotificationCenter.defaultCenter removeObserver:self];[NSStatusBar.systemStatusBar removeStatusItem:self.statusItem];}
@end

int main(int argc,const char **argv) {
 @autoreleasepool {
    if(argc>1 && strcmp(argv[1],"--diagnose")==0){printJSON(BTTouchController.diagnostics);return 0;}
    if(argc>1 && (strcmp(argv[1],"--observe")==0 || strcmp(argv[1],"--run")==0)) {
        char *end=NULL;double seconds=argc==3?strtod(argv[2],&end):0;
        if(!isfinite(seconds) || seconds<=0 || seconds>120 || !end || *end){fprintf(stderr,"Use --observe/--run <seconds>, 0 < seconds <= 120.\n");return 2;}
        struct sigaction action={0},previousInt,previousTerm;
        action.sa_handler=BTHandleSignal;sigemptyset(&action.sa_mask);BTInterruptedSignal=0;
        if(sigaction(SIGINT,&action,&previousInt)!=0){perror("sigaction SIGINT");return 2;}
        if(sigaction(SIGTERM,&action,&previousTerm)!=0){sigaction(SIGINT,&previousInt,NULL);perror("sigaction SIGTERM");return 2;}
        BOOL post=strcmp(argv[1],"--run")==0;NSDictionary *display=bostoDisplay();
        BTTouchController *controller=[BTTouchController new];NSError *error=nil;
        if(![controller startWithDisplay:[display[@"id"] unsignedIntValue] postEvents:post error:&error]){
            sigaction(SIGINT,&previousInt,NULL);sigaction(SIGTERM,&previousTerm,NULL);
            printJSON(@{@"error":error.localizedDescription,@"state":controller.snapshot});return 2;
        }
        fprintf(stderr,"Multitouch with shared read-only pen proximity: %.0f seconds, %s input events, target %s.\n",seconds,post?"POSTING":"not posting",[display[@"name"] UTF8String]);
        double deadline=NSProcessInfo.processInfo.systemUptime+seconds;
        while(!BTInterruptedSignal && controller.running && NSProcessInfo.processInfo.systemUptime<deadline)CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.05,false);
        NSDictionary *beforeStop=controller.snapshot;BOOL stayedRunning=controller.running;[controller stop];
        int interrupted=BTInterruptedSignal;
        sigaction(SIGINT,&previousInt,NULL);sigaction(SIGTERM,&previousTerm,NULL);
        printJSON(@{@"completedInterval":@(stayedRunning && !interrupted),@"interruptedSignal":@(interrupted),@"captured":beforeStop,@"afterStop":controller.snapshot});
        if(interrupted)return 128+interrupted;
        return stayedRunning && [beforeStop[@"validFrames"] unsignedIntegerValue]>0?0:3;
    }
    NSApplication *app=NSApplication.sharedApplication;[app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    BTApp *delegate=[BTApp new];
    for(int i=1;i<argc;i++) {
        if(strcmp(argv[i],"--state-file")==0 && i+1<argc)delegate.stateFile=[NSString stringWithUTF8String:argv[++i]];
        else if(strcmp(argv[i],"--ui-smoke-test")==0)delegate.smokeTest=YES;
        else{fprintf(stderr,"Unknown option: %s\n",argv[i]);return 2;}
    }
    app.delegate=delegate;[app run];
 }
 return 0;
}
