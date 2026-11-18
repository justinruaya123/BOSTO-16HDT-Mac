// Exercise the actual delegate decisions and file writer without network, AppKit UI,
// user Downloads, HID, or permission access. This translation unit is test-only.
#import "../UpdateController.m"
#include <assert.h>

static NSHTTPURLResponse *response(NSInteger status,NSString *length) {
    return [[NSHTTPURLResponse alloc]initWithURL:[NSURL URLWithString:UPLatestReleaseURL] statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:length?@{@"Content-Length":length}:@{}];
}
int main(void) { @autoreleasepool {
    NSURLSession *session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    NSURLSessionDataTask *task=[session dataTaskWithURL:[NSURL URLWithString:UPLatestReleaseURL]]; // Never resumed.
    for(NSNumber *status in @[@200,@403,@404,@429,@500]){
        UPUpdateRequest *r=[UPUpdateRequest new];r.limit=3;
        __block NSURLSessionResponseDisposition result=NSURLSessionResponseAllow;
        [r URLSession:session dataTask:task didReceiveResponse:response(status.integerValue,@"3") completionHandler:^(NSURLSessionResponseDisposition d){result=d;}];
        assert((result==NSURLSessionResponseAllow)==(status.integerValue==200));
    }
    UPUpdateRequest *r=[UPUpdateRequest new];r.limit=3;r.data=[NSMutableData data];
    __block NSURLSessionResponseDisposition result=NSURLSessionResponseAllow;
    [r URLSession:session dataTask:task didReceiveResponse:response(200,@"4") completionHandler:^(NSURLSessionResponseDisposition d){result=d;}];
    assert(result==NSURLSessionResponseCancel && r.failure);
    r=[UPUpdateRequest new];r.limit=3;r.data=[NSMutableData data];
    NSData *abc=[@"abc" dataUsingEncoding:NSUTF8StringEncoding];
    [r URLSession:session dataTask:task didReceiveData:abc];assert(r.data.length==3 && !r.failure);
    [r URLSession:session dataTask:task didReceiveData:abc];assert(r.data.length==3 && r.failure);
    for(NSNumber *package in @[@NO,@YES])for(NSString *url in @[@"https://release-assets.githubusercontent.com/path?sig=1",@"https://evil.test/path",UPLatestReleaseURL]){
        r=[UPUpdateRequest new];r.package=package.boolValue;
        NSURLRequest *request=[NSURLRequest requestWithURL:[NSURL URLWithString:url]];
        __block NSURLRequest *redirect=nil;
        [r URLSession:session task:task willPerformHTTPRedirection:response(302,nil) newRequest:request completionHandler:^(NSURLRequest *allowed){redirect=allowed;}];
        assert((redirect!=nil)==(package.boolValue && [url hasPrefix:@"https://release-assets.githubusercontent.com/"]));
    }
    [session invalidateAndCancel];
    NSURL *root=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    NSFileManager *files=NSFileManager.defaultManager;
    assert([files createDirectoryAtURL:root withIntermediateDirectories:NO attributes:nil error:NULL]);
    NSDictionary *release=@{@"version":@"0.1.5"};NSError *error=nil;
    NSURL *first=savePackage(abc,release,root,&error);assert(first && !error);
    NSURL *second=savePackage(abc,release,root,&error);assert(second && !error && ![first isEqual:second]);
    assert([[NSData dataWithContentsOfURL:first] isEqual:abc]);assert([[NSData dataWithContentsOfURL:second] isEqual:abc]);
    char quarantine[512]={0};ssize_t n=getxattr(first.fileSystemRepresentation,"com.apple.quarantine",quarantine,sizeof(quarantine),0,0);
    assert(n>0 && strncmp(quarantine,"0083;",5)==0 && strstr(quarantine,";BostoTablet;"));
    NSURL *missing=[root URLByAppendingPathComponent:@"missing" isDirectory:YES];
    assert(!savePackage(abc,release,missing,&error) && error);
    assert([[NSData dataWithContentsOfURL:first] isEqual:abc]);
    assert([files removeItemAtURL:root error:NULL]);
    puts("Update request rejection, received-size bounds, unique saves and quarantine checks passed (offline).");
}return 0;}
