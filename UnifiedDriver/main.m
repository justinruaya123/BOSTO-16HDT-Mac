#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <ServiceManagement/ServiceManagement.h>
#import "BTTouchController.h"
#import "UnifiedMonitor.h"
#import "UnifiedPen.h"
#include <math.h>
#import "ShortcutEditor.h"
#import "SetupState.h"
#import "UpdateController.h"
#import "PenBattery.h"
#import "BatteryNotifications.h"
#import "MenuIcon.h"
static NSTextField *label(NSString *text,NSRect r) {NSTextField *v=[NSTextField labelWithString:text];v.frame=r;return v;}
@interface UPApp : NSObject<NSApplicationDelegate,NSWindowDelegate,NSTabViewDelegate>
@property(nonatomic,strong) BTTouchController *touch;
@property(nonatomic,strong) NSWindow *window;
@property(nonatomic,strong) NSStatusItem *item;
@property(nonatomic,strong) UPUpdateController *updater;
@property(nonatomic,strong) UPBatteryNotifications *batteryNotifications;
@property(nonatomic,strong) NSTextField *batteryLabel;
@property(nonatomic,strong) NSMenuItem *batteryMenu;
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
@property(nonatomic,strong) NSArray<NSTextField *> *setupDots,*setupLabels;
@property(nonatomic) BOOL checkingPermission;
@property(nonatomic) BOOL explicitDisplaySelection;
@property(nonatomic,strong) NSButton *openAtLogin;
@property(nonatomic,strong) NSTextField *loginStatus;
@property(nonatomic,copy) NSString *loginError;
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
    self.touch=[BTTouchController new]; // HID opens only through the shared, permission-gated start path.
    self.window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,700,550) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"BostoTablet";self.window.releasedWhenClosed=NO;self.window.delegate=self;
    [self composeControlsInView:self.window.contentView resumeDelay:self.touch.resumeDelay];
    self.item=[NSStatusBar.systemStatusBar statusItemWithLength:28];
    __weak UPApp *owner=self;
    self.batteryNotifications=[[UPBatteryNotifications alloc]initWithReading:^NSNumber *{
        UPApp *app=owner;if(!app || !app.touch.running || app.failure ||
            IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)!=kIOHIDAccessTypeGranted || !CGPreflightPostEventAccess())return nil;
        return UPBatteryPercent(app.touch.snapshot[@"penObserver"][@"batteryPercent"]);
    }];
    NSMenu *menu=[NSMenu new];
    self.batteryMenu=[menu addItemWithTitle:UPBatteryDescription(nil) action:nil keyEquivalent:@""];NSMenuItem *show=[menu addItemWithTitle:@"Show BostoTablet" action:@selector(show:) keyEquivalent:@""];show.target=self;
    NSMenuItem *stop=[menu addItemWithTitle:@"Disable pen and touch" action:@selector(disable:) keyEquivalent:@""];stop.target=self;
    self.updater=[UPUpdateController new];
    NSMenuItem *updates=[menu addItemWithTitle:@"Check for Updates…" action:@selector(checkForUpdates:) keyEquivalent:@""];updates.target=self.updater;
    [menu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];self.item.menu=menu;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(penFailed:) name:UPFailureNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadDisplays:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
    [self reloadDisplays:nil];[self.window center];[self show:nil];
    self.timer=[NSTimer timerWithTimeInterval:0.25 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];[NSRunLoop.currentRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];[self refresh:nil];
    [self preselectLaunchDisplay];
}
- (void)composeControlsInView:(NSView *)root resumeDelay:(double)resumeDelay {
    NSTabView *tabs=[[NSTabView alloc]initWithFrame:NSMakeRect(10,10,680,530)];tabs.delegate=self;[root addSubview:tabs];
    NSTabViewItem *home=[[NSTabViewItem alloc]initWithIdentifier:@"home"];home.label=@"Home / Setup";[tabs addTabViewItem:home];
    NSView *v=[[NSView alloc]initWithFrame:NSMakeRect(0,0,680,500)];home.view=v;
    [v addSubview:label(@"BostoTablet — local candidate",NSMakeRect(20,460,630,24))];
    self.openAtLogin=[NSButton checkboxWithTitle:@"Open at Login" target:self action:@selector(toggleOpenAtLogin:)];
    self.openAtLogin.frame=NSMakeRect(20,430,160,24);[v addSubview:self.openAtLogin];
    self.loginStatus=label(@"",NSMakeRect(185,421,455,38));self.loginStatus.maximumNumberOfLines=2;
    self.loginStatus.font=[NSFont systemFontOfSize:11];[v addSubview:self.loginStatus];
    [v addSubview:label(@"Pen and touch display",NSMakeRect(20,390,180,24))];
    self.displays=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(200,388,440,28) pullsDown:NO];self.displays.target=self;self.displays.action=@selector(selectDisplay:);[v addSubview:self.displays];
    [v addSubview:label(@"Touch delay after pen exit (0–30 s)",NSMakeRect(20,347,300,24))];
    self.delay=[[NSTextField alloc]initWithFrame:NSMakeRect(340,347,90,24)];self.delay.doubleValue=resumeDelay;[v addSubview:self.delay];
    self.enable=[NSButton buttonWithTitle:@"Enable pen and touch" target:self action:@selector(toggle:)];self.enable.frame=NSMakeRect(20,289,225,32);[v addSubview:self.enable];
    NSButton *quit=[NSButton buttonWithTitle:@"Quit" target:NSApp action:@selector(terminate:)];quit.frame=NSMakeRect(550,289,90,32);[v addSubview:quit];
    self.status=label(@"",NSMakeRect(250,265,290,65));self.status.maximumNumberOfLines=4;self.status.lineBreakMode=NSLineBreakByWordWrapping;self.status.font=[NSFont systemFontOfSize:11];[v addSubview:self.status];
    NSBox *box=[[NSBox alloc]initWithFrame:NSMakeRect(20,90,620,165)];box.title=@"Current session and app permissions";[v addSubview:box];
    NSMutableArray *dots=[NSMutableArray array],*rows=[NSMutableArray array];
    NSArray *titles=@[@"Pen",@"Touch",@"Input Monitoring",@"Accessibility"];
    for(NSUInteger i=0;i<titles.count;i++){
        CGFloat y=112-i*30;
        NSTextField *dot=label(@"●",NSMakeRect(12,y,18,22));dot.font=[NSFont systemFontOfSize:14];
        NSTextField *row=label(@"",NSMakeRect(190,y,395,22));
        [box.contentView addSubview:dot];[box.contentView addSubview:label(titles[i],NSMakeRect(38,y,150,22))];[box.contentView addSubview:row];
        [dots addObject:dot];[rows addObject:row];
    }
    self.setupDots=dots;self.setupLabels=rows;
    NSTextField *scope=label(@"Permissions apply to BostoTablet as a whole. Active means accepted reports in this session.\nReport activity does not verify delivery to apps or gesture handling.",NSMakeRect(20,25,620,55));scope.maximumNumberOfLines=3;scope.font=[NSFont systemFontOfSize:11];[v addSubview:scope];
    NSTabViewItem *diagnostics=[[NSTabViewItem alloc]initWithIdentifier:@"diagnostics"];diagnostics.label=@"Diagnostics";
    NSView *dv=[[NSView alloc]initWithFrame:v.frame];diagnostics.view=dv;
    NSScrollView *scroll=[[NSScrollView alloc]initWithFrame:NSMakeRect(20,20,620,440)];scroll.hasVerticalScroller=YES;
    self.diagnostics=[[NSTextView alloc]initWithFrame:scroll.bounds];self.diagnostics.editable=NO;self.diagnostics.font=[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];scroll.documentView=self.diagnostics;[dv addSubview:scroll];
    NSTabViewItem *pen=[[NSTabViewItem alloc]initWithIdentifier:@"pen"];pen.label=@"Pen";[tabs addTabViewItem:pen];
    NSView *pv=[[NSView alloc]initWithFrame:v.frame];pen.view=pv;
    self.batteryLabel=label(UPBatteryDescription(nil),NSMakeRect(20,300,620,24));[pv addSubview:self.batteryLabel];
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
    [tabs addTabViewItem:diagnostics];
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
- (void)applicationDidBecomeActive:(NSNotification *)note {(void)note;[self refresh:nil];}
- (void)windowDidBecomeKey:(NSNotification *)note {(void)note;[self refresh:nil];}
- (void)windowDidResignKey:(NSNotification *)note {(void)note;[self.window makeFirstResponder:nil];}
- (void)tabView:(NSTabView *)tabView willSelectTabViewItem:(NSTabViewItem *)item {(void)tabView;(void)item;[self.window makeFirstResponder:nil];}
- (void)reloadDisplays:(NSNotification *)note {
    (void)note;[self.touch stop];[self.displays removeAllItems];
    [self.displays addItemWithTitle:@"Choose the Bosto display…"];
    for(NSDictionary *d in BTAvailableDisplays()){[self.displays addItemWithTitle:d[@"name"]];self.displays.lastItem.representedObject=d;}
    [self.displays selectItemAtIndex:0];self.explicitDisplaySelection=NO;
    if(note){self.failure=@"Off: display configuration changed. Choose a display and Enable manually.";[self refresh:nil];}
}
- (void)selectDisplay:(id)sender {(void)sender;[self.touch stop];self.explicitDisplaySelection=self.displays.selectedItem.representedObject!=nil;self.failure=nil;[self refresh:nil];}
- (void)openPermissionSettings:(NSString *)pane {
    NSWorkspace *workspace=NSWorkspace.sharedWorkspace;
    NSURL *url=[NSURL URLWithString:[@"x-apple.systempreferences:com.apple.preference.security?" stringByAppendingString:pane]];
    if(![workspace openURL:url])[workspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security"]];
}
- (void)preselectLaunchDisplay {
    NSString *reason=nil;
    id saved=[self.preferences objectForKey:@"selectedDisplayUUID"];
    NSString *uuid=[saved isKindOfClass:NSString.class]?saved:nil;
    NSDictionary *display=UPLaunchDisplay(BTAvailableDisplays(),uuid,&reason);
    if(!display){self.failure=reason;[self refresh:nil];return;}
    for(NSMenuItem *item in self.displays.itemArray){
        if([item.representedObject isEqual:display]){[self.displays selectItem:item];break;}
    }
    self.explicitDisplaySelection=NO;
    [self refresh:nil];
}
- (void)toggle:(id)sender {
    (void)sender;
    if(self.touch.running){[self disable:nil];return;}
    [self startSelectedDisplay];
}
- (void)startSelectedDisplay {
    if(self.checkingPermission || self.touch.running)return;
    UPEnableAction action=UPSetupAction(NO,IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)==kIOHIDAccessTypeGranted,CGPreflightPostEventAccess());
    self.failure=nil;
    if(action==UPRequestInputMonitoring || action==UPRequestAccessibility){
        BOOL listen=action==UPRequestInputMonitoring;
        self.checkingPermission=YES;self.enable.enabled=NO;
        NSLog(@"BostoTablet: start requested %@",listen?@"Input Monitoring":@"Accessibility (AX prompt)");
        if(!listen){
            AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES});
            // The AX prompt is asynchronous. Give it a bounded head start before Settings.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
                if(!CGPreflightPostEventAccess())[self openPermissionSettings:@"Privacy_Accessibility"];
                self.checkingPermission=NO;
                [self refresh:nil];
            });
            return; // A manual retry starts HID or requests the next missing grant.
        }
        UPRequestSetupPermission(^BOOL{
            return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)==kIOHIDAccessTypeGranted;
        },^{
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
        },^{[self openPermissionSettings:@"Privacy_ListenEvent"];});
        self.checkingPermission=NO;
        // Even a synchronous grant ends this click. The next deliberate click starts or requests the next grant.
        [self refresh:nil];return;
    }
    NSDictionary *display=self.displays.selectedItem.representedObject;
    NSScanner *ds=[NSScanner scannerWithString:self.delay.stringValue];double delay=0;
    if(!display || ![ds scanDouble:&delay] || !ds.isAtEnd || !isfinite(delay) || delay<0 || delay>30){self.failure=@"Choose a display; delay must be 0–30.";[self refresh:nil];return;}
    [self.touch updateResumeDelay:delay];[BTPenMonitor configureDisplay:[display[@"id"] unsignedIntValue] pressureExponent:self.exponent];
    NSError *error=nil;
    if(![self.touch startWithDisplay:[display[@"id"] unsignedIntValue] postEvents:YES error:&error])
        self.failure=[NSString stringWithFormat:@"Off: %@ Reconnect the selected display and exact Bosto USB pen/touch, then Enable manually.",error.localizedDescription?:@"Device start failed."];
    else if(self.explicitDisplaySelection && [display[@"uuid"] length]>0)
        [self.preferences setObject:display[@"uuid"] forKey:@"selectedDisplayUUID"];
    [self refresh:nil];
}
- (void)refreshLoginStatus {
    NSString *status=@"Requires macOS 13 or later";
    self.openAtLogin.enabled=NO;self.openAtLogin.state=NSControlStateValueOff;
    if(@available(macOS 13.0,*)){
        self.openAtLogin.enabled=YES;
        switch(SMAppService.mainAppService.status){
            case SMAppServiceStatusEnabled: status=@"On — opens at login";self.openAtLogin.state=NSControlStateValueOn;break;
            case SMAppServiceStatusRequiresApproval: status=@"Approval needed — check to open Login Items";self.openAtLogin.state=NSControlStateValueOff;break;
            case SMAppServiceStatusNotRegistered: status=@"Off";break;
            case SMAppServiceStatusNotFound: status=@"Unavailable — app service not found";break;
        }
    }
    self.loginStatus.stringValue=self.loginError?[NSString stringWithFormat:@"%@ — %@",status,self.loginError]:status;
}
- (void)toggleOpenAtLogin:(NSButton *)sender {
    if(@available(macOS 13.0,*)){
        BOOL enable=sender.state==NSControlStateValueOn;
        SMAppService *service=SMAppService.mainAppService;
        NSError *error=nil;BOOL success=YES;
        self.loginError=nil;
        if(enable){
            if(service.status!=SMAppServiceStatusEnabled && service.status!=SMAppServiceStatusRequiresApproval)
                success=[service registerAndReturnError:&error];
            if(service.status==SMAppServiceStatusRequiresApproval)[SMAppService openSystemSettingsLoginItems];
        }else success=[service unregisterAndReturnError:&error];
        if(!success)self.loginError=error.localizedDescription?:@"Login setting could not be changed";
    }
    [self refreshLoginStatus];
}
- (void)penFailed:(NSNotification *)note {[self.touch stop];self.failure=note.userInfo[@"reason"];[self refresh:nil];}
- (void)disable:(id)sender {(void)sender;[self.touch stop];self.failure=nil;[self refresh:nil];}
- (void)show:(id)sender {(void)sender;[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];}
- (void)refresh:(NSTimer *)timer {
    if(!self.touch || !self.enable)return;
    (void)timer;BOOL running=self.touch.running;
    [self refreshLoginStatus];
    self.delay.enabled=self.displays.enabled=!running;
    self.pressureDescription.stringValue=[NSString stringWithFormat:@"Curve exponent %.2f%@",self.exponent,self.exponent==1?@" — linear (default)":@""];
    NSMutableDictionary *state=[self.touch.snapshot mutableCopy];
    state[@"penSeized"]=state[@"penObserver"][@"seized"]?:@NO;
    BOOL listen=IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)==kIOHIDAccessTypeGranted;
    BOOL post=CGPreflightPostEventAccess();
    self.enable.title=running?@"Disable pen and touch":!listen?@"Request Input Monitoring…":!post?@"Request Accessibility…":@"Enable pen and touch";
    self.enable.enabled=!self.checkingPermission;
    UPMenuState menuState=UPSetupMenuState(state,listen,post,self.failure!=nil);
    NSString *description=menuState==UPMenuPen?@"BostoTablet: pen in range or palm cooldown":menuState==UPMenuTouch?@"BostoTablet: touch gestures ready":@"BostoTablet: unavailable — check setup";
    self.item.button.image=UPMenuIcon(menuState);
    self.item.button.toolTip=description;[self.item.button setAccessibilityLabel:description];
    NSNumber *battery=running && listen && post && !self.failure && [state[@"penObserver"][@"running"] boolValue]?UPBatteryPercent(state[@"penObserver"][@"batteryPercent"]):nil;
    self.batteryLabel.stringValue=self.batteryMenu.title=UPBatteryDescription(battery);
    [self.batteryNotifications refresh];
    NSDictionary *setup=UPSetupStatus(state,listen,post);
    NSArray *keys=@[@"pen",@"touch",@"listen",@"post"];
    NSDictionary *colors=@{@"off":NSColor.secondaryLabelColor,@"waiting":NSColor.systemOrangeColor,@"active":NSColor.systemGreenColor};
    for(NSUInteger i=0;i<keys.count;i++){
        self.setupLabels[i].stringValue=setup[keys[i]];
        NSString *tone=i<2?setup[[keys[i] stringByAppendingString:@"Tone"]]:((i==2?listen:post)?@"active":@"waiting");
        self.setupDots[i].textColor=colors[tone];
    }
    NSString *guidance;
    if(!listen || !post)guidance=[NSString stringWithFormat:@"Request %@, then allow BostoTablet in Settings. If already on, quit and relaunch. Enable pen and touch once both are granted.",!listen?@"Input Monitoring":@"Accessibility"];
    else guidance=running?self.touch.status:@"Choose a display and delay, then Enable pen and touch.";
    self.status.stringValue=self.failure?:guidance;
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
