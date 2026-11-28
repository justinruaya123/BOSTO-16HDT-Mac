// Production launch routing, with no windows, HID opens or permission prompts.
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import "BTTouchController.h"
#include <assert.h>

static BOOL listenGranted, postGranted;
static NSArray<NSNumber *> *tabletIdentity;
static NSArray<NSDictionary *> *connectedDisplays;
static IOHIDAccessType fakeListen(IOHIDRequestType type) {
    assert(type==kIOHIDRequestTypeListenEvent);
    return listenGranted?kIOHIDAccessTypeGranted:kIOHIDAccessTypeDenied;
}
static BOOL fakePost(void) { return postGranted; }
static bool unexpectedListenRequest(IOHIDRequestType type) { (void)type; assert(0 && "Automatic launch requested Input Monitoring"); return false; }
static Boolean unexpectedAXRequest(CFDictionaryRef options) { (void)options; assert(0 && "Automatic launch requested Accessibility"); return false; }
static NSArray<NSDictionary *> *fakeDisplays(void) { return connectedDisplays; }

#define IOHIDCheckAccess fakeListen
#define CGPreflightPostEventAccess fakePost
#define IOHIDRequestAccess unexpectedListenRequest
#define AXIsProcessTrustedWithOptions unexpectedAXRequest
#define BTAvailableDisplays fakeDisplays
#define BTTabletRegistryIdentity fakeTabletIdentity
static NSArray<NSNumber *> *fakeTabletIdentity(void) __attribute__((unused));
static NSArray<NSNumber *> *fakeTabletIdentity(void) { return tabletIdentity; }
#define main realAppMain
#import "../main.m"
#undef main
@interface UPApp (ReconciliationTest)
- (void)reconcileInput;
@end

@interface TestItem : NSObject
@property(nonatomic, strong) NSDictionary *representedObject;
@end
@implementation TestItem
@end

@interface TestDisplayPicker : NSObject
@property(nonatomic, copy) NSArray<TestItem *> *itemArray;
@property(nonatomic) NSInteger indexOfSelectedItem;
@property(nonatomic, strong) TestItem *selectedItem;
@end
@implementation TestDisplayPicker
- (void)selectItem:(TestItem *)item { self.selectedItem=item; }
- (void)selectItemAtIndex:(NSInteger)index { self.selectedItem=self.itemArray.count>(NSUInteger)index?self.itemArray[index]:nil; }
- (void)removeAllItems { self.itemArray=@[];self.selectedItem=nil; }
- (void)addItemWithTitle:(NSString *)title { (void)title;self.itemArray=[self.itemArray arrayByAddingObject:[TestItem new]]; }
- (instancetype)menu { return self; }
- (void)addItem:(NSMenuItem *)item {
    TestItem *entry=[TestItem new];entry.representedObject=item.representedObject;
    self.itemArray=[self.itemArray arrayByAddingObject:entry];
}
@end

// Stand-in for the menu-bar item; no system status item is created.
@interface TestStatusItem : NSObject
@property(nonatomic,strong) NSButton *button;
@end
@implementation TestStatusItem
@end

@interface TestDelay : NSObject
@property(nonatomic, copy) NSString *stringValue;
@end
@implementation TestDelay
@end

