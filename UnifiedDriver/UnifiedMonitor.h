#import "BTPenMonitor.h"
#import <ApplicationServices/ApplicationServices.h>
extern NSString *const UPFailureNotification;
// Configure display while disabled; controls update on the main thread while running.
// The touch controller creates this
// replacement monitor; its presence callback is the sole palm-rejection source.
@interface BTPenMonitor (UnifiedSettings)
+ (void)configureDisplay:(CGDirectDisplayID)display pressureExponent:(double)exponent;
+ (void)updatePressureExponent:(double)exponent;
+ (void)updateShortcutBindings:(NSArray *)bindings;
+ (void)setShortcutCapture:(BOOL)capturing;
@end
// Invalid saved bindings normalize to Unassigned (NSNull).
NSArray *UPValidatedBindings(id value);
