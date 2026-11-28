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
static NSString *const UPAutoDetectKey=@"autoDetectTablet";
static NSString *const UPFlipTouchYKey=@"flipTouchY";
static NSString *const UPTouchInputKey=@"touchInputEnabled";
static NSString *const UPPenInputKey=@"penInputEnabled";
static NSString *const UPInputDisabledKey=@"inputDisabled";
static NSString *const UPTouchModeKey=@"touchMode"; // Only an explicit Compatibility selection opts out of Native.
static NSString *const UPGestureActionsKey=@"gestureActions";
static NSString *gestureKey(NSUInteger row) { return row==0?@"swipe":@"pinch"; }
static NSTextField *label(NSString *text,NSRect r) {NSTextField *v=[NSTextField labelWithString:text];v.frame=r;return v;}
@interface UPApp : NSObject<NSApplicationDelegate,NSWindowDelegate,NSTabViewDelegate>
@property(nonatomic,strong) BTTouchController *touch;
@property(nonatomic,strong) NSWindow *window;
@property(nonatomic,strong) NSStatusItem *item;
@property(nonatomic,strong) UPUpdateController *updater;
@property(nonatomic,strong) UPBatteryNotifications *batteryNotifications;
@property(nonatomic,strong) NSTextField *batteryLabel;
@property(nonatomic,strong) NSMenuItem *batteryMenu;
@property(nonatomic,strong) NSPopUpButton *displays,*touchOrientation;
@property(nonatomic,strong) NSTextField *delay,*status,*pressureDescription,*tester;
@property(nonatomic,strong) NSSlider *pressureSlider;
@property(nonatomic,strong) NSLevelIndicator *rawMeter,*effectiveMeter;
@property(nonatomic,strong) NSArray<UPShortcutEditor *> *editors;
@property(nonatomic,strong) NSArray<UPShortcutEditor *> *gestureEditors;
@property(nonatomic,strong) NSArray<NSPopUpButton *> *gesturePickers;
@property(nonatomic,strong) NSTextField *gestureStatus;
@property(nonatomic,strong) NSMutableArray *bindings;
@property(nonatomic,strong) NSUserDefaults *preferences;
@property(nonatomic) double exponent;
@property(nonatomic,strong) NSTextView *diagnostics;
@property(nonatomic,strong) NSButton *enable,*touchInput,*penInput;
@property(nonatomic) BOOL changingInputs;
@property(nonatomic,strong) NSArray<NSTextField *> *setupDots,*setupLabels;
@property(nonatomic) BOOL checkingPermission;
@property(nonatomic,strong) NSButton *autoDetectTablet;
@property(nonatomic,strong) NSButton *openAtLogin;
@property(nonatomic,strong) NSTextField *loginStatus;
@property(nonatomic,copy) NSString *loginError;
@property(nonatomic,strong) NSTimer *timer,*inputTimer;
@property(nonatomic,copy) NSArray *lastInputAttempt;
@property(nonatomic) BOOL inputSleeping,inputSessionInactive,inputTerminating;
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
    NSMenuItem *stop=[menu addItemWithTitle:@"Stop driver (release tablet)" action:@selector(disable:) keyEquivalent:@""];stop.target=self;
    self.updater=[UPUpdateController new];
    NSMenuItem *updates=[menu addItemWithTitle:@"Check for Updates…" action:@selector(checkForUpdates:) keyEquivalent:@""];updates.target=self.updater;
    [menu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];self.item.menu=menu;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(penFailed:) name:UPFailureNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadDisplays:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
    [self reloadDisplays:nil];[self.window center];[self show:nil];
    self.timer=[NSTimer timerWithTimeInterval:0.25 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];[NSRunLoop.currentRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];[self refresh:nil];
    NSNotificationCenter *workspaceNotes=NSWorkspace.sharedWorkspace.notificationCenter;
    [workspaceNotes addObserver:self selector:@selector(inputSleepChanged:) name:NSWorkspaceWillSleepNotification object:nil];
    [workspaceNotes addObserver:self selector:@selector(inputSleepChanged:) name:NSWorkspaceDidWakeNotification object:nil];
    [workspaceNotes addObserver:self selector:@selector(inputSessionChanged:) name:NSWorkspaceSessionDidResignActiveNotification object:nil];
    [workspaceNotes addObserver:self selector:@selector(inputSessionChanged:) name:NSWorkspaceSessionDidBecomeActiveNotification object:nil];
    self.inputTimer=[NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){(void)timer;[owner reconcileInput];}];
    [NSRunLoop.currentRunLoop addTimer:self.inputTimer forMode:NSDefaultRunLoopMode];
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
    self.displays=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(200,388,255,28) pullsDown:NO];self.displays.target=self;self.displays.action=@selector(selectDisplay:);[v addSubview:self.displays];
    self.autoDetectTablet=[NSButton checkboxWithTitle:@"Auto-detect tablet" target:self action:@selector(toggleAutoDetectTablet:)];
    self.autoDetectTablet.frame=NSMakeRect(470,390,170,24);[v addSubview:self.autoDetectTablet];
    [v addSubview:label(@"Compatibility touch Y",NSMakeRect(20,322,180,24))];
    self.touchOrientation=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(200,320,235,28) pullsDown:NO];
    [self.touchOrientation setAccessibilityLabel:@"Compatibility touch orientation"];
    self.touchOrientation.toolTip=@"Applies only to direct touch in Compatibility mode.";
    [self.touchOrientation addItemsWithTitles:@[@"Normal",@"Flip vertical"]];
    [self.touchOrientation selectItemAtIndex:[[self.preferences objectForKey:UPFlipTouchYKey] isEqual:@YES]?1:0];
    self.touchOrientation.target=self;self.touchOrientation.action=@selector(changeTouchOrientation:);[v addSubview:self.touchOrientation];
    [v addSubview:label(@"Touch delay after pen exit (0–30 s)",NSMakeRect(20,352,300,24))];
    self.delay=[[NSTextField alloc]initWithFrame:NSMakeRect(340,352,90,24)];self.delay.doubleValue=resumeDelay;[v addSubview:self.delay];
    self.enable=[NSButton buttonWithTitle:@"Start driver" target:self action:@selector(toggle:)];self.enable.frame=NSMakeRect(20,278,225,32);[v addSubview:self.enable];
    NSButton *quit=[NSButton buttonWithTitle:@"Quit" target:NSApp action:@selector(terminate:)];quit.frame=NSMakeRect(550,278,90,32);[v addSubview:quit];
    self.status=label(@"",NSMakeRect(250,255,290,65));self.status.maximumNumberOfLines=4;self.status.lineBreakMode=NSLineBreakByWordWrapping;self.status.font=[NSFont systemFontOfSize:11];[v addSubview:self.status];
    NSBox *box=[[NSBox alloc]initWithFrame:NSMakeRect(20,80,620,165)];box.title=@"Requested inputs and current session";[v addSubview:box];
    NSMutableArray *dots=[NSMutableArray array],*rows=[NSMutableArray array];
    NSArray *titles=@[@"Pen input",@"Touch input",@"Input Monitoring",@"Accessibility"];
    for(NSUInteger i=0;i<titles.count;i++){
        CGFloat y=112-i*30;
        NSTextField *dot=label(@"●",NSMakeRect(12,y,18,22));dot.font=[NSFont systemFontOfSize:14];
        NSTextField *row=label(@"",NSMakeRect(190,y,395,22));
        [box.contentView addSubview:dot];[box.contentView addSubview:row];
        if(i<2){
            NSButton *input=[NSButton checkboxWithTitle:titles[i] target:self action:@selector(changeInput:)];
            input.frame=NSMakeRect(38,y,145,22);
            input.state=[self requestsInputForKey:i==0?UPPenInputKey:UPTouchInputKey]?NSControlStateValueOn:NSControlStateValueOff;
            if(i==0)self.penInput=input;else self.touchInput=input;
            [box.contentView addSubview:input];
        }else [box.contentView addSubview:label(titles[i],NSMakeRect(38,y,150,22))];
        [dots addObject:dot];[rows addObject:row];
    }
    self.setupDots=dots;self.setupLabels=rows;
    NSTextField *scope=label(@"These switches save your Bosto display preferences. While running, both off mutes this tablet. Stop releases it to macOS.\nActive means reports received, not verified delivery to apps.",NSMakeRect(20,25,620,55));scope.maximumNumberOfLines=3;scope.font=[NSFont systemFontOfSize:11];[v addSubview:scope];
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
    [tabs addTabViewItem:[self gestureTabWithFrame:v.frame]];
    [tabs addTabViewItem:diagnostics];
    [tabs selectTabViewItemAtIndex:0];
}
- (BOOL)requestsNativeTouch {
    return ![[self.preferences objectForKey:UPTouchModeKey] isEqual:@"compatibility"];
}
- (NSDictionary *)savedGestureActions {
    id saved=[self.preferences objectForKey:UPGestureActionsKey];
    return [saved isKindOfClass:NSDictionary.class]?saved:@{};
}
- (void)saveGestureAction:(id)action forKey:(NSString *)key {
    if(self.requestsNativeTouch || self.changingInputs)return;
    NSMutableDictionary *actions=[self.savedGestureActions mutableCopy];
    actions[key]=action;
    [self.preferences setObject:actions forKey:UPGestureActionsKey];
    if(self.touch.running)self.touch.gestureActions=actions;
}
- (void)updateCompatibilityControls {
    BOOL editable=!self.requestsNativeTouch && !self.changingInputs;
    self.touchOrientation.enabled=editable;
    for(NSPopUpButton *picker in self.gesturePickers){
        picker.enabled=editable;
        self.gestureEditors[(NSUInteger)picker.tag].enabled=editable && picker.indexOfSelectedItem==1;
    }
}
- (NSTabViewItem *)gestureTabWithFrame:(NSRect)frame {
    NSTabViewItem *tab=[[NSTabViewItem alloc]initWithIdentifier:@"gestures"];
    tab.label=@"Gestures";
    NSView *view=[[NSView alloc]initWithFrame:frame];tab.view=view;
    [view addSubview:label(@"Touch mode",NSMakeRect(20,438,135,24))];
    NSPopUpButton *mode=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(160,435,270,28) pullsDown:NO];
    [mode setAccessibilityLabel:@"Touch mode"];
    [mode addItemsWithTitles:@[@"Native multitouch",@"Compatibility"]];
    [mode selectItemAtIndex:self.requestsNativeTouch?0:1];mode.target=self;mode.action=@selector(changeTouchMode:);[view addSubview:mode];
    NSTextField *explanation=label(@"Native multitouch: one finger points, taps on lift, or drags. Two or more fingers go to macOS for gestures. Choose Compatibility for driver-generated scroll, zoom, or shortcuts.",NSMakeRect(20,372,620,58));
    explanation.maximumNumberOfLines=3;explanation.lineBreakMode=NSLineBreakByWordWrapping;[view addSubview:explanation];
    NSArray *titles=@[@"Two-finger swipe: scroll / pan",@"Pinch: zoom"];
    NSMutableArray *editors=[NSMutableArray array],*pickers=[NSMutableArray array];
    for(NSUInteger row=0;row<titles.count;row++){
        NSString *key=gestureKey(row);id action=self.savedGestureActions[key];
        NSDictionary *binding=UPValidatedShortcut(action);
        BOOL isBinding=binding!=nil;
        NSInteger mode=[action isEqual:@"off"]?2:(isBinding || [action isEqual:@"shortcut"])?1:0;
        CGFloat y=311-row*79;
        [view addSubview:label(titles[row],NSMakeRect(20,y+30,620,24))];
        NSPopUpButton *picker=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(20,y,210,28) pullsDown:NO];
        [picker setAccessibilityLabel:titles[row]];
        [picker addItemsWithTitles:@[@"Default",@"Keyboard Shortcut",@"Off"]];
        [picker selectItemAtIndex:mode];picker.tag=(NSInteger)row;
        picker.target=self;picker.action=@selector(changeGestureAction:);[view addSubview:picker];[pickers addObject:picker];
        UPShortcutEditor *editor=[[UPShortcutEditor alloc]initWithFrame:NSMakeRect(247,y,375,28)];
        editor.bezelStyle=NSBezelStyleRounded;
        editor.binding=binding;
        __weak UPApp *owner=self;
        editor.bindingChanged=^(NSDictionary *binding){[owner saveGestureAction:binding forKey:key];};
        [view addSubview:editor];[editors addObject:editor];
    }
    self.gestureEditors=editors;self.gesturePickers=pickers;[self updateCompatibilityControls];
    [view addSubview:label(@"Touch shortcuts are saved in both modes but run only in Compatibility.",NSMakeRect(20,183,620,28))];
    self.gestureStatus=label(@"",NSMakeRect(20,70,620,88));
    self.gestureStatus.maximumNumberOfLines=4;
    self.gestureStatus.lineBreakMode=NSLineBreakByWordWrapping;
    self.gestureStatus.font=[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    [view addSubview:self.gestureStatus];
    return tab;
}
- (void)changeGestureAction:(NSPopUpButton *)sender {
    if(self.requestsNativeTouch || self.changingInputs)return;
    NSString *key=gestureKey((NSUInteger)sender.tag);
    UPShortcutEditor *editor=self.gestureEditors[(NSUInteger)sender.tag];
    [self.window makeFirstResponder:nil];
    switch(sender.indexOfSelectedItem){
        case 0:[self saveGestureAction:nil forKey:key];break;
        case 1:[self saveGestureAction:editor.binding?:@"shortcut" forKey:key];break;
        case 2:[self saveGestureAction:@"off" forKey:key];break;
        default:return;
    }
    editor.enabled=sender.indexOfSelectedItem==1;
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
    NSDictionary *previous=self.displays.selectedItem.representedObject;
    [self.displays removeAllItems];
    [self.displays addItemWithTitle:@"Choose the Bosto display…"];
    NSArray<NSDictionary *> *displays=BTAvailableDisplays();
    for(NSDictionary *d in displays){
        // NSPopUpButton's title-based insertion can replace a same-named display.
        NSMenuItem *item=[[NSMenuItem alloc]initWithTitle:d[@"name"] action:NULL keyEquivalent:@""];
        item.representedObject=d;
        [self.displays.menu addItem:item];
    }
    NSString *previousFailure=self.failure;
    BOOL selected=[self preselectDisplayFrom:displays];
    NSDictionary *current=self.displays.selectedItem.representedObject;
    if(note && ![previous isEqual:current]){
        if(self.touch.running)[self.touch stop];
        self.lastInputAttempt=nil;
        if(selected)self.failure=@"Waiting for the tablet connection…";
    } else if(note && selected && !self.touch.running)self.failure=previousFailure;
    [self refresh:nil];
}
- (BOOL)autoDetectTabletEnabled {
    return ![[self.preferences objectForKey:UPAutoDetectKey] isEqual:@NO];
}
- (void)toggleAutoDetectTablet:(NSButton *)sender {
    if(self.touch.running)return;
    [self.preferences setBool:sender.state==NSControlStateValueOn forKey:UPAutoDetectKey];
    self.lastInputAttempt=nil;[self reloadDisplays:nil];
}
- (void)selectDisplay:(id)sender {
    (void)sender;
    if(self.touch.running || self.autoDetectTabletEnabled)return;
    NSDictionary *display=self.displays.selectedItem.representedObject;
    NSString *uuid=display[@"uuid"];
    if(uuid.length && ![display[@"mirrored"] boolValue]){
        [self.preferences setObject:uuid forKey:@"selectedDisplayUUID"];
        self.failure=nil;
    } else {
        [self.preferences removeObjectForKey:@"selectedDisplayUUID"];
        [self.displays selectItemAtIndex:0];
        self.failure=@"Choose a nonmirrored display.";
    }
    [self refresh:nil];
}
- (BOOL)requestsInputForKey:(NSString *)key {
    return ![[self.preferences objectForKey:key] isEqual:@NO];
}
- (void)changeInput:(NSButton *)sender {
    NSString *key=sender==self.touchInput?UPTouchInputKey:UPPenInputKey;
    BOOL enabled=sender.state==NSControlStateValueOn;
    if(enabled==[self requestsInputForKey:key])return;
    [self.preferences setBool:enabled forKey:key];
    [self inputConfigurationChanged];
}
- (void)changeTouchMode:(NSPopUpButton *)sender {
    NSInteger index=sender.indexOfSelectedItem;
    if((index!=0 && index!=1) || (index==0)==self.requestsNativeTouch)return;
    [self.window makeFirstResponder:nil]; // End any in-progress shortcut capture.
    [self.preferences setObject:index==0?@"native":@"compatibility" forKey:UPTouchModeKey];
    [self inputConfigurationChanged];
}
- (void)inputConfigurationChanged {
    if(!self.changingInputs && ![[self.preferences objectForKey:UPInputDisabledKey] isEqual:@YES]){
        self.changingInputs=YES;self.lastInputAttempt=nil;
        // A fault may already have queued cleanup. Never apply settings before those releases.
        if(self.touch.running)[self.touch stop];
        dispatch_async(dispatch_get_main_queue(),^{
            self.changingInputs=NO;
            [self reconcileInput]; // Recheck Stop, connection and grants; read the latest input choices and touch mode.
            [self refresh:nil];
        });
    }
    [self refresh:nil];
}
- (void)changeTouchOrientation:(NSPopUpButton *)sender {
    if(self.requestsNativeTouch || self.changingInputs)return;
    NSInteger index=sender.indexOfSelectedItem;
    if(index!=0 && index!=1)return;
    BOOL flip=index==1;
    if(self.touch.running)self.touch.flipTouchY=flip;
    if(self.touch.running && self.touch.flipTouchY!=flip){
        [sender selectItemAtIndex:self.touch.flipTouchY?1:0];
        NSBeep();
        return;
    }
    [self.preferences setBool:flip forKey:UPFlipTouchYKey];
    [self refresh:nil];
}
- (void)openPermissionSettings:(NSString *)pane {
    NSWorkspace *workspace=NSWorkspace.sharedWorkspace;
    NSURL *url=[NSURL URLWithString:[@"x-apple.systempreferences:com.apple.preference.security?" stringByAppendingString:pane]];
    if(![workspace openURL:url])[workspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security"]];
}
- (BOOL)preselectDisplayFrom:(NSArray<NSDictionary *> *)displays {
    BOOL automatic=self.autoDetectTabletEnabled;
    id saved=[self.preferences objectForKey:@"selectedDisplayUUID"];
    NSString *uuid=[saved isKindOfClass:NSString.class]?saved:nil;
    NSString *reason=nil;
    NSDictionary *display=automatic || uuid.length?UPLaunchDisplay(displays,automatic?nil:uuid,&reason):nil;
    if(display){
        for(NSMenuItem *item in self.displays.itemArray){
            if(![item.representedObject isEqual:display])continue;
            [self.displays selectItem:item];self.failure=nil;
            return YES;
        }
    }
    [self.displays selectItemAtIndex:0];
    self.failure=automatic?@"No unique nonmirrored Bosto Tablet detected. Connect it or turn off Auto-detect to choose a display.":
        reason?:@"Choose a nonmirrored display, then press Start driver.";
    return NO;
}
- (void)preselectLaunchDisplay {
    [self preselectDisplayFrom:BTAvailableDisplays()];
    [self reconcileInput];
    [self refresh:nil];
}
- (void)inputSleepChanged:(NSNotification *)note {
    self.inputSleeping=[note.name isEqual:NSWorkspaceWillSleepNotification];
    if(!self.inputSleeping){self.lastInputAttempt=nil;[self reloadDisplays:nil];}
}
- (void)inputSessionChanged:(NSNotification *)note {
    self.inputSessionInactive=[note.name isEqual:NSWorkspaceSessionDidResignActiveNotification];
    if(!self.inputSessionInactive){self.lastInputAttempt=nil;[self reloadDisplays:nil];}
}
- (NSArray *)inputCandidateForDisplay:(NSDictionary *)display {
    if(!display || [display[@"mirrored"] boolValue])return nil;
    // Screen notifications may still be queued when a switch finishes cleaning up.
    NSDictionary *current=UPLaunchDisplay(BTAvailableDisplays(),self.autoDetectTabletEnabled?nil:display[@"uuid"],NULL);
    if(![current isEqual:display])return nil;
    NSArray<NSNumber *> *devices=BTTabletRegistryIdentity();
    return devices.count?@[display,devices]:nil;
}
- (void)reconcileInput {
    if(self.changingInputs || self.inputTerminating || self.inputSleeping || self.inputSessionInactive || self.checkingPermission || self.touch.running ||
        [[self.preferences objectForKey:UPInputDisabledKey] isEqual:@YES])return;
    if(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)!=kIOHIDAccessTypeGranted || !CGPreflightPostEventAccess()){
        self.lastInputAttempt=nil;return;
    }
    NSDictionary *display=self.displays.selectedItem.representedObject;
    NSArray *candidate=[self inputCandidateForDisplay:display];
    if(!candidate){
        self.lastInputAttempt=nil;
        if(display)self.failure=@"Waiting for the selected display and the Bosto tablet’s USB interfaces…";
        return;
    }
    if([self.lastInputAttempt isEqual:candidate])return;
    self.lastInputAttempt=candidate;
    [self startSelectedDisplayAllowingPermissionRequests:NO];
}
- (void)toggle:(id)sender {
    (void)sender;
    if(self.touch.running || self.changingInputs){[self disable:nil];return;}
    [self.preferences setBool:NO forKey:UPInputDisabledKey];
    [self startSelectedDisplayAllowingPermissionRequests:YES];
}
- (void)startSelectedDisplayAllowingPermissionRequests:(BOOL)allowRequests {
    if(self.changingInputs || self.checkingPermission || self.touch.running)return;
    UPEnableAction action=UPSetupAction(NO,IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)==kIOHIDAccessTypeGranted,CGPreflightPostEventAccess());
    self.failure=nil;
    if(action==UPRequestInputMonitoring || action==UPRequestAccessibility){
        if(!allowRequests){[self refresh:nil];return;}
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
            return; // The timer can start input once all grants are present.
        }
        UPRequestSetupPermission(^BOOL{
            return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)==kIOHIDAccessTypeGranted;
        },^{
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
        },^{[self openPermissionSettings:@"Privacy_ListenEvent"];});
        self.checkingPermission=NO;
        // One permission request per click; automatic start never requests either grant.
        [self refresh:nil];return;
    }
    NSDictionary *display=self.displays.selectedItem.representedObject;
    NSScanner *ds=[NSScanner scannerWithString:self.delay.stringValue];double delay=0;
    if(!display || [display[@"mirrored"] boolValue] || ![ds scanDouble:&delay] || !ds.isAtEnd || !isfinite(delay) || delay<0 || delay>30){self.failure=@"Choose a display; delay must be 0–30.";[self refresh:nil];return;}
    if(allowRequests)self.lastInputAttempt=[self inputCandidateForDisplay:display];
    BOOL native=self.requestsNativeTouch;
    self.touch.nativeTouchEnabled=native;
    self.touch.gestureActions=native?@{}:self.savedGestureActions;
    self.touch.flipTouchY=!native && [[self.preferences objectForKey:UPFlipTouchYKey] isEqual:@YES];
    self.touch.touchInputEnabled=[self requestsInputForKey:UPTouchInputKey];
    self.touch.penInputEnabled=[self requestsInputForKey:UPPenInputKey];
    [self.touch updateResumeDelay:delay];[BTPenMonitor configureDisplay:[display[@"id"] unsignedIntValue] pressureExponent:self.exponent];
    NSError *error=nil;
    if(![self.touch startWithDisplay:[display[@"id"] unsignedIntValue] postEvents:YES error:&error])
        self.failure=[NSString stringWithFormat:@"Off: %@ Reconnect the selected display and Bosto USB pen/touch, or press Start driver to retry.",error.localizedDescription?:@"Device start failed."];
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
- (void)disable:(id)sender {
    (void)sender;[self.preferences setBool:YES forKey:UPInputDisabledKey];
    self.lastInputAttempt=nil;[self.touch stop];self.failure=nil;[self refresh:nil];
}
- (void)show:(id)sender {(void)sender;[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];}
- (void)refresh:(NSTimer *)timer {
    if(!self.touch || !self.enable)return;
    (void)timer;BOOL running=self.touch.running;
    [self refreshLoginStatus];
    BOOL automatic=self.autoDetectTabletEnabled;
    self.autoDetectTablet.state=automatic?NSControlStateValueOn:NSControlStateValueOff;
    self.autoDetectTablet.enabled=self.delay.enabled=!running;
    self.displays.enabled=!running && !automatic;
    self.pressureDescription.stringValue=[NSString stringWithFormat:@"Curve exponent %.2f%@",self.exponent,self.exponent==1?@" — linear (default)":@""];
    NSMutableDictionary *state=[self.touch.snapshot mutableCopy];
    state[@"touchInputEnabled"]=@(self.touch.touchInputEnabled);
    state[@"penInputEnabled"]=@(self.touch.penInputEnabled);
    state[@"penSeized"]=state[@"penObserver"][@"seized"]?:@NO;
    [self updateCompatibilityControls];
    BOOL listen=IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)==kIOHIDAccessTypeGranted;
    BOOL post=CGPreflightPostEventAccess();
    BOOL controlling=UPSetupControlsInput(state,listen,post,self.failure!=nil);
    if(!controlling)self.gestureStatus.stringValue=@"No active touch session confirmed. Check Home / Setup.";
    else if(!self.touch.touchInputEnabled)self.gestureStatus.stringValue=@"Touch is muted by the driver.";
    else {
        NSString *output=self.touch.nativeTouchEnabled?[NSString stringWithFormat:@"Pointer downs: %@ · drags: %@ · ups: %@. macOS handles gestures; app delivery is not measured.",state[@"downEvents"]?:@0,state[@"dragEvents"]?:@0,state[@"upEvents"]?:@0]:
            [NSString stringWithFormat:@"Synthetic scroll events: %@ · synthetic zoom events: %@",state[@"scrollEvents"]?:@0,state[@"magnifyEvents"]?:@0];
        self.gestureStatus.stringValue=[NSString stringWithFormat:@"This session: %@ reports with 2+ contacts · peak %@ fingers\nMultitouch report callbacks: %@\n%@",
            state[@"multiContactFrames"]?:@0,state[@"peakContacts"]?:@0,state[@"rawReportIDs"][@"4"]?:@0,output];
    }
    self.enable.title=running || self.changingInputs?@"Stop driver (release tablet)":!listen?@"Request Input Monitoring…":!post?@"Request Accessibility…":@"Start driver";
    self.enable.enabled=!self.checkingPermission;
    NSDictionary *setup=UPSetupStatus(state,listen,post,self.failure!=nil);
    BOOL waitingForPen=controlling && [state[@"penObserver"][@"waitingForDevice"] boolValue];
    UPMenuState menuState=UPSetupMenuState(state,listen,post,self.failure!=nil);
    NSString *description=menuState==UPMenuPen?@"BostoTablet: pen in range or palm cooldown":menuState==UPMenuTouch?@"BostoTablet: touch gestures ready":@"BostoTablet: unavailable — check setup";
    NSImage *icon=UPMenuIcon(menuState);
    BOOL mutedMenu=controlling && menuState==UPMenuUnavailable && (!self.touch.touchInputEnabled || !self.touch.penInputEnabled);
    if(mutedMenu){
        // An intentionally muted input is not a setup fault.
        icon=self.touch.penInputEnabled && !waitingForPen?UPMenuIcon(UPMenuPen):([NSImage imageWithSystemSymbolName:@"pause.circle" accessibilityDescription:nil]?:icon);
    }
    if(waitingForPen || mutedMenu)
        description=[NSString stringWithFormat:@"BostoTablet: touch — %@; pen — %@",setup[@"touch"],setup[@"pen"]];
    self.item.button.image=icon;
    self.item.button.toolTip=description;[self.item.button setAccessibilityLabel:description];
    NSNumber *battery=controlling?UPBatteryPercent(state[@"penObserver"][@"batteryPercent"]):nil;
    self.batteryLabel.stringValue=self.batteryMenu.title=UPBatteryDescription(battery);
    [self.batteryNotifications refresh];
    NSArray *keys=@[@"pen",@"touch",@"listen",@"post"];
    NSDictionary *colors=@{@"off":NSColor.secondaryLabelColor,@"waiting":NSColor.systemOrangeColor,@"active":NSColor.systemGreenColor};
    for(NSUInteger i=0;i<keys.count;i++){
        self.setupLabels[i].stringValue=setup[keys[i]];
        NSString *tone=i<2?setup[[keys[i] stringByAppendingString:@"Tone"]]:((i==2?listen:post)?@"active":@"waiting");
        self.setupDots[i].textColor=colors[tone];
    }
    NSString *guidance;
    if(!listen || !post)guidance=[NSString stringWithFormat:@"Request %@, then allow BostoTablet in Settings. If already on, quit and relaunch. Start the driver once both are granted.",!listen?@"Input Monitoring":@"Accessibility"];
    else if(self.changingInputs)guidance=@"Releasing previous inputs before applying your choices…";
    else if(running && !controlling)guidance=@"Driver unavailable. Saved choices are not confirmed.";
    else if(controlling && (!self.touch.touchInputEnabled || !self.touch.penInputEnabled))guidance=@"Driver running. See each input’s current state below.";
    else guidance=running?self.touch.status:@"Driver inactive. Start the driver to apply your saved input choices.";
    self.status.stringValue=self.failure?:guidance;
    NSDictionary *pen=state[@"penObserver"];
    NSString *phase=pen[@"pressureState"]?:@"inactive";
    NSDictionary *names=@{@"inactive":@"Inactive — start the driver to test",@"noData":@"No data — waiting for an accepted pen packet",@"outOfRange":@"Pen out of range",@"tipUp":@"Tip up",@"tipDown":@"Tip down"};
    self.rawMeter.doubleValue=[pen[@"rawPressure"] doubleValue]/8192.0;
    self.effectiveMeter.doubleValue=[pen[@"effectivePressure"] doubleValue];
    self.tester.stringValue=[NSString stringWithFormat:@"%@\nRaw %.0f / 8192 · Effective %.1f%%",waitingForPen?setup[@"pen"]:(names[phase]?:phase),[pen[@"rawPressure"] doubleValue],100*[pen[@"effectivePressure"] doubleValue]];
    NSDictionary *d=@{@"app":@"local.BostoTablet",@"state":state,@"listenAccess":@(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)),@"postEventAccess":@(CGPreflightPostEventAccess()),@"legacy782C":@"Unsupported: different 19MB protocol; no legacy binary or guessed profile.",@"penWrites":@0};
    NSData *data=[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];self.diagnostics.string=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]?:@"Diagnostics unavailable";
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {
    self.inputTerminating=YES;[self.inputTimer invalidate];[self.touch stop];
    // Let queued HID cleanup finish before AppKit exits its owner run loop.
    dispatch_async(dispatch_get_main_queue(),^{[app replyToApplicationShouldTerminate:YES];});
    return NSTerminateLater;
}
- (void)applicationWillTerminate:(NSNotification *)note {(void)note;[self.touch stop];[self.timer invalidate];[self.inputTimer invalidate];[NSNotificationCenter.defaultCenter removeObserver:self];[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];[NSStatusBar.systemStatusBar removeStatusItem:self.item];}
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