@interface TestTouchSession : NSObject
@property(nonatomic) BOOL running;
@property(nonatomic) NSUInteger attempts;
@property(nonatomic) CGDirectDisplayID startedDisplay;
@property(nonatomic) BOOL nativeTouchEnabled,flipTouchY,touchInputEnabled,penInputEnabled,cleaning;
@property(nonatomic,copy) NSDictionary *gestureActions;
@end
@implementation TestTouchSession
- (BOOL)updateResumeDelay:(double)seconds { assert(seconds==2); return YES; }
- (BOOL)startWithDisplay:(CGDirectDisplayID)display postEvents:(BOOL)postEvents error:(NSError **)error {
    (void)error; assert(postEvents); assert(!self.cleaning && "Started before HID cleanup"); self.attempts++;
    if(!tabletIdentity)return NO;
    self.startedDisplay=display;self.running=YES;return YES;
}
- (void)stop { self.running=NO; } // Most launch tests do not interleave events with cleanup.
@end
@interface DeferredTouchSession : TestTouchSession
@property(nonatomic) BOOL waitingForPen;
@end
@implementation DeferredTouchSession
- (void)stop {
    if(!self.running)return;
    [super stop];self.cleaning=YES;
    dispatch_async(dispatch_get_main_queue(),^{self.cleaning=NO;});
}
- (NSDictionary *)snapshot {
    BOOL attached=self.running && !self.waitingForPen;
    return @{@"running":@(self.running),@"penObserver":@{@"running":@(self.running),@"seized":@(attached),
             @"waitingForDevice":@(self.running && self.waitingForPen),@"pressureState":!self.running?@"inactive":self.penInputEnabled?@"noData":@"muted"}};
}
- (NSString *)status { return @"Waiting for reports"; }
- (void)setTouchInputEnabled:(BOOL)value { assert(!self.cleaning && !self.running);[super setTouchInputEnabled:value]; }
- (void)setPenInputEnabled:(BOOL)value { assert(!self.cleaning && !self.running);[super setPenInputEnabled:value]; }
- (void)setNativeTouchEnabled:(BOOL)value { assert(!self.cleaning && !self.running);[super setNativeTouchEnabled:value]; }
- (void)setGestureActions:(NSDictionary *)value { assert(!self.cleaning);[super setGestureActions:value]; }
@end

@interface TestApp : UPApp
@end
@implementation TestApp
- (void)refresh:(NSTimer *)timer { (void)timer; }
- (void)openPermissionSettings:(NSString *)pane { (void)pane; assert(0 && "Automatic launch opened System Settings"); }
@end

// Exercise Home's real refresh without looking up the machine's login service.
@interface HomeApp : UPApp
@end
@implementation HomeApp
- (void)refreshLoginStatus {}
- (void)openPermissionSettings:(NSString *)pane { (void)pane; assert(0 && "Switches opened Settings"); }
@end

@interface TestPreferences : NSObject
@property(nonatomic, strong) NSMutableDictionary *values;
@end
@implementation TestPreferences
- (id)objectForKey:(NSString *)key { return self.values[key]; }
- (void)setBool:(BOOL)value forKey:(NSString *)key { self.values[key]=@(value); }
- (void)setObject:(id)value forKey:(NSString *)key { self.values[key]=value; }
- (void)removeObjectForKey:(NSString *)key { [self.values removeObjectForKey:key]; }
@end

