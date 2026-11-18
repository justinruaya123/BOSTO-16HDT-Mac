#import "UpdateController.h"
#import "UpdatePolicy.h"
#include <fcntl.h>
#include <unistd.h>
#include <sys/xattr.h>
#include <errno.h>

// One bounded request per session. No cookies, disk cache, credentials or background tasks.
@interface UPUpdateRequest : NSObject<NSURLSessionDataDelegate>
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSMutableData *data;
@property(nonatomic) NSUInteger limit;
@property(nonatomic) BOOL package;
@property(nonatomic,copy) NSString *failure;
@property(nonatomic,copy) void (^completion)(NSData *,NSString *);
- (void)startURL:(NSURL *)url package:(BOOL)package limit:(NSUInteger)limit completion:(void (^)(NSData *,NSString *))completion;
@end
@implementation UPUpdateRequest
- (void)startURL:(NSURL *)url package:(BOOL)package limit:(NSUInteger)limit completion:(void (^)(NSData *,NSString *))completion {
    self.package=package;self.limit=limit;self.completion=completion;self.data=[NSMutableData data];
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest=15;config.timeoutIntervalForResource=120;
    config.HTTPCookieStorage=nil;config.HTTPShouldSetCookies=NO;config.URLCredentialStorage=nil;config.URLCache=nil;
    NSOperationQueue *queue=[NSOperationQueue new];queue.maxConcurrentOperationCount=1;
    self.session=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:queue];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    [request setValue:@"BostoTablet-Manual-Updater" forHTTPHeaderField:@"User-Agent"];
    [request setValue:package?@"application/octet-stream":@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [[self.session dataTaskWithRequest:request] resume];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    (void)session;(void)task;(void)response;
    BOOL allowed=self.package && UPAllowedPackageRedirect(request.URL);
    if(!allowed)self.failure=@"GitHub returned an unexpected redirect. No package was saved.";
    completionHandler(allowed?request:nil);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    (void)session;(void)task;
    NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)response statusCode]:0;
    if(self.failure){completionHandler(NSURLSessionResponseCancel);return;}
    if(status!=200){
        self.failure=status==403||status==429?@"GitHub's request limit was reached. Please try again later.":@"GitHub could not provide the release (it may be unavailable). Please try again later.";
        completionHandler(NSURLSessionResponseCancel);return;
    }
    if(!UPSizeAllowed(response.expectedContentLength,0,0,self.limit)){
        self.failure=@"GitHub advertised an excessive download size. No package was saved.";
        completionHandler(NSURLSessionResponseCancel);return;
    }
    completionHandler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    (void)session;
    if(!UPSizeAllowed(-1,self.data.length,data.length,self.limit)){
        self.failure=@"The received download exceeded its size limit. No package was saved.";[task cancel];return;
    }
    [self.data appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    (void)task;
    NSString *failure=self.failure;
    if(!failure && error){
        BOOL offline=error.code==NSURLErrorNotConnectedToInternet||error.code==NSURLErrorNetworkConnectionLost||error.code==NSURLErrorCannotFindHost||error.code==NSURLErrorCannotConnectToHost||error.code==NSURLErrorTimedOut;
        failure=offline?@"Unable to reach GitHub. Check your connection and try again.":@"The secure GitHub request failed. Please try again later. No package was saved.";
    }
    NSData *data=failure?nil:[self.data copy];
    void (^completion)(NSData *,NSString *)=self.completion;self.completion=nil;
    [session finishTasksAndInvalidate];self.session=nil;
    // Parsing, hashing and disk writes stay off the UI thread.
    completion(data,failure);
}
@end

