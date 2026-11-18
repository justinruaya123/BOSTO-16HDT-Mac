#import "BatteryNotifications.h"
#import "PenBattery.h"
#import <UserNotifications/UserNotifications.h>
@interface UPBatteryNotifications () <UNUserNotificationCenterDelegate>
@end
@implementation UPBatteryNotifications {
    UPBatteryPolicy *_policy;
    NSNumber *(^_reading)(void);
    BOOL _authorized;
}
- (instancetype)initWithReading:(NSNumber *(^)(void))reading {
    if((self=[super init])){_reading=[reading copy];_policy=[UPBatteryPolicy new];}return self;
}
- (void)refresh {
    [_policy observe:_reading()];
    if([_policy beginConsentRequest]) {
        UNUserNotificationCenter *center=UNUserNotificationCenter.currentNotificationCenter;
        center.delegate=self;
        [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert completionHandler:^(BOOL granted,NSError *error){
            (void)error;
            dispatch_async(dispatch_get_main_queue(),^{self->_authorized=granted;[self refresh];});
        }];
    }
    if(!_authorized)return;
    NSNumber *low=[_policy consumeLowAlert];if(!low)return;
    UNMutableNotificationContent *content=[UNMutableNotificationContent new];
    content.title=@"Pen battery low";
    content.body=[NSString stringWithFormat:@"The pen reports %@%% battery remaining.",low];
    UNNotificationRequest *request=[UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString content:content trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:nil];
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    (void)center;
    (void)notification;
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList);
}
@end
