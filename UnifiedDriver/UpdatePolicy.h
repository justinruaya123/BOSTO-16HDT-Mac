#import <Foundation/Foundation.h>

extern const NSUInteger UPMaximumPackageSize;
extern NSString * const UPLatestReleaseURL;
// Invalid versions return NO; comparison never converts components to machine integers.
BOOL UPVersionIsNewer(NSString *candidate, NSString *installed);
NSDictionary *UPValidatedRelease(id metadata);
BOOL UPAllowedPackageRedirect(NSURL *url);
BOOL UPSizeAllowed(int64_t advertised, NSUInteger received, NSUInteger incoming, NSUInteger limit);
BOOL UPVerifyPackage(NSData *data, NSDictionary *release);
