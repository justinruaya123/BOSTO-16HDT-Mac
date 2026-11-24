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

@interface TestDelay : NSObject
@property(nonatomic, copy) NSString *stringValue;
@end
@implementation TestDelay
@end

@interface TestTouchSession : NSObject
@property(nonatomic) BOOL running;
@property(nonatomic) NSUInteger attempts;
@property(nonatomic) CGDirectDisplayID startedDisplay;
@property(nonatomic) BOOL flipTouchY;
@end
@implementation TestTouchSession
- (BOOL)updateResumeDelay:(double)seconds { assert(seconds==2); return YES; }
- (BOOL)startWithDisplay:(CGDirectDisplayID)display postEvents:(BOOL)postEvents error:(NSError **)error {
    (void)error; assert(postEvents); self.attempts++;
    if(!tabletIdentity)return NO;
    self.startedDisplay=display;self.running=YES;return YES;
}
- (void)stop { self.running=NO; }
@end

@interface TestApp : UPApp
@end
@implementation TestApp
- (void)refresh:(NSTimer *)timer { (void)timer; }
- (void)openPermissionSettings:(NSString *)pane { (void)pane; assert(0 && "Automatic launch opened System Settings"); }
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

@interface UPApp (GesturePreferencesTest)
- (void)restoreGestureActions;
@end

static void checkGesturePreferences(void) {
    [NSApplication sharedApplication];
    TestPreferences *preferences=[TestPreferences new];preferences.values=[NSMutableDictionary dictionary];
    for(int launch=0;launch<2;launch++) {
        TestApp *app=[TestApp new];app.preferences=(NSUserDefaults *)(id)preferences;
        app.touch=[BTTouchController new];app.exponent=1;
        if([app respondsToSelector:@selector(restoreGestureActions)])[app restoreGestureActions];
        NSView *root=[[NSView alloc]initWithFrame:NSMakeRect(0,0,700,550)];
        [app composeControlsInView:root resumeDelay:2];
        NSTabView *tabs=(NSTabView *)root.subviews.firstObject;
        NSInteger index=[tabs indexOfTabViewItemWithIdentifier:@"gestures"];
        assert(index!=NSNotFound && "Gesture actions must have a settings tab");
        NSView *view=[tabs tabViewItemAtIndex:index].view;
        NSMutableArray<NSPopUpButton *> *pickers=[NSMutableArray array];
        for(NSView *child in view.subviews)if([child isKindOfClass:NSPopUpButton.class])[pickers addObject:(NSPopUpButton *)child];
        assert(pickers.count==2);
        assert([pickers[0].titleOfSelectedItem isEqual:@"Default"]);
        assert([pickers[1].titleOfSelectedItem isEqual:(launch?@"Off":@"Default")]);
        if(!launch){
            [pickers[1] selectItemWithTitle:@"Off"];
            assert([pickers[1] sendAction:pickers[1].action to:pickers[1].target]);
            assert([app.touch.gestureActions[@"pinch"] isEqual:@"off"] && !app.touch.gestureActions[@"swipe"]);
        }
    }
    puts("Gestures tab keeps native defaults and restores a changed action on the next launch.");
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
    [app restoreTouchOrientation];
    [app preselectLaunchDisplay];
    return app;
}
static TestApp *launch(NSArray<NSDictionary *> *displays) { return launchWithSettings(displays,@{}); }

int main(void) { @autoreleasepool {
    checkGesturePreferences();
    NSDictionary *bosto=@{@"id":@42,@"uuid":@"tablet",@"name":@"Bosto Tablet",@"mirrored":@NO};
    NSDictionary *retina=@{@"id":@1,@"uuid":@"internal",@"name":@"Built-in Retina Display",@"mirrored":@NO};
    listenGranted=postGranted=YES;
    tabletIdentity=nil;
    TestApp *lateUSB=launch(@[bosto]);
    TestTouchSession *lateSession=(TestTouchSession *)(id)lateUSB.touch;
    assert(lateSession.attempts==0 && !lateSession.running && "Launch must wait for the exact tablet USB interfaces");
    tabletIdentity=@[@101,@201];
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
    assert(session.running && session.attempts==1 && session.startedDisplay==42);
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
    TestApp *orientation=launchWithSettings(@[bosto],@{@"flipTouchY":@YES});
    assert(orientation.touch.flipTouchY && !app.touch.flipTouchY);
    TestDisplayPicker *orientationPicker=[TestDisplayPicker new];orientationPicker.indexOfSelectedItem=1;
    [app changeTouchOrientation:(NSPopUpButton *)(id)orientationPicker];
    assert(app.touch.flipTouchY && [[app.preferences objectForKey:@"flipTouchY"] isEqual:@YES]);
    orientationPicker.indexOfSelectedItem=0;[app changeTouchOrientation:(NSPopUpButton *)(id)orientationPicker];
    assert(!app.touch.flipTouchY && [[app.preferences objectForKey:@"flipTouchY"] isEqual:@NO]);
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
