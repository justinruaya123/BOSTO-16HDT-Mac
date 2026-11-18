#import <Cocoa/Cocoa.h>
#import "UnifiedMonitor.h"
#import "UnifiedPen.h"

// A first-responder-only recorder: no event taps, local monitors or global listening.
@interface UPShortcutEditor : NSButton
@property(nonatomic,copy) void (^bindingChanged)(NSDictionary *binding);
@property(nonatomic,strong) id binding;
@property(nonatomic) BOOL recording;
@end
