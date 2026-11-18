#import "UpdatePolicy.h"
#import <CommonCrypto/CommonDigest.h>

const NSUInteger UPMaximumPackageSize=32*1024*1024;
NSString * const UPLatestReleaseURL=@"https://api.github.com/repos/justinruaya123/BOSTO-16HDT-Mac/releases/latest";

static BOOL matches(id value,NSString *pattern) {
    if(![value isKindOfClass:NSString.class])return NO;
    NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
    NSTextCheckingResult *match=[re firstMatchInString:value options:0 range:NSMakeRange(0,[value length])];
    return match && NSEqualRanges(match.range,NSMakeRange(0,[value length]));
}
static BOOL version(id value) {return matches(value,@"(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)");}
BOOL UPVersionIsNewer(NSString *candidate,NSString *installed) {
    if(!version(candidate)||!version(installed))return NO;
    NSArray *a=[candidate componentsSeparatedByString:@"."],*b=[installed componentsSeparatedByString:@"."];
    for(NSUInteger i=0;i<3;i++){
        NSString *x=a[i],*y=b[i];
        if(x.length!=y.length)return x.length>y.length;
        NSComparisonResult order=[x compare:y options:NSLiteralSearch];
        if(order!=NSOrderedSame)return order==NSOrderedDescending;
    }
    return NO;
}
NSDictionary *UPValidatedRelease(id metadata) {
    if(![metadata isKindOfClass:NSDictionary.class])return nil;
    for(NSString *key in @[@"draft",@"prerelease"]){
        id flag=metadata[key];
        if(!flag||CFGetTypeID((__bridge CFTypeRef)flag)!=CFBooleanGetTypeID()||[flag boolValue])return nil;
    }
    id tag=metadata[@"tag_name"];
    if(![tag isKindOfClass:NSString.class]||![tag hasPrefix:@"v"]||!version([tag substringFromIndex:1]))return nil;
    id assets=metadata[@"assets"];
    if(![assets isKindOfClass:NSArray.class])return nil;
    NSDictionary *package=nil;
    for(id asset in assets){
        if(![asset isKindOfClass:NSDictionary.class])return nil;
        if([asset[@"name"] isEqual:@"BostoTablet.pkg"]){if(package)return nil;package=asset;}
    }
    if(!package||![package[@"state"] isEqual:@"uploaded"])return nil;
    id size=package[@"size"];
    if(![size isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)size)==CFBooleanGetTypeID()||CFNumberIsFloatType((__bridge CFNumberRef)size)||[size longLongValue]<=0||[size unsignedLongLongValue]>UPMaximumPackageSize)return nil;
    if(!matches(package[@"digest"],@"sha256:[0-9a-fA-F]{64}"))return nil;
    NSString *url=[NSString stringWithFormat:@"https://github.com/justinruaya123/BOSTO-16HDT-Mac/releases/download/%@/BostoTablet.pkg",tag];
    if(![package[@"browser_download_url"] isEqual:url])return nil;
    return @{@"version":[tag substringFromIndex:1],@"url":url,@"size":size,@"digest":[package[@"digest"] lowercaseString]};
}
BOOL UPAllowedPackageRedirect(NSURL *url) {
    return [url.scheme isEqual:@"https"] && [url.host isEqual:@"release-assets.githubusercontent.com"] && !url.user && !url.password && !url.port && !url.fragment;
}
BOOL UPSizeAllowed(int64_t advertised,NSUInteger received,NSUInteger incoming,NSUInteger limit) {
    return (advertised<0||(uint64_t)advertised<=limit) && received<=limit && incoming<=limit-received;
}
BOOL UPVerifyPackage(NSData *data,NSDictionary *release) {
    if(data.length!=[release[@"size"] unsignedIntegerValue]||data.length>UPMaximumPackageSize)return NO;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,hash);
    NSMutableString *digest=[NSMutableString stringWithString:@"sha256:"];
    for(NSUInteger i=0;i<sizeof(hash);i++)[digest appendFormat:@"%02x",hash[i]];
    return [digest isEqual:release[@"digest"]];
}