static void drainMainQueue(void);
static NSPopUpButton *pickerNamed(NSView *pane,NSString *name) {
    for(NSView *child in pane.subviews)if([child isKindOfClass:NSPopUpButton.class] &&
        [[(NSPopUpButton *)child accessibilityLabel] isEqual:name])return (NSPopUpButton *)child;
    return nil;
}
static void choose(NSPopUpButton *picker,NSString *title) {
    assert(picker.enabled && [picker itemWithTitle:title]);
    [picker selectItemWithTitle:title];assert([picker sendAction:picker.action to:picker.target]);
}
static void checkGesturePreferences(NSDictionary *bosto) {
    [NSApplication sharedApplication];
    connectedDisplays=@[bosto];tabletIdentity=@[@101,@201];listenGranted=postGranted=YES;
    NSDictionary *binding=@{@"key":@6,@"modifiers":@(kCGEventFlagMaskCommand),@"name":@"Z"};
    NSDictionary *legacy=@{@"gestureActions":@{@"swipe":binding,@"pinch":@"off"},@"flipTouchY":@YES,@"penInputEnabled":@NO};
    TestPreferences *prefs=[TestPreferences new];prefs.values=[legacy mutableCopy];
    for(int launch=0;launch<2;launch++) {
        HomeApp *app=[HomeApp new];app.preferences=(NSUserDefaults *)(id)prefs;app.exponent=1;
        DeferredTouchSession *session=[DeferredTouchSession new];app.touch=(BTTouchController *)(id)session;
        NSView *root=[[NSView alloc]initWithFrame:NSMakeRect(0,0,700,550)];
        [app composeControlsInView:root resumeDelay:2];[app reloadDisplays:nil];[app preselectLaunchDisplay];
        NSTabView *tabs=(NSTabView *)root.subviews.firstObject;
        NSView *pane=[tabs tabViewItemAtIndex:[tabs indexOfTabViewItemWithIdentifier:@"gestures"]].view;
        NSPopUpButton *mode=pickerNamed(pane,@"Touch mode"),*swipe=pickerNamed(pane,@"Two-finger swipe: scroll / pan"),*pinch=pickerNamed(pane,@"Pinch: zoom");
        assert(mode && "Gestures must offer an accessible native/compatibility mode control");
        assert(swipe && pinch && [swipe.titleOfSelectedItem isEqual:@"Keyboard Shortcut"]);
        assert(session.running && session.touchInputEnabled && !session.penInputEnabled);
        if(!launch){
            assert([mode.titleOfSelectedItem isEqual:@"Native multitouch"] && session.nativeTouchEnabled);
            assert(!swipe.enabled && !pinch.enabled && !app.gestureEditors[0].enabled && app.touchOrientation.enabled);
            assert([app.touchOrientation.titleOfSelectedItem isEqual:@"Inverted"]);
            assert(!session.gestureActions.count && !session.flipTouchY && [prefs.values isEqual:legacy]);
            assert(![app.gestureStatus.stringValue containsString:@"scroll events"]);
            choose(mode,@"Compatibility");assert(session.cleaning && !session.running);
            drainMainQueue();[app reconcileInput];
        }
        assert([mode.titleOfSelectedItem isEqual:@"Compatibility"] && !session.nativeTouchEnabled);
        assert(session.running && !session.penInputEnabled && session.touchInputEnabled && !session.flipTouchY);
        assert([session.gestureActions[@"swipe"] isEqual:binding] && [session.gestureActions[@"pinch"] isEqual:@"off"]);
        assert(swipe.enabled && pinch.enabled && app.gestureEditors[0].enabled && !app.gestureEditors[1].enabled && app.touchOrientation.enabled);
        assert([app.gestureStatus.stringValue containsString:@"Synthetic"]);
        if(launch){
            choose(pinch,@"Default");assert(![prefs objectForKey:@"gestureActions"][@"pinch"]);
            choose(mode,@"Native multitouch");drainMainQueue();[app reconcileInput];
            assert(session.running && session.nativeTouchEnabled && !session.gestureActions.count && !session.flipTouchY);
            assert([[prefs objectForKey:@"gestureActions"][@"swipe"] isEqual:binding] && [[prefs objectForKey:@"flipTouchY"] isEqual:@YES]);
            choose(mode,@"Compatibility");[app disable:nil];drainMainQueue();[app reconcileInput];
            assert(!session.running); // Master Stop cancels a pending mode restart.
        }
        [session stop];drainMainQueue();
    }
    puts("Native upgrade leaves legacy choices dormant; Compatibility restores them across restart and relaunch (offline).");
}

static TestApp *launchWithSettings(NSArray<NSDictionary *> *displays, NSDictionary *saved) {
    connectedDisplays=displays;
    NSMutableArray<TestItem *> *items=[NSMutableArray array];
    [items addObject:[TestItem new]];
    for(NSDictionary *display in displays){TestItem *item=[TestItem new];item.representedObject=display;[items addObject:item];}
    TestDisplayPicker *picker=[TestDisplayPicker new];picker.itemArray=items;
    TestDelay *delay=[TestDelay new];delay.stringValue=@"2";
    TestApp *app=[TestApp new];app.displays=(NSPopUpButton *)(id)picker;app.delay=(NSTextField *)(id)delay;
    app.touch=(BTTouchController *)(id)[TestTouchSession new];app.exponent=1;
    TestPreferences *preferences=[TestPreferences new];preferences.values=[saved mutableCopy];
    app.preferences=(NSUserDefaults *)(id)preferences;
    [app preselectLaunchDisplay];
    return app;
}
static TestApp *launch(NSArray<NSDictionary *> *displays) { return launchWithSettings(displays,@{}); }

