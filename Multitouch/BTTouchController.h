#import <Cocoa/Cocoa.h>
#import "BT16Touch.h"
NSArray<NSDictionary *> *BTAvailableDisplays(void);
@interface BTTouchController : NSObject
// Owned by the main run loop, like the shared pen observer.
@property(nonatomic, readonly) BOOL running;
@property(nonatomic, readonly) NSString *status;
@property(nonatomic, readonly) NSDictionary *snapshot;
@property(nonatomic, readonly) double resumeDelay;
+ (NSDictionary *)diagnostics;
- (BOOL)startWithDisplay:(CGDirectDisplayID)display postEvents:(BOOL)postEvents error:(NSError **)error;
- (BOOL)updateResumeDelay:(double)seconds;
- (void)stop;
@end
