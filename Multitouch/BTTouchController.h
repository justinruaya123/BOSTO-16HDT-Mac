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
// Main-thread settings for the next start. Changing an active claim requires stop/restart.
@property(nonatomic) BOOL touchInputEnabled, penInputEnabled;
// YES (default): macOS owns finger output. NO: use the compatibility gesture synthesizer.
@property(nonatomic) BOOL nativeTouchEnabled;
@property(nonatomic) BOOL flipTouchY;
// Compatibility only. Missing keys use synthesized scroll/magnify instead of a key binding.
@property(nonatomic,copy) NSDictionary<NSString *,id> *gestureActions;
#endif
- (void)stop;
@end
