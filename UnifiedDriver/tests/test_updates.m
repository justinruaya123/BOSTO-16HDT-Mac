#import "UpdatePolicy.h"
#include <assert.h>

static NSMutableDictionary *fixture(void) {
    return [@{@"tag_name":@"v0.1.5",@"draft":@NO,@"prerelease":@NO,
        @"assets":@[@{@"name":@"BostoTablet.pkg",@"state":@"uploaded",@"size":@3,
        @"digest":@"sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        @"browser_download_url":@"https://github.com/justinruaya123/BOSTO-16HDT-Mac/releases/download/v0.1.5/BostoTablet.pkg"}]} mutableCopy];
}
int main(void) { @autoreleasepool {
    assert(UPVersionIsNewer(@"0.1.10",@"0.1.9"));
    assert(UPVersionIsNewer(@"1.0.0",@"0.99.99"));
    assert(UPVersionIsNewer(@"0.2.0",@"0.1.999"));
    assert(!UPVersionIsNewer(@"0.1.4",@"0.1.4"));
    assert(!UPVersionIsNewer(@"0.1.3",@"0.1.4"));
    for(NSString *s in @[@"v1.2.3",@"1.2",@"1.2.3.4",@"1.2.3-beta",@" 1.2.3",@"1.2.3\n",@"01.2.3",@"1.-2.3",@"１.2.3"]){
        assert(!UPVersionIsNewer(s,@"0.1.4"));assert(!UPVersionIsNewer(@"9.0.0",s));
    }
    NSDictionary *valid=UPValidatedRelease(fixture());assert(valid);
    NSData *abc=[@"abc" dataUsingEncoding:NSUTF8StringEncoding];
    assert(UPVerifyPackage(abc,valid));
    assert(!UPVerifyPackage([@"abd" dataUsingEncoding:NSUTF8StringEncoding],valid));
    assert(!UPVerifyPackage([NSData data],valid));
    assert(!UPValidatedRelease(@[]));assert(!UPValidatedRelease(nil));
    for(NSString *key in @[@"draft",@"prerelease"]){NSMutableDictionary *m=fixture();m[key]=@YES;assert(!UPValidatedRelease(m));[m removeObjectForKey:key];assert(!UPValidatedRelease(m));m[key]=@0;assert(!UPValidatedRelease(m));}
    for(id tag in @[@"0.1.5",@"v0.1.5-rc1",@"v0.1.5\n",@"v01.1.5",@5]){NSMutableDictionary *m=fixture();m[@"tag_name"]=tag;assert(!UPValidatedRelease(m));}
    NSMutableDictionary *m=fixture();m[@"assets"]=@[];assert(!UPValidatedRelease(m));
    m=fixture();m[@"assets"]=@[m[@"assets"][0],m[@"assets"][0]];assert(!UPValidatedRelease(m));
    NSDictionary *badFields=@{@"size":@[@0,@(-1),@YES,@3.5,@(32*1024*1024+1),@"3"],
        @"digest":@[@"sha256:abc",@"md5:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",NSNull.null],
        @"state":@[@"new",NSNull.null],
        @"browser_download_url":@[@"http://github.com/justinruaya123/BOSTO-16HDT-Mac/releases/download/v0.1.5/BostoTablet.pkg",
        @"https://github.com/other/BOSTO-16HDT-Mac/releases/download/v0.1.5/BostoTablet.pkg",
        @"https://github.com/justinruaya123/BOSTO-16HDT-Mac/releases/download/v0.1.4/BostoTablet.pkg",
        @"https://github.com/justinruaya123/BOSTO-16HDT-Mac/releases/download/v0.1.5/BostoTablet.pkg?x=1",
        @"https://github.com.evil.test/justinruaya123/BOSTO-16HDT-Mac/releases/download/v0.1.5/BostoTablet.pkg"]};
    for(NSString *key in badFields)for(id value in badFields[key]){m=fixture();NSMutableDictionary *a=[m[@"assets"][0] mutableCopy];a[key]=value;m[@"assets"]=@[a];assert(!UPValidatedRelease(m));}
    for(NSString *key in @[@"size",@"digest",@"state",@"browser_download_url"]){m=fixture();NSMutableDictionary *a=[m[@"assets"][0] mutableCopy];[a removeObjectForKey:key];m[@"assets"]=@[a];assert(!UPValidatedRelease(m));}
    assert(UPAllowedPackageRedirect([NSURL URLWithString:@"https://release-assets.githubusercontent.com/path?signature=abc"]));
    for(NSString *url in @[@"http://release-assets.githubusercontent.com/path",@"https://github.com/path",@"https://api.github.com/path",@"https://release-assets.githubusercontent.com.evil.test/path",@"https://user@release-assets.githubusercontent.com/path",@"https://release-assets.githubusercontent.com:443/path",@"https://release-assets.githubusercontent.com/path#fragment"])
        assert(!UPAllowedPackageRedirect([NSURL URLWithString:url]));
    assert(UPSizeAllowed(-1,0,3,3));assert(UPSizeAllowed(3,2,1,3));
    assert(!UPSizeAllowed(4,0,0,3));assert(!UPSizeAllowed(-1,3,1,3));
    assert(!UPSizeAllowed(3,0,4,3));assert(!UPSizeAllowed(-1,NSUIntegerMax,1,3));
    puts("Update policy: numeric versions, strict metadata, URL/redirect scope, size and SHA-256 checks passed (offline).");
}return 0;}
