// Executes the actual patched SPUDownloader using deterministic URLSession responses.
#import <Foundation/Foundation.h>
#import "SPUDownloader.h"
#import "SPUDownloaderDelegate.h"
#import "SPUDownloadData.h"
#import "BeeSaveDownloadPolicy.h"

static NSString *scenario;
static NSUInteger failures;
static void check(BOOL condition, NSString *message) {
    if (!condition) { failures++; fprintf(stderr, "FAIL: %s\n", message.UTF8String); }
}

@interface FixtureProtocol : NSURLProtocol
@property(atomic) BOOL stopped;
@end
@implementation FixtureProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSString *mode = [scenario copy];
    if ([mode isEqualToString:@"offline"]) {
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]];
        return;
    }
    if ([mode isEqualToString:@"redirect"] || [mode isEqualToString:@"redirect-good"]) {
        NSString *destination = [mode isEqualToString:@"redirect"] ? @"https://example.com/update.dmg" : @"https://release-assets.githubusercontent.com/file";
        if ([self.request.URL.host isEqualToString:@"github.com"]) {
            NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:302 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Location":destination}];
            [self.client URLProtocol:self wasRedirectedToRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:destination]] redirectResponse:response];
            return;
        }
    }
    BOOL archive = [self.request.URL.path hasSuffix:@".dmg"];
    NSInteger status = [mode isEqualToString:@"status"] ? 500 : 200;
    NSMutableDictionary *headers = [@{@"Content-Type":@"application/octet-stream"} mutableCopy];
    if ([mode isEqualToString:@"header-limit"]) headers[@"Content-Length"] = archive ? @"209715201" : @"1048577";
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:headers];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    NSUInteger count = [mode isEqualToString:@"stream-limit"] ? (archive ? 201 : 2) : 1;
    NSUInteger chunkSize = [mode isEqualToString:@"stream-limit"] ? 1024 * 1024 : 32;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *chunk = [NSMutableData dataWithLength:chunkSize];
        for (NSUInteger i = 0; i < count && !self.stopped; i++) {
            [self.client URLProtocol:self didLoadData:chunk];
            [NSThread sleepForTimeInterval:0.015];
        }
        if (!self.stopped) [self.client URLProtocolDidFinishLoading:self];
    });
}
- (void)stopLoading { self.stopped = YES; }
@end

NSArray<Class> *BeeSaveNetworkTestProtocols(void) { return @[FixtureProtocol.class]; }

@interface Receiver : NSObject <SPUDownloaderDelegate>
@property NSUInteger completions;
@property NSUInteger errors;
@property NSData *body;
@property NSString *token;
@end
@implementation Receiver
- (void)downloaderDidSetDownloadBookmarkData:(NSData *)data downloadToken:(NSString *)token { self.token = token; }
- (void)downloaderDidReceiveExpectedContentLength:(int64_t)length {}
- (void)downloaderDidReceiveDataOfLength:(uint64_t)length {}
- (void)downloaderDidFinishWithTemporaryDownloadData:(SPUDownloadData *)data { self.completions++; self.body = data.data; }
- (void)downloaderDidFailWithError:(NSError *)error { self.errors++; }
@end

static void pump(NSTimeInterval seconds, BOOL (^done)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    do {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    } while (!done() && deadline.timeIntervalSinceNow > 0);
}

static void run(NSString *mode, BOOL archive, BOOL success) {
    scenario = mode;
    Receiver *receiver = [Receiver new];
    SPUDownloader *downloader = [[SPUDownloader alloc] initWithDelegate:receiver];
    NSURL *url = [NSURL URLWithString:archive ? @"https://github.com/BeeSave/BeeSave/releases/download/v1.2.0/BeeSave-macos-arm64.dmg" : @"https://github.com/BeeSave/BeeSave/releases/download/v1.2.0/appcast.xml"];
    if (archive) [downloader startPersistentDownloadWithRequest:[NSURLRequest requestWithURL:url] bundleIdentifier:@"com.beesave.network-tests" desiredFilename:@"update.dmg"];
    else [downloader startTemporaryDownloadWithRequest:[NSURLRequest requestWithURL:url]];
    if ([mode isEqualToString:@"cancel"]) {
        [downloader cleanup:^{}];
        pump(0.2, ^{return NO;});
        check(receiver.errors == 0 && receiver.completions == 0, @"Cancellation must not finish or fail a dismissed update");
    } else {
        pump(15, ^{return (BOOL)(receiver.errors + receiver.completions > 0);});
        pump(0.1, ^{return NO;});
        check(success ? (receiver.completions == 1 && receiver.errors == 0) : (receiver.errors == 1 && receiver.completions == 0), [NSString stringWithFormat:@"%@ %@ must complete exactly once", mode, archive ? @"archive" : @"feed"]);
        if (success && !archive) check(receiver.body.length == 32, @"Successful feed bytes must be complete");
        if (receiver.token) [downloader removeDownloadDirectoryWithDownloadToken:receiver.token bundleIdentifier:@"com.beesave.network-tests"];
        [downloader cleanup:^{}];
    }
    pump(0.05, ^{return NO;});
    fprintf(stdout, "%s %s checked\n", mode.UTF8String, archive ? "archive" : "feed");
}

int main(void) { @autoreleasepool {
    NSURL *initial = [NSURL URLWithString:@"https://github.com/BeeSave/BeeSave/releases/download/v1.2.0/appcast.xml"];
    check(BeeSaveReleaseURL(initial), @"Exact release feed allowed");
    for (NSString *address in @[@"http://github.com/BeeSave/BeeSave/releases/download/v1.2.0/appcast.xml", @"https://github.com/Other/BeeSave/releases/download/v1.2.0/appcast.xml", @"https://user@github.com/BeeSave/BeeSave/releases/download/v1.2.0/appcast.xml", @"https://github.com:444/BeeSave/BeeSave/releases/download/v1.2.0/appcast.xml", @"https://github.com/BeeSave/BeeSave/releases/download/v1.3.0/appcast.xml", @"https://github.com.evil.test/file", @"https://api.github.com/file"]) {
        check(!BeeSaveDownloadURL(initial, [NSURL URLWithString:address]), @"Foreign redirect blocked");
    }
    NSURLSessionConfiguration *config = BeeSaveDownloadConfiguration();
    check(config.timeoutIntervalForRequest == 15 && config.timeoutIntervalForResource == 300, @"Both network deadlines set");
    check(!config.HTTPShouldSetCookies && !config.HTTPCookieStorage && !config.URLCredentialStorage && !config.URLCache, @"No persistent accounts or caches");
    for (NSNumber *archive in @[@NO, @YES]) {
        run(@"ok", archive.boolValue, YES);
        run(@"header-limit", archive.boolValue, NO);
        run(@"stream-limit", archive.boolValue, NO);
        run(@"status", archive.boolValue, NO);
        run(@"offline", archive.boolValue, NO);
        run(@"redirect", archive.boolValue, NO);
        run(@"redirect-good", archive.boolValue, YES);
        run(@"cancel", archive.boolValue, NO);
    }
    fprintf(stdout, "Downloader failures: %lu\n", (unsigned long)failures);
    return failures ? 1 : 0;
} }
