#import <Cocoa/Cocoa.h>
#import "BT16Touch.h"
NSArray<NSDictionary *> *BTAvailableDisplays(void);
#ifdef BT_UNIFIED_DRIVER
// Metadata only. The retry key identifies the exact digitizer, independent of pen arrival/removal.
// This never authorizes a pen open; the pen monitor verifies its own candidate.
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
// YES (default): report 4 drives the absolute single-finger pointer; macOS owns multitouch.
// NO: use the compatibility gesture synthesizer (including its vendor report 3 fallback).
@property(nonatomic) BOOL nativeTouchEnabled;
@property(nonatomic) BOOL flipTouchY;
// Compatibility only. Missing keys use synthesized scroll/magnify instead of a key binding.
@property(nonatomic,copy) NSDictionary<NSString *,id> *gestureActions;
#endif
- (void)stop;
@end