static NSButton *homeButton(NSView *view,NSString *title) {
    if([view isKindOfClass:NSButton.class] && [[(NSButton *)view title] isEqual:title])return (NSButton *)view;
    for(NSView *child in view.subviews){NSButton *button=homeButton(child,title);if(button)return button;}
    return nil;
}
static void setSwitch(NSButton *button,BOOL on) {
    button.state=on?NSControlStateValueOn:NSControlStateValueOff;
    assert([button sendAction:button.action to:button.target]);
}
static void drainMainQueue(void) {
    __block BOOL done=NO;dispatch_async(dispatch_get_main_queue(),^{done=YES;});
    while(!done)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
}
static void checkInputSwitches(NSDictionary *bosto) {
    connectedDisplays=@[bosto];tabletIdentity=@[@101,@201];listenGranted=postGranted=YES;
    TestPreferences *prefs=[TestPreferences new];prefs.values=[NSMutableDictionary dictionary];
    for(int launch=0;launch<2;launch++){
        HomeApp *app=[HomeApp new];app.preferences=(NSUserDefaults *)(id)prefs;app.exponent=1;
        DeferredTouchSession *session=[DeferredTouchSession new];app.touch=(BTTouchController *)(id)session;
        NSView *root=[[NSView alloc]initWithFrame:NSMakeRect(0,0,700,550)];
        [app composeControlsInView:root resumeDelay:2];[app reloadDisplays:nil];[app preselectLaunchDisplay];
        NSTabView *tabs=(NSTabView *)root.subviews.firstObject;
        NSView *home=[tabs tabViewItemAtIndex:[tabs indexOfTabViewItemWithIdentifier:@"home"]].view;
        NSButton *touch=homeButton(home,@"Touch input"),*pen=homeButton(home,@"Pen input");
        assert(touch && pen && "Home must offer independent display touch and pen switches");
        assert(touch.state==(launch?NSControlStateValueOff:NSControlStateValueOn) && pen.state==NSControlStateValueOn);
        assert(session.running && session.touchInputEnabled==!launch && session.penInputEnabled);
        assert([app.enable.title isEqual:@"Stop driver (release tablet)"]);
        if(!launch){
            setSwitch(touch,NO);[app reconcileInput];
            assert(!session.running && session.cleaning && session.attempts==1);
            assert(![app.setupLabels[1].stringValue containsString:@"Muted"]);
            drainMainQueue();[app reconcileInput];
            assert([app.setupLabels[1].stringValue isEqual:@"Muted by driver"]);
            assert(session.running && !session.touchInputEnabled && session.penInputEnabled && session.attempts==2);
            [app.touch stop];drainMainQueue();continue;
        }
        setSwitch(pen,NO);setSwitch(touch,YES);setSwitch(touch,NO); // Latest pair wins during cleanup.
        drainMainQueue();[app reconcileInput];
        assert(session.running && !session.touchInputEnabled && !session.penInputEnabled && session.attempts==2);
        assert([app.setupLabels[0].stringValue isEqual:@"Muted by driver"] && [app.setupLabels[1].stringValue isEqual:@"Muted by driver"]);
        TestStatusItem *item=[TestStatusItem new];item.button=[NSButton new];app.item=(id)item;
        session.waitingForPen=YES;[app refresh:nil];
        assert([app.setupLabels[0].stringValue isEqual:@"Waiting for pen device"] && [app.setupLabels[1].stringValue isEqual:@"Muted by driver"]);
        assert([item.button.toolTip localizedCaseInsensitiveContainsString:@"waiting for pen device"]);
        assert([app.tester.stringValue containsString:@"Waiting for pen device"]);
        session.waitingForPen=NO;[app reconcileInput];[app refresh:nil];
        assert(session.running && session.attempts==2 && [app.setupLabels[0].stringValue isEqual:@"Muted by driver"]);
        postGranted=NO;[app refresh:nil];
        assert(![app.setupLabels[0].stringValue containsString:@"Muted"]);
        postGranted=YES;app.failure=@"Session fault";[app refresh:nil];
        assert(![app.setupLabels[0].stringValue containsString:@"Muted"]);app.failure=nil;
        setSwitch(pen,YES);tabletIdentity=nil;drainMainQueue();[app reconcileInput];
        assert(!session.running && session.attempts==2); // USB detached before cleanup returned.
        tabletIdentity=@[@102,@202];[app reconcileInput];assert(session.running && session.attempts==3);
        setSwitch(touch,YES);connectedDisplays=@[];drainMainQueue();[app reconcileInput];
        assert(!session.running && session.attempts==3); // USB still attached, screen notification not yet delivered.
        connectedDisplays=@[bosto];[app reconcileInput];assert(session.running && session.attempts==4);
        setSwitch(touch,NO);[app toggle:nil]; // Master Stop during a switch must cancel the pending restart.
        drainMainQueue();[app reconcileInput];assert(!session.running && session.attempts==4);
        assert([app.enable.title isEqual:@"Start driver"]);
        setSwitch(pen,NO);drainMainQueue();[app reconcileInput];assert(!session.running && session.attempts==4);
        [app toggle:nil];assert(session.running && !session.touchInputEnabled && !session.penInputEnabled);
        [session stop]; // A controller fault queued cleanup; same identity must not loop on the same choice.
        [app reconcileInput];assert(session.attempts==5);
        setSwitch(touch,YES);[app reconcileInput];assert(session.cleaning && session.attempts==5);
        drainMainQueue();[app reconcileInput];
        assert(session.running && session.touchInputEnabled && !session.penInputEnabled && session.attempts==6);
        [app disable:nil];drainMainQueue();
    }
    puts("Home switches persist independently; restart waits for cleanup, a connected tablet and driver consent (offline).");
}