static NSURL *savePackage(NSData *data,NSDictionary *release,NSURL *downloads,NSError **error) {
    NSFileManager *files=NSFileManager.defaultManager;
    if(!downloads)return nil;
    NSString *pattern=[[downloads URLByAppendingPathComponent:[NSString stringWithFormat:@"BostoTablet-%@-XXXXXX",release[@"version"]]] path];
    char *path=strdup(pattern.fileSystemRepresentation);
    if(!path){if(error)*error=[NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil];return nil;}
    if(!mkdtemp(path)){int code=errno;free(path);if(error)*error=[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];return nil;}
    NSURL *folder=[NSURL fileURLWithFileSystemRepresentation:path isDirectory:YES relativeToURL:nil];free(path);
    NSURL *url=[folder URLByAppendingPathComponent:@"BostoTablet.pkg"];
    int fd=open(url.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    int code=fd<0?errno:0;
    if(fd>=0){
        // POSIX creation must explicitly retain the quarantine expected for internet downloads.
        NSString *quarantine=[NSString stringWithFormat:@"0083;%llx;BostoTablet;%@",(unsigned long long)NSDate.date.timeIntervalSince1970,NSUUID.UUID.UUIDString];
        NSData *q=[quarantine dataUsingEncoding:NSUTF8StringEncoding];
        if(fsetxattr(fd,"com.apple.quarantine",q.bytes,q.length,0,0)<0)code=errno;
        NSUInteger written=0;
        while(!code && written<data.length){ssize_t n=write(fd,(const char *)data.bytes+written,data.length-written);if(n<0 && errno==EINTR)continue;if(n<=0){code=n<0?errno:EIO;break;}written+=(NSUInteger)n;}
        if(close(fd)<0 && !code)code=errno;
    }
    if(code){[files removeItemAtURL:folder error:NULL];if(error)*error=[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];return nil;}
    return url;
}

@interface UPUpdateController ()
@property(nonatomic) BOOL busy;
@property(nonatomic,weak) NSMenuItem *menuItem;
@end
@implementation UPUpdateController
- (BOOL)validateMenuItem:(NSMenuItem *)item {(void)item;return !self.busy;}
- (void)finishWithTitle:(NSString *)title message:(NSString *)message {
    NSAssert(NSThread.isMainThread,@"Update UI must run on the main thread");
    self.menuItem.title=@"Check for Updates…";
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert=[NSAlert new];alert.messageText=title;alert.informativeText=message;[alert runModal];
    self.busy=NO;
}
- (void)checkForUpdates:(id)sender {
    NSAssert(NSThread.isMainThread,@"Update UI must run on the main thread");
    if(self.busy)return;self.busy=YES;
    if([sender isKindOfClass:NSMenuItem.class])self.menuItem=sender;
    self.menuItem.title=@"Checking for Updates…";
    NSString *installed=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    UPUpdateRequest *request=[UPUpdateRequest new];
    [request startURL:[NSURL URLWithString:UPLatestReleaseURL] package:NO limit:1024*1024 completion:^(NSData *data,NSString *failure){
        id metadata=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
        NSDictionary *release=UPValidatedRelease(metadata);
        dispatch_async(dispatch_get_main_queue(),^{
            if(failure){[self finishWithTitle:@"Couldn’t Check for Updates" message:failure];return;}
            if(!release){[self finishWithTitle:@"Invalid Release Information" message:@"GitHub did not return a valid stable release with one uploaded BostoTablet.pkg and a SHA-256 digest. Nothing was downloaded."];return;}
            if(!UPVersionIsNewer(release[@"version"],installed)){
                [self finishWithTitle:@"You’re Up to Date" message:[NSString stringWithFormat:@"BostoTablet %@ is installed. The latest stable release is %@; no newer package is available.",installed,release[@"version"]]];return;
            }
            NSAlert *alert=[NSAlert new];alert.messageText=[NSString stringWithFormat:@"BostoTablet %@ Is Available",release[@"version"]];
            alert.informativeText=[NSString stringWithFormat:@"Installed: %@. Download the %.1f MiB package to Downloads and reveal it in Finder?\n\nThe package is unsigned and unnotarized. BostoTablet verifies its size and GitHub SHA-256 digest, but macOS security checks still apply. Quit BostoTablet before opening the package in Installer. You may need to reapprove device permissions after installation.",installed,[release[@"size"] doubleValue]/(1024*1024)];
            [alert addButtonWithTitle:@"Download Package"];[alert addButtonWithTitle:@"Cancel"];
            [NSApp activateIgnoringOtherApps:YES];
            if([alert runModal]!=NSAlertFirstButtonReturn){self.menuItem.title=@"Check for Updates…";self.busy=NO;return;}
            self.menuItem.title=@"Downloading Update…";
            UPUpdateRequest *download=[UPUpdateRequest new];
            [download startURL:[NSURL URLWithString:release[@"url"]] package:YES limit:[release[@"size"] unsignedIntegerValue] completion:^(NSData *package,NSString *downloadFailure){
                NSURL *saved=nil;NSString *message=downloadFailure;
                if(!message && !UPVerifyPackage(package,release))message=@"The package size or SHA-256 digest did not match GitHub's release metadata. No package was saved. Please try again later.";
                if(!message){
                    NSError *error=nil;
                    NSURL *downloads=[NSFileManager.defaultManager URLForDirectory:NSDownloadsDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:&error];
                    saved=savePackage(package,release,downloads,&error);
                    if(!saved)message=[NSString stringWithFormat:@"The verified package could not be saved in Downloads: %@",error.localizedDescription];
                }
                dispatch_async(dispatch_get_main_queue(),^{
                    if(message){[self finishWithTitle:@"Update Download Failed" message:message];return;}
                    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[saved]];
                    [self finishWithTitle:@"Verified Package Saved" message:[NSString stringWithFormat:@"Saved to %@ and revealed in Finder.\n\nQuit BostoTablet before opening BostoTablet.pkg in Installer. This package is unsigned and unnotarized; macOS security checks still apply. You may need to reapprove Input Monitoring and Accessibility permissions after installation.",saved.path]];
                });
            }];
        });
    }];
}
@end
