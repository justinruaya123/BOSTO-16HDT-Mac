#import <Foundation/Foundation.h>
// Missing, boolean, nonintegral and out-of-range properties are unavailable.
NSNumber *UPBatteryPercent(id property);
NSString *UPBatteryDescription(NSNumber *percent);
@interface UPBatteryPolicy : NSObject
@property(nonatomic,readonly) BOOL consentRequested;
- (void)observe:(id)property;
- (BOOL)beginConsentRequest;
- (NSNumber *)consumeLowAlert;
@end
