#import <Cocoa/Cocoa.h>
#import "BT16Touch.h"
NSArray<NSDictionary *> *BTAvailableDisplays(void);
#ifdef BT_UNIFIED_DRIVER
// Metadata-only; returns one exact touch and one exact pen registry identity.
NSArray<NSNumber *> *BTTabletRegistryIdentity(void);
#endif
@interface BTTouchController : NSObject
// Owned by the main run loop, like the shared pen observer.
@property(nonatomic, readonly) BOOL running;
@property(nonatomic, readonly) NSString *status;
@property(nonatomic, readonly) NSDictionary *snapshot;
@property(nonatomic, readonly) double resumeDelay;
+ (NSDictionary *)diagnostics;
- (BOOL)startWithDisplay:(CGDirectDisplayID)display postEvents:(BOOL)postEvents error:(NSError **)error;
- (BOOL)updateResumeDelay:(double)seconds;
#ifdef BT_UNIFIED_DRIVER
@property(nonatomic) BOOL flipTouchY;
// Missing keys use native output. Values are @"off", @"shortcut" (unassigned), or a key binding.
@property(nonatomic,copy) NSDictionary<NSString *,id> *gestureActions;
#endif
- (void)stop;
@end
