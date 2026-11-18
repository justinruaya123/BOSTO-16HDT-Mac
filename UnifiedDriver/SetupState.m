#import "SetupState.h"
#import "BTGestures.h"

UPMenuState UPSetupMenuState(NSDictionary *snapshot, BOOL listenGranted, BOOL postGranted, BOOL fault) {
    if(fault || !listenGranted || !postGranted || ![snapshot[@"running"] boolValue] ||
       ![snapshot[@"penObserver"][@"running"] boolValue])return UPMenuUnavailable;
    NSString *presence=snapshot[@"penObserver"][@"presence"];
    if(![presence isEqual:@"inRange"] && ![presence isEqual:@"outOfRange"])return UPMenuUnavailable;
    switch([snapshot[@"gestureReadiness"] unsignedIntegerValue]) {
        case BTGestureReadinessPen:return UPMenuPen;
        case BTGestureReadinessReady:return UPMenuTouch;
        case BTGestureReadinessUnknown:case BTGestureReadinessLiftRequired:return UPMenuUnavailable;
    }
    return UPMenuUnavailable;
}
UPEnableAction UPSetupAction(BOOL running, BOOL listenGranted, BOOL postGranted) {
    if(running)return UPDisable;
    if(!listenGranted)return UPRequestInputMonitoring;
    if(!postGranted)return UPRequestAccessibility;
    return UPValidateDisplay;
}
BOOL UPRequestSetupPermission(BOOL (^preflight)(void), void (^request)(void), void (^openSettings)(void)) {
    if(preflight())return YES;
    request();
    BOOL granted=preflight();
    if(!granted)openSettings();
    return granted;
}
NSDictionary *UPSetupStatus(NSDictionary *snapshot, BOOL listenGranted, BOOL postGranted) {
    BOOL running=[snapshot[@"running"] boolValue];
    NSDictionary *pen=snapshot[@"penObserver"];
    BOOL penActive=running && [pen[@"running"] boolValue] && [pen[@"reports"] unsignedIntegerValue]>0 &&
        ![pen[@"pressureState"] isEqual:@"noData"] && ![pen[@"pressureState"] isEqual:@"inactive"];
    BOOL touchActive=running && [snapshot[@"validFrames"] unsignedIntegerValue]>0;
    NSString *penText=!running?@"Off":penActive?@"Active":@"Waiting for reports";
    NSString *touchText=!running?@"Off":touchActive?@"Active":@"Waiting for reports";
    NSUInteger readiness=[snapshot[@"gestureReadiness"] unsignedIntegerValue];
    BOOL suppressed=running && (readiness==BTGestureReadinessPen || readiness==BTGestureReadinessLiftRequired);
    if(touchActive && suppressed)touchText=@"Active — palm suppression";
    return @{@"pen":penText,@"touch":touchText,@"listen":listenGranted?@"Granted":@"Not granted",
             @"post":postGranted?@"Granted":@"Not granted",
             @"penTone":!running?@"off":penActive?@"active":@"waiting",
             @"touchTone":!running?@"off":touchActive?(suppressed?@"waiting":@"active"):@"waiting"};
}

NSDictionary *UPLaunchDisplay(NSArray<NSDictionary *> *displays, NSString *savedUUID, NSString **reason) {
    if(reason)*reason=nil;
    BOOL saved=savedUUID.length>0;
    NSMutableArray<NSDictionary *> *matches=[NSMutableArray array];
    for(NSDictionary *display in displays){
        id name=display[@"name"];
        BOOL match=saved?[display[@"uuid"] isEqual:savedUUID]:
            ([name isKindOfClass:NSString.class] && [name length]>0 &&
             [name caseInsensitiveCompare:@"Bosto Tablet"]==NSOrderedSame && ![display[@"mirrored"] boolValue]);
        if(match)[matches addObject:display];
    }
    if(matches.count==1 && ![matches[0][@"mirrored"] boolValue])return matches[0];
    if(reason)*reason=saved?@"Off: saved display missing, ambiguous or mirrored. Reconnect it or choose a display and Enable manually.":
        @"Off: no unique nonmirrored Bosto Tablet display. Connect it or choose a display and Enable manually.";
    return nil;
}
BOOL UPConsumeLaunchAttempt(BOOL *attempted) {
    if(*attempted)return NO;
    *attempted=YES;
    return YES;
}
