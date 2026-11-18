#import <Foundation/Foundation.h>
#import "BTGestures.h"
// Owned by the main run loop. Shared observation; never seize or write the pen.
@interface BTPenMonitor : NSObject
@property(nonatomic,readonly) BOOL running;
@property(nonatomic,readonly) BTPenPresence presence;
@property(nonatomic,readonly,copy) NSString *status;
@property(nonatomic,copy) void (^presenceChanged)(BTPenPresence presence);
- (BOOL)startWithError:(NSError **)error;
- (void)stop;
- (NSDictionary *)snapshot;
@end
