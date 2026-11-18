#import <Cocoa/Cocoa.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import "BTTouchController.h"
#import "UnifiedMonitor.h"
#import "UnifiedPen.h"
#include <math.h>
#import "ShortcutEditor.h"
static NSTextField *label(NSString *text,NSRect r) {NSTextField *v=[NSTextField labelWithString:text];v.frame=r;return v;}
@interface UPApp : NSObject<NSApplicationDelegate,NSWindowDelegate,NSTabViewDelegate>
@property(nonatomic,strong) BTTouchController *touch;
@property(nonatomic,strong) NSWindow *window;
@property(nonatomic,strong) NSStatusItem *item;
@property(nonatomic,strong) NSPopUpButton *displays;
@property(nonatomic,strong) NSTextField *delay,*status,*pressureDescription,*tester;
@property(nonatomic,strong) NSSlider *pressureSlider;
@property(nonatomic,strong) NSLevelIndicator *rawMeter,*effectiveMeter;
@property(nonatomic,strong) NSArray<UPShortcutEditor *> *editors;
@property(nonatomic,strong) NSMutableArray *bindings;
@property(nonatomic,strong) NSUserDefaults *preferences;
@property(nonatomic) double exponent;
@property(nonatomic,strong) NSTextView *diagnostics;
@property(nonatomic,strong) NSButton *enable;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,copy) NSString *failure;
@end
@implementation UPApp
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    for(NSRunningApplication *other in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"local.BostoTablet"])if(other.processIdentifier!=NSProcessInfo.processInfo.processIdentifier){[other activateWithOptions:0];[NSApp terminate:nil];return;}
    self.preferences=[[NSUserDefaults alloc]initWithSuiteName:@"local.BostoTablet"];
    NSDictionary *saved=[self.preferences persistentDomainForName:@"local.BostoTablet"];
    self.exponent=UPValidatedExponent(saved[@"penPressureExponent"]);
    self.bindings=[UPValidatedBindings(saved[@"penShortcutBindings"]) mutableCopy];
    [BTPenMonitor updatePressureExponent:self.exponent];[BTPenMonitor updateShortcutBindings:self.bindings];
    self.touch=[BTTouchController new]; // No HID opened until Enable.
    self.window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,700,550) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"BostoTablet";self.window.releasedWhenClosed=NO;self.window.delegate=self;
    [self composeControlsInView:self.window.contentView resumeDelay:self.touch.resumeDelay];
    self.item=[NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];self.item.button.title=@"Bosto Off";
    NSMenu *menu=[NSMenu new];NSMenuItem *show=[menu addItemWithTitle:@"Show BostoTablet" action:@selector(show:) keyEquivalent:@""];show.target=self;
    NSMenuItem *stop=[menu addItemWithTitle:@"Disable pen and touch" action:@selector(disable:) keyEquivalent:@""];stop.target=self;
    [menu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];self.item.menu=menu;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(penFailed:) name:UPFailureNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadDisplays:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
    [self reloadDisplays:nil];[self.window center];[self show:nil];
    self.timer=[NSTimer timerWithTimeInterval:0.25 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];[NSRunLoop.currentRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];[self refresh:nil];
}
- (void)composeControlsInView:(NSView *)root resumeDelay:(double)resumeDelay {
    NSTabView *tabs=[[NSTabView alloc]initWithFrame:NSMakeRect(10,10,680,530)];tabs.delegate=self;[root addSubview:tabs];
    NSTabViewItem *home=[[NSTabViewItem alloc]initWithIdentifier:@"home"];home.label=@"Home / Setup";[tabs addTabViewItem:home];
    NSView *v=[[NSView alloc]initWithFrame:NSMakeRect(0,0,680,500)];home.view=v;
    [v addSubview:label(@"BostoTablet — local candidate",NSMakeRect(20,460,630,24))];
    [v addSubview:label(@"7821 pen + finger touch · initially disabled · no automatic startup",NSMakeRect(20,430,630,24))];
    [v addSubview:label(@"Pen and touch display",NSMakeRect(20,390,180,24))];
    self.displays=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(200,388,440,28) pullsDown:NO];self.displays.target=self;self.displays.action=@selector(selectDisplay:);[v addSubview:self.displays];
    [v addSubview:label(@"Touch delay after pen exit (0–30 s)",NSMakeRect(20,347,300,24))];
    self.delay=[[NSTextField alloc]initWithFrame:NSMakeRect(340,347,90,24)];self.delay.doubleValue=resumeDelay;[v addSubview:self.delay];
    self.enable=[NSButton buttonWithTitle:@"Enable pen and touch" target:self action:@selector(toggle:)];self.enable.frame=NSMakeRect(20,289,200,32);[v addSubview:self.enable];
    NSButton *quit=[NSButton buttonWithTitle:@"Quit" target:NSApp action:@selector(terminate:)];quit.frame=NSMakeRect(550,289,90,32);[v addSubview:quit];
    self.status=label(@"Disabled — choose a display, then Enable.",NSMakeRect(20,237,620,45));self.status.maximumNumberOfLines=2;[v addSubview:self.status];
    NSScrollView *scroll=[[NSScrollView alloc]initWithFrame:NSMakeRect(20,20,620,205)];scroll.hasVerticalScroller=YES;
    self.diagnostics=[[NSTextView alloc]initWithFrame:scroll.bounds];self.diagnostics.editable=NO;self.diagnostics.font=[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];scroll.documentView=self.diagnostics;[v addSubview:scroll];
    NSTabViewItem *pen=[[NSTabViewItem alloc]initWithIdentifier:@"pen"];pen.label=@"Pen";[tabs addTabViewItem:pen];
    NSView *pv=[[NSView alloc]initWithFrame:v.frame];pen.view=pv;
    [pv addSubview:label(@"Pressure sensitivity",NSMakeRect(20,440,600,28))];
    [pv addSubview:label(@"Softer                         Linear                         Firmer",NSMakeRect(20,395,600,24))];
    self.pressureSlider=[NSSlider sliderWithValue:log2(self.exponent) minValue:-2 maxValue:2 target:self action:@selector(changePressure:)];
    self.pressureSlider.frame=NSMakeRect(20,365,500,28);self.pressureSlider.continuous=YES;
    self.pressureSlider.numberOfTickMarks=5;[pv addSubview:self.pressureSlider];
    NSButton *reset=[NSButton buttonWithTitle:@"Reset to linear" target:self action:@selector(resetPressure:)];reset.frame=NSMakeRect(520,365,130,28);[pv addSubview:reset];
    self.pressureDescription=label(@"",NSMakeRect(20,325,620,24));[pv addSubview:self.pressureDescription];
    [pv addSubview:label(@"Live tester — accepted pen packets",NSMakeRect(20,265,620,28))];
    [pv addSubview:label(@"Raw",NSMakeRect(20,220,100,24))];
    [pv addSubview:label(@"Effective",NSMakeRect(20,170,100,24))];
    self.rawMeter=[[NSLevelIndicator alloc]initWithFrame:NSMakeRect(130,220,500,24)];
    self.effectiveMeter=[[NSLevelIndicator alloc]initWithFrame:NSMakeRect(130,170,500,24)];
    for(NSLevelIndicator *meter in @[self.rawMeter,self.effectiveMeter]){meter.levelIndicatorStyle=NSLevelIndicatorStyleContinuousCapacity;meter.minValue=0;meter.maxValue=1;meter.warningValue=1;meter.criticalValue=1;[pv addSubview:meter];}
    self.tester=label(@"Inactive",NSMakeRect(20,95,620,50));self.tester.maximumNumberOfLines=2;[pv addSubview:self.tester];
    [pv addSubview:label(@"Saved automatically. Applies immediately to the running pen in every app.",NSMakeRect(20,40,620,40))];
    NSTabViewItem *buttons=[[NSTabViewItem alloc]initWithIdentifier:@"buttons"];buttons.label=@"Buttons";[tabs addTabViewItem:buttons];
    NSView *bv=[[NSView alloc]initWithFrame:v.frame];buttons.view=bv;
    [bv addSubview:label(@"Side button shortcuts — shared across apps",NSMakeRect(20,440,620,28))];
    [bv addSubview:label(@"Click Record, then type a key with optional ⌘ ⇧ ⌥ ⌃ modifiers.",NSMakeRect(20,400,620,24))];
    NSMutableArray *editors=[NSMutableArray array];
    for(NSUInteger i=0;i<2;i++){
        CGFloat y=310-i*100;
        [bv addSubview:label(i==0?@"Side button 1 (barrel)":@"Side button 2 (secondary)",NSMakeRect(20,y+32,600,24))];
        UPShortcutEditor *editor=[[UPShortcutEditor alloc]initWithFrame:NSMakeRect(20,y,450,30)];editor.bezelStyle=NSBezelStyleRounded;editor.binding=self.bindings[i];
        __weak UPApp *weakSelf=self;
        editor.bindingChanged=^(NSDictionary *binding){UPApp *owner=weakSelf;if(!owner)return;owner.bindings[i]=binding;[owner saveBindings];};
        [bv addSubview:editor];[editors addObject:editor];
        NSButton *clear=[NSButton buttonWithTitle:@"Clear / Unassigned" target:self action:@selector(clearBinding:)];clear.tag=i;clear.frame=NSMakeRect(480,y,170,30);[bv addSubview:clear];
    }
    self.editors=editors;
    [bv addSubview:label(@"One shortcut per press. Native pen button flags are preserved.",NSMakeRect(20,110,620,24))];
    [bv addSubview:label(@"Shortcuts pause while recording. Escape cancels recording.",NSMakeRect(20,75,620,24))];
    [tabs selectTabViewItemAtIndex:0];
}
- (void)changePressure:(id)sender {
    (void)sender;self.exponent=UPValidatedExponent(@(exp2(self.pressureSlider.doubleValue)));
    [self.preferences setDouble:self.exponent forKey:@"penPressureExponent"];
    [BTPenMonitor updatePressureExponent:self.exponent];[self refresh:nil];
}
- (void)resetPressure:(id)sender {(void)sender;self.pressureSlider.doubleValue=0;[self changePressure:nil];}
- (void)saveBindings {
    [BTPenMonitor updateShortcutBindings:self.bindings];
    NSMutableArray *saved=[NSMutableArray array];
    for(id binding in self.bindings)[saved addObject:binding==NSNull.null?@{}:binding];
    [self.preferences setObject:saved forKey:@"penShortcutBindings"];
}
- (void)clearBinding:(NSButton *)sender {
    [self.window makeFirstResponder:nil];self.bindings[sender.tag]=NSNull.null;
    self.editors[sender.tag].binding=NSNull.null;[self saveBindings];
}
- (void)windowDidResignKey:(NSNotification *)note {(void)note;[self.window makeFirstResponder:nil];}
- (void)tabView:(NSTabView *)tabView willSelectTabViewItem:(NSTabViewItem *)item {(void)tabView;(void)item;[self.window makeFirstResponder:nil];}
- (void)reloadDisplays:(NSNotification *)note {
    (void)note;[self.touch stop];[self.displays removeAllItems];
    [self.displays addItemWithTitle:@"Choose the Bosto display…"];
    for(NSDictionary *d in BTAvailableDisplays()){[self.displays addItemWithTitle:d[@"name"]];self.displays.lastItem.representedObject=d;}
    [self.displays selectItemAtIndex:0];
}
- (void)selectDisplay:(id)sender {(void)sender;[self.touch stop];self.failure=nil;[self refresh:nil];}
- (void)toggle:(id)sender {
    (void)sender;if(self.touch.running){[self disable:nil];return;}
    NSDictionary *display=self.displays.selectedItem.representedObject;
    NSScanner *ds=[NSScanner scannerWithString:self.delay.stringValue];double delay=0;
    if(!display || ![ds scanDouble:&delay] || !ds.isAtEnd || !isfinite(delay) || delay<0 || delay>30){self.failure=@"Choose a display; delay must be 0–30.";[self refresh:nil];return;}
    self.failure=nil;
    if(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)!=kIOHIDAccessTypeGranted){IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);self.failure=@"Grant Input Monitoring to BostoTablet, then Enable again.";[self refresh:nil];return;}
    if(!CGPreflightPostEventAccess()){CGRequestPostEventAccess();self.failure=@"Grant Accessibility to BostoTablet, then Enable again.";[self refresh:nil];return;}
    [self.touch updateResumeDelay:delay];[BTPenMonitor configureDisplay:[display[@"id"] unsignedIntValue] pressureExponent:self.exponent];
    NSError *error=nil;if(![self.touch startWithDisplay:[display[@"id"] unsignedIntValue] postEvents:YES error:&error])self.failure=error.localizedDescription;
    [self refresh:nil];
}
- (void)penFailed:(NSNotification *)note {[self.touch stop];self.failure=note.userInfo[@"reason"];[self refresh:nil];}
- (void)disable:(id)sender {(void)sender;[self.touch stop];self.failure=nil;[self refresh:nil];}
- (void)show:(id)sender {(void)sender;[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];}
- (void)refresh:(NSTimer *)timer {
    (void)timer;BOOL running=self.touch.running;
    self.enable.title=running?@"Disable pen and touch":@"Enable pen and touch";self.item.button.title=running?@"Bosto On":@"Bosto Off";
    self.delay.enabled=self.displays.enabled=!running;
    self.pressureDescription.stringValue=[NSString stringWithFormat:@"Curve exponent %.2f%@",self.exponent,self.exponent==1?@" — linear (default)":@""];
    self.status.stringValue=self.failure?:running?self.touch.status:@"Disabled — choose a display, then Enable.";
    NSMutableDictionary *state=[self.touch.snapshot mutableCopy];
    state[@"penSeized"]=state[@"penObserver"][@"seized"]?:@NO;
    NSDictionary *pen=state[@"penObserver"];
    NSString *phase=pen[@"pressureState"]?:@"inactive";
    NSDictionary *names=@{@"inactive":@"Inactive — enable pen and touch to test",@"noData":@"No data — waiting for an accepted pen packet",@"outOfRange":@"Pen out of range",@"tipUp":@"Tip up",@"tipDown":@"Tip down"};
    self.rawMeter.doubleValue=[pen[@"rawPressure"] doubleValue]/8192.0;
    self.effectiveMeter.doubleValue=[pen[@"effectivePressure"] doubleValue];
    self.tester.stringValue=[NSString stringWithFormat:@"%@\nRaw %.0f / 8192 · Effective %.1f%%",names[phase]?:phase,[pen[@"rawPressure"] doubleValue],100*[pen[@"effectivePressure"] doubleValue]];
    NSDictionary *d=@{@"app":@"local.BostoTablet",@"state":state,@"listenAccess":@(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)),@"postEventAccess":@(CGPreflightPostEventAccess()),@"legacy782C":@"Unsupported: different 19MB protocol; no legacy binary or guessed profile.",@"penWrites":@0};
    NSData *data=[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];self.diagnostics.string=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]?:@"Diagnostics unavailable";
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {
    [self.touch stop];
    // Let queued HID cleanup finish before AppKit exits its owner run loop.
    dispatch_async(dispatch_get_main_queue(),^{[app replyToApplicationShouldTerminate:YES];});
    return NSTerminateLater;
}
- (void)applicationWillTerminate:(NSNotification *)note {(void)note;[self.touch stop];[self.timer invalidate];[NSNotificationCenter.defaultCenter removeObserver:self];[NSStatusBar.systemStatusBar removeStatusItem:self.item];}
@end
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc==2 && strcmp(argv[1],"--self-check")==0){
        const uint8_t bytes[]={1,0x11,0,0x23,0,0x14,0,0x10};UPPacket p={0};UPState s={0};UPBatch b={0};
        if(!UPParse(bytes,8,&p)||!UPAdvance(&s,p,CGRectMake(0,0,1920,1080),1,&b))return 1;
        BOOL ok=b.count==2 && CGEventGetType(b.events[1])==kCGEventLeftMouseDown && CGEventGetIntegerValueField(b.events[1],kCGMouseEventSubtype)==1 && fabs(CGEventGetDoubleValueField(b.events[1],kCGTabletEventPointPressure)-0.5)<0.0001;
        UPClear(&b);UPCancel(&s,&b);ok=ok && b.count==2;UPClear(&b);
        UPButtonState buttons={0};UPPacket held={.inRange=true,.barrel=true,.tip=true,.pressure=4096};
        ok=ok && UPPressure(held,2)==0.25 && UPButtonPresses(&buttons,held,false)==0;
        held.barrel=false;ok=ok && UPButtonPresses(&buttons,held,false)==0;
        held.barrel=true;ok=ok && UPButtonPresses(&buttons,held,false)==1 && UPButtonPresses(&buttons,held,false)==0;
        ok=ok && UPValidatedExponent(@"invalid")==1 && [UPValidatedBindings(nil)[0] isEqual:NSNull.null];
        UPBatch keys={0};ok=ok && UPShortcutEvents(6,kCGEventFlagMaskCommand,&keys) && keys.count==2;
        if(keys.count==2)ok=ok && CGEventGetType(keys.events[0])==kCGEventKeyDown && CGEventGetType(keys.events[1])==kCGEventKeyUp && CGEventGetFlags(keys.events[1])==0;
        UPClear(&keys);
        puts(ok?"BostoTablet offline self-check passed; no HID, GUI, input posting or preferences accessed.":"Self-check failed");return ok?0:1;
    }
    if(argc!=1){fprintf(stderr,"Usage: BostoTablet [--self-check]\n");return 2;}
    NSApplication *app=NSApplication.sharedApplication;[app setActivationPolicy:NSApplicationActivationPolicyAccessory];UPApp *delegate=[UPApp new];app.delegate=delegate;[app run];
}return 0;}