int main(void) { @autoreleasepool {
    NSDictionary *bosto=@{@"id":@42,@"uuid":@"tablet",@"name":@"Bosto Tablet",@"mirrored":@NO};
    checkGesturePreferences(bosto);
    checkInputSwitches(bosto);
    NSDictionary *retina=@{@"id":@1,@"uuid":@"internal",@"name":@"Built-in Retina Display",@"mirrored":@NO};
    listenGranted=postGranted=YES;
    tabletIdentity=nil;
    TestApp *lateUSB=launch(@[bosto]);
    TestTouchSession *lateSession=(TestTouchSession *)(id)lateUSB.touch;
    assert(lateSession.attempts==0 && !lateSession.running && "Launch must wait for the exact tablet USB interfaces");
    tabletIdentity=@[];[lateUSB reconcileInput];assert(!lateSession.running && lateSession.attempts==0);
    tabletIdentity=@[@101]; // The registry found the eligible touch device before the pen.
    [lateUSB reconcileInput];assert(lateSession.running && lateSession.attempts==1);
    [lateSession stop];[lateUSB reconcileInput];assert(lateSession.attempts==1); // unchanged fault
    tabletIdentity=nil;[lateUSB reconcileInput];assert(lateSession.attempts==1);
    tabletIdentity=@[@102,@202];
    [lateUSB reconcileInput];assert(lateSession.running && lateSession.attempts==2);
    [lateUSB reloadDisplays:[NSNotification notificationWithName:NSApplicationDidChangeScreenParametersNotification object:nil]];
    [lateUSB reconcileInput];assert(lateSession.running && lateSession.attempts==2); // unrelated display event
    [lateUSB inputSleepChanged:[NSNotification notificationWithName:NSWorkspaceWillSleepNotification object:nil]];
    [lateSession stop]; // The real controller closes its HID connections on sleep.
    [lateUSB reconcileInput];assert(lateSession.attempts==2);
    [lateUSB inputSleepChanged:[NSNotification notificationWithName:NSWorkspaceDidWakeNotification object:nil]];
    [lateUSB reconcileInput];assert(lateSession.running && lateSession.attempts==3);
    [lateUSB disable:nil];tabletIdentity=@[@103,@203];
    [lateUSB reconcileInput];assert(!lateSession.running && lateSession.attempts==3);
    assert(!launchWithSettings(@[bosto],@{@"inputDisabled":@YES}).touch.running);
    TestApp *app=launch(@[retina,bosto]);
    TestTouchSession *session=(TestTouchSession *)(id)app.touch;
    assert(session.running && session.attempts==1 && session.startedDisplay==42 && session.nativeTouchEnabled);
    assert(((TestTouchSession *)(id)launchWithSettings(@[bosto],@{@"touchMode":@NO}).touch).nativeTouchEnabled);
    [app disable:nil];assert(!session.running && session.attempts==1);
    TestApp *detected=launchWithSettings(@[retina,bosto],@{@"selectedDisplayUUID":@"internal"});
    assert(((TestTouchSession *)(id)detected.touch).startedDisplay==42);
    TestApp *manual=launchWithSettings(@[retina,bosto],@{@"selectedDisplayUUID":@"internal",@"autoDetectTablet":@NO});
    assert(((TestTouchSession *)(id)manual.touch).startedDisplay==1);
    assert(!launchWithSettings(@[bosto],@{@"autoDetectTablet":@NO}).touch.running);
    assert(!launchWithSettings(@[retina],@{@"selectedDisplayUUID":@"internal"}).touch.running);
    [manual disable:nil];
    connectedDisplays=@[retina,bosto];
    [manual reloadDisplays:[NSNotification notificationWithName:NSApplicationDidChangeScreenParametersNotification object:nil]];
    assert([manual.displays.selectedItem.representedObject isEqual:retina] && !manual.touch.running);
    [detected disable:nil];
    [detected reloadDisplays:[NSNotification notificationWithName:NSApplicationDidChangeScreenParametersNotification object:nil]];
    assert([detected.displays.selectedItem.representedObject isEqual:bosto] && !detected.touch.running);
    TestApp *orientation=launchWithSettings(@[bosto],@{@"touchMode":@"compatibility",@"flipTouchY":@YES});
    assert(!orientation.touch.flipTouchY && app.touch.flipTouchY);
    assert(launchWithSettings(@[bosto],@{@"touchMode":@"compatibility"}).touch.flipTouchY);
    TestDisplayPicker *orientationPicker=[TestDisplayPicker new];orientationPicker.indexOfSelectedItem=1;
    TestApp *nativeOrientation=launch(@[bosto]);assert(nativeOrientation.touch.running && nativeOrientation.touch.flipTouchY);
    [nativeOrientation changeTouchOrientation:(NSPopUpButton *)(id)orientationPicker];assert(!nativeOrientation.touch.flipTouchY);
    [orientation changeTouchOrientation:(NSPopUpButton *)(id)orientationPicker];
    assert(!orientation.touch.flipTouchY && [[orientation.preferences objectForKey:@"flipTouchY"] isEqual:@YES]);
    orientationPicker.indexOfSelectedItem=0;[orientation changeTouchOrientation:(NSPopUpButton *)(id)orientationPicker];
    assert(orientation.touch.flipTouchY && [[orientation.preferences objectForKey:@"flipTouchY"] isEqual:@NO]);
    TestApp *hotplug=launch(@[retina]);
    connectedDisplays=@[retina,bosto];
    [hotplug reloadDisplays:[NSNotification notificationWithName:NSApplicationDidChangeScreenParametersNotification object:nil]];
    [hotplug reconcileInput];
    assert([hotplug.displays.selectedItem.representedObject isEqual:bosto] && hotplug.touch.running);
    // Use the actual AppKit picker: insertion by title deduplicates items.
    [NSApplication sharedApplication];
    hotplug.displays=[[NSPopUpButton alloc]initWithFrame:NSZeroRect pullsDown:NO];
    NSDictionary *mirroredBosto=@{@"id":@43,@"uuid":@"mirrored",@"name":@"Bosto Tablet",@"mirrored":@YES};
    connectedDisplays=@[bosto,mirroredBosto];
    [hotplug reloadDisplays:nil];
    assert(hotplug.displays.numberOfItems==3 && [hotplug.displays.selectedItem.representedObject isEqual:bosto]);
    assert(!launch(@[retina]).touch.running);
    assert(!launch(@[bosto,bosto]).touch.running);
    listenGranted=NO;assert(!launch(@[bosto]).touch.running);
    listenGranted=YES;postGranted=NO;assert(!launch(@[bosto]).touch.running);
    puts("Launch, late USB arrival, reconnect and wake start only once with a safe display, existing grants and no manual Disable (offline).");
}return 0;}
