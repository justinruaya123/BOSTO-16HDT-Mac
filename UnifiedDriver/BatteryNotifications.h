#import <Foundation/Foundation.h>
@interface UPBatteryNotifications : NSObject
// Main-run-loop provider rechecks the current acquired pen at async completion.
- (instancetype)initWithReading:(NSNumber *(^)(void))reading;
- (void)refresh;
@end
