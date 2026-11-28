#import "SetupState.h"
#import "BTGestures.h"

BOOL UPSetupControlsInput(NSDictionary *snapshot, BOOL listenGranted, BOOL postGranted, BOOL fault) {
    return !fault && listenGranted && postGranted && [snapshot[@"running"] boolValue] && ([snapshot[@"penObserver"][@"running"] boolValue] || [snapshot[@"touchRunningWithoutPen"] boolValue]);
}
UPMenuState UPSetupMenuState(NSDictionary *snapshot, BOOL listenGranted, BOOL postGranted, BOOL fault) {
    if(!UPSetupControlsInput(snapshot,listenGranted,postGranted,fault))return UPMenuUnavailable;
    BOOL touchEnabled=![snapshot[@"touchInputEnabled"] isEqual:@NO];
    BOOL penEnabled=![snapshot[@"penInputEnabled"] isEqual:@NO];
    switch([snapshot[@"gestureReadiness"] unsignedIntegerValue]) {
        case BTGestureReadinessPen:return penEnabled?UPMenuPen:UPMenuUnavailable;
        case BTGestureReadinessReady:return touchEnabled?UPMenuTouch:UPMenuUnavailable;
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
NSDictionary *UPSetupStatus(NSDictionary *snapshot, BOOL listenGranted, BOOL postGranted, BOOL fault) {
    BOOL running=[snapshot[@"running"] boolValue];
    NSDictionary *pen=snapshot[@"penObserver"];
    BOOL controlling=UPSetupControlsInput(snapshot,listenGranted,postGranted,fault);
    NSString *unavailable=!running?@"Driver inactive":@"Driver unavailable";
    BOOL waitingForDevice=[pen[@"waitingForDevice"] boolValue];
    BOOL penMuted=controlling && !waitingForDevice && [snapshot[@"penInputEnabled"] isEqual:@NO];
    BOOL touchMuted=controlling && [snapshot[@"touchInputEnabled"] isEqual:@NO];
    BOOL penActive=controlling && !waitingForDevice && !penMuted && [pen[@"reports"] unsignedIntegerValue]>0 &&
        ![pen[@"pressureState"] isEqual:@"noData"] && ![pen[@"pressureState"] isEqual:@"inactive"];
    BOOL touchActive=controlling && !touchMuted && [snapshot[@"validFrames"] unsignedIntegerValue]>0;
    NSString *penText=!controlling?unavailable:[snapshot[@"touchRunningWithoutPen"] boolValue]?@"Unavailable — touch still enabled":waitingForDevice?@"Waiting for pen device":penMuted?@"Muted by driver":penActive?@"Active":@"Waiting for reports";
    NSString *touchText=!controlling?unavailable:touchMuted?@"Muted by driver":touchActive?@"Active":@"Waiting for reports";
    NSUInteger readiness=[snapshot[@"gestureReadiness"] unsignedIntegerValue];
    BOOL suppressed=running && (readiness==BTGestureReadinessPen || readiness==BTGestureReadinessLiftRequired);
    if(touchActive && suppressed)touchText=@"Active — palm suppression";
    return @{@"pen":penText,@"touch":touchText,@"listen":listenGranted?@"Granted":@"Not granted",
             @"post":postGranted?@"Granted":@"Not granted",
             @"penTone":!controlling || penMuted?@"off":penActive?@"active":@"waiting",
             @"touchTone":!controlling || touchMuted?@"off":touchActive?(suppressed?@"waiting":@"active"):@"waiting"};
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
    if(reason)*reason=saved?@"Off: saved display missing, ambiguous or mirrored. Reconnect it or choose a display and start the driver manually.":
        @"Off: no unique nonmirrored Bosto Tablet display. Connect it or choose a display and start the driver manually.";
    return nil;
}
