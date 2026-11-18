#import "PenBattery.h"
#include <math.h>
NSNumber *UPBatteryPercent(id property) {
    if(![property isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)property)==CFBooleanGetTypeID())return nil;
    double n=[property doubleValue];
    if(!isfinite(n) || n<0 || n>100 || floor(n)!=n)return nil;
    // NSNumber comparison can round NSDecimalNumber through double. Preserve
    // decimal precision before accepting a value that rounded onto an integer.
    NSDecimalNumber *decimal=[NSDecimalNumber decimalNumberWithDecimal:[property decimalValue]];
    NSDecimalNumber *integer=[NSDecimalNumber decimalNumberWithMantissa:(uint64_t)n exponent:0 isNegative:NO];
    if([decimal isEqual:NSDecimalNumber.notANumber] || [decimal compare:integer]!=NSOrderedSame)return nil;
    return @((NSInteger)n);
}
NSString *UPBatteryDescription(NSNumber *percent) {
    NSNumber *valid=UPBatteryPercent(percent);
    return valid?[NSString stringWithFormat:@"Pen battery: %@%%",valid]:@"Pen battery: unavailable";
}
@implementation UPBatteryPolicy {
    NSNumber *_percent;
    BOOL _alerted;
}
- (void)observe:(id)property {
    _percent=UPBatteryPercent(property);
    if(_percent && _percent.integerValue>=20)_alerted=NO;
}
- (BOOL)beginConsentRequest {
    if(_consentRequested || !_percent || _percent.integerValue>=20)return NO;
    _consentRequested=YES;return YES;
}
- (NSNumber *)consumeLowAlert {
    if(!_percent || _percent.integerValue>=20 || _alerted)return nil;
    _alerted=YES;return _percent;
}
@end
