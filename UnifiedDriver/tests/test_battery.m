#import "PenBattery.h"
#include <assert.h>
#include <math.h>
int main(void){@autoreleasepool{
    assert(!UPBatteryPercent(nil));
    for(id bad in @[NSNull.null,@YES,@NO,@"19",@(-1),@101,@19.5,@(NAN),@(INFINITY),@(-INFINITY),@(ULLONG_MAX),[NSDecimalNumber notANumber], [NSDecimalNumber decimalNumberWithString:@"100.000000000000000001"], [NSDecimalNumber decimalNumberWithString:@"-0.000000000000000001"]]){if(UPBatteryPercent(bad))NSLog(@"Accepted invalid battery %@ (%@)",bad,[bad class]);assert(!UPBatteryPercent(bad));}
    for(int i=0;i<=100;i++)assert([UPBatteryPercent(@(i)) intValue]==i);
    assert([UPBatteryDescription(nil) isEqual:@"Pen battery: unavailable"]);
    assert([UPBatteryDescription(@19) isEqual:@"Pen battery: 19%"]);
    UPBatteryPolicy *p=[UPBatteryPolicy new];
    [p observe:nil];assert(![p beginConsentRequest] && ![p consumeLowAlert]);
    [p observe:@20];assert(![p beginConsentRequest] && ![p consumeLowAlert]);
    [p observe:@19];assert([p beginConsentRequest]);assert(![p beginConsentRequest]);
    // Pending consent must not schedule after disappearance, invalid data or recovery.
    [p observe:nil];assert(![p consumeLowAlert]);
    [p observe:@YES];assert(![p consumeLowAlert]);
    [p observe:@20];assert(![p consumeLowAlert]);
    [p observe:@19];assert([[p consumeLowAlert] isEqual:@19]);
    [p observe:@1];assert(![p consumeLowAlert]);
    [p observe:nil];[p observe:@19];assert(![p consumeLowAlert]); // Unknown preserves latch.
    [p observe:@101];[p observe:@19];assert(![p consumeLowAlert]);
    [p observe:@20];[p observe:@0];assert([[p consumeLowAlert] isEqual:@0]);
    assert(![p beginConsentRequest]);assert(![p consumeLowAlert]);
    puts("Conditional battery validation, consent, async recheck and low streak checks passed (offline).");
}return 0;}
