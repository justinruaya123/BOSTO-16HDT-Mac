#import "SetupState.h"
#include <assert.h>
int main(void) { @autoreleasepool {
    NSDictionary *bosto=@{@"id":@2,@"uuid":@"tablet",@"name":@"Bosto Tablet",@"mirrored":@NO};
    NSDictionary *internal=@{@"id":@1,@"uuid":@"internal",@"name":@"Built-in Retina Display",@"mirrored":@NO};
    NSDictionary *other=@{@"id":@3,@"uuid":@"other",@"name":@"External Display",@"mirrored":@NO};
    NSDictionary *unnamed=@{@"id":@5,@"uuid":@"unnamed",@"mirrored":@NO};
    NSMutableDictionary *mirror=[bosto mutableCopy];mirror[@"mirrored"]=@YES;
    NSMutableDictionary *second=[bosto mutableCopy];second[@"uuid"]=@"second";second[@"id"]=@4;
    NSString *reason=nil;
    assert([UPLaunchDisplay(@[internal,bosto],nil,&reason) isEqual:bosto] && !reason);
    assert([UPLaunchDisplay(@[other,bosto],@"other",&reason) isEqual:other]);
    assert(!UPLaunchDisplay(@[internal],nil,&reason) && reason.length);
    assert(!UPLaunchDisplay(@[unnamed],nil,&reason)); // A nil name must never compare as a Bosto match.
    assert(!UPLaunchDisplay(@[other],nil,&reason)); // Never infer the only screen.
    assert(!UPLaunchDisplay(@[bosto,second],nil,&reason));
    assert(!UPLaunchDisplay(@[mirror],nil,&reason));
    assert(!UPLaunchDisplay(@[bosto],@"missing",&reason)); // No named-display fallback.
    assert(!UPLaunchDisplay(@[bosto,bosto],@"tablet",&reason));
    assert(!UPLaunchDisplay(@[mirror,bosto],@"tablet",&reason));
    assert(!UPLaunchDisplay(@[mirror,other],@"tablet",&reason));
    // Missing grants precede display validation, with Input Monitoring first.
    assert(UPSetupAction(NO,NO,NO)==UPRequestInputMonitoring);
    assert(UPSetupAction(NO,YES,NO)==UPRequestAccessibility);
    assert(UPSetupAction(NO,YES,YES)==UPValidateDisplay);
    assert(UPSetupAction(YES,NO,NO)==UPDisable);
    // Request before recheck, then only the selected pane if still denied.
    NSMutableString *trace=[NSMutableString string];
    BOOL granted=UPRequestSetupPermission(^BOOL{[trace appendString:@"check;"];return NO;},^{[trace appendString:@"request;"];},^{[trace appendString:@"pane;"];});
    assert(!granted && [trace isEqual:@"check;request;check;pane;"]);
    [trace setString:@""];
    granted=UPRequestSetupPermission(^BOOL{[trace appendString:@"check;"];return YES;},^{[trace appendString:@"request;"];},^{[trace appendString:@"pane;"];});
    assert(granted && [trace isEqual:@"check;"]);
    // An open, ignored/raw reports, and retained old counters cannot imply Active.
    NSMutableDictionary *state=[@{@"running":@NO,@"validFrames":@12,@"penObserver":@{@"running":@NO,@"reports":@8,@"pressureState":@"inactive"}} mutableCopy];
    NSDictionary *s=UPSetupStatus(state,NO,YES,NO);
    assert([s[@"pen"] isEqual:@"Driver inactive"] && [s[@"touch"] isEqual:@"Driver inactive"]);
    assert([s[@"listen"] isEqual:@"Not granted"] && [s[@"post"] isEqual:@"Granted"]);
    state[@"running"]=@YES;state[@"validFrames"]=@0;state[@"rawReports"]=@20;
    state[@"penObserver"]=@{@"running":@YES,@"reports":@0,@"seized":@YES,@"pressureState":@"noData",@"presence":@"unknown"};
    s=UPSetupStatus(state,YES,YES,NO);
    assert([s[@"pen"] isEqual:@"Waiting for reports"] && [s[@"touch"] isEqual:@"Waiting for reports"]);
    state[@"penObserver"]=@{@"running":@YES,@"reports":@1,@"pressureState":@"tipUp",@"presence":@"inRange"};
    state[@"gestureReadiness"]=@(BTGestureReadinessPen);state[@"validFrames"]=@1;s=UPSetupStatus(state,YES,YES,NO);
    assert([s[@"pen"] isEqual:@"Active"] && [s[@"touch"] isEqual:@"Active — palm suppression"]);
    state[@"penObserver"]=@{@"running":@YES,@"reports":@0,@"pressureState":@"noData"};
    s=UPSetupStatus(state,YES,YES,NO);assert([s[@"pen"] isEqual:@"Waiting for reports"]);
    state[@"running"]=@NO;s=UPSetupStatus(state,YES,YES,NO);
    assert([s[@"pen"] isEqual:@"Driver inactive"] && [s[@"touch"] isEqual:@"Driver inactive"]);
    state[@"running"]=@YES;state[@"penObserver"]=@{@"running":@YES,@"presence":@"outOfRange"};
    state[@"gestureReadiness"]=@(BTGestureReadinessReady);
    assert(UPSetupMenuState(state,YES,YES,NO)==UPMenuTouch);
    state[@"penObserver"]=@{@"running":@YES,@"presence":@"outOfRange",@"reports":@1,@"pressureState":@"outOfRange"};
    s=UPSetupStatus(state,YES,YES,NO);
    assert([s[@"pen"] isEqual:@"Active"] && [s[@"touch"] isEqual:@"Active"]);
    // Readiness, not recent contact/report activity, determines the ready menu.
    state[@"validFrames"]=@0;state[@"activeContacts"]=@999;
    assert(UPSetupMenuState(state,YES,YES,NO)==UPMenuTouch);
    state[@"gestureReadiness"]=@(BTGestureReadinessPen);
    assert(UPSetupMenuState(state,YES,YES,NO)==UPMenuPen);
    state[@"gestureReadiness"]=@(BTGestureReadinessLiftRequired);
    assert(UPSetupMenuState(state,YES,YES,NO)==UPMenuUnavailable);
    state[@"gestureReadiness"]=@(BTGestureReadinessReady);
    assert(UPSetupMenuState(state,NO,YES,NO)==UPMenuUnavailable);
    assert(UPSetupMenuState(state,YES,NO,NO)==UPMenuUnavailable);
    assert(UPSetupMenuState(state,YES,YES,YES)==UPMenuUnavailable);
    state[@"penObserver"]=@{@"running":@YES,@"presence":@"unknown"};
    assert(UPSetupMenuState(state,YES,YES,NO)==UPMenuTouch); // The touch policy is already ready.
    state[@"gestureReadiness"]=@(BTGestureReadinessUnknown);
    assert(UPSetupMenuState(state,YES,YES,NO)==UPMenuUnavailable);
    state[@"running"]=@NO;assert(UPSetupMenuState(state,YES,YES,NO)==UPMenuUnavailable);
    // Accepted reports and palm telemetry are not evidence of output from a muted input.
    state[@"running"]=@YES;state[@"validFrames"]=@9;
    state[@"penObserver"]=@{@"running":@YES,@"reports":@8,@"pressureState":@"tipDown",@"seized":@YES};
    state[@"gestureReadiness"]=@(BTGestureReadinessReady);
    state[@"touchInputEnabled"]=@NO;state[@"penInputEnabled"]=@YES;
    s=UPSetupStatus(state,YES,YES,NO);
    assert([s[@"touch"] isEqual:@"Muted by driver"] && [s[@"pen"] isEqual:@"Active"]);
    assert(UPSetupMenuState(state,YES,YES,NO)!=UPMenuTouch);
    state[@"penInputEnabled"]=@NO;state[@"gestureReadiness"]=@(BTGestureReadinessPen);
    s=UPSetupStatus(state,YES,YES,NO);
    assert([s[@"pen"] isEqual:@"Muted by driver"] && [s[@"touch"] isEqual:@"Muted by driver"]);
    assert(UPSetupMenuState(state,YES,YES,NO)!=UPMenuPen);
    state[@"touchInputEnabled"]=@YES;state[@"gestureReadiness"]=@(BTGestureReadinessReady);
    assert([UPSetupStatus(state,YES,YES,NO)[@"touch"] isEqual:@"Active"]);
    for(NSDictionary *blocked in @[UPSetupStatus(state,NO,YES,NO),UPSetupStatus(state,YES,NO,NO)])
        assert(![blocked[@"pen"] isEqual:@"Muted by driver"] && ![blocked[@"touch"] isEqual:@"Active"]);
    state[@"running"]=@NO;
    assert(![UPSetupStatus(state,YES,YES,NO)[@"pen"] isEqual:@"Muted by driver"]);
    puts("Setup status and one-per-click permission routing checks passed (offline).");
}return 0;}
