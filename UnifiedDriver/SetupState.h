#import <Foundation/Foundation.h>
#import "BTGestures.h"
typedef NS_ENUM(NSUInteger, UPMenuState) { UPMenuUnavailable, UPMenuPen, UPMenuTouch };
UPMenuState UPSetupMenuState(NSDictionary *snapshot, BOOL listenGranted, BOOL postGranted, BOOL fault);

typedef NS_ENUM(NSUInteger, UPEnableAction) {
    UPDisable, UPRequestInputMonitoring, UPRequestAccessibility, UPValidateDisplay
};
UPEnableAction UPSetupAction(BOOL running, BOOL listenGranted, BOOL postGranted);
// Each explicit permission branch ends its start attempt; a grant never prompts again.
BOOL UPRequestSetupPermission(BOOL (^preflight)(void), void (^request)(void), void (^openSettings)(void));
// Snapshot-only presentation; never discovers or opens hardware.
NSDictionary *UPSetupStatus(NSDictionary *snapshot, BOOL listenGranted, BOOL postGranted);

// Never falls back when a saved UUID is missing, duplicated, or mirrored.
NSDictionary *UPLaunchDisplay(NSArray<NSDictionary *> *displays, NSString *savedUUID, NSString **reason);
