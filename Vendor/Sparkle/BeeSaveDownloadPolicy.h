// BeeSave's transport contract for the pinned Sparkle source build.
// This header is private to SPUDownloader; installer APIs are unchanged.
#import <Foundation/Foundation.h>

static const uint64_t BeeSaveFeedLimit = 1024 * 1024;
static const uint64_t BeeSaveArchiveLimit = 200 * 1024 * 1024;

static BOOL BeeSaveReleaseURL(NSURL *url) {
    if (![url.scheme.lowercaseString isEqualToString:@"https"] || url.user || url.password ||
        (url.port && url.port.integerValue != 443) || url.fragment || url.query ||
        ![url.host.lowercaseString isEqualToString:@"github.com"]) return NO;
    NSArray<NSString *> *parts = url.pathComponents;
    if (parts.count != 7 || ![parts[1] isEqualToString:@"BeeSave"] ||
        ![parts[2] isEqualToString:@"BeeSave"] || ![parts[3] isEqualToString:@"releases"] ||
        ![parts[4] isEqualToString:@"download"] || ![parts[5] hasPrefix:@"v"] ||
        [parts[5] containsString:@"/"] || [parts[6] containsString:@"/"]) return NO;
    return [parts[6] isEqualToString:@"appcast.xml"] || [parts[6] hasSuffix:@".dmg"];
}

static BOOL BeeSaveDownloadURL(NSURL *initialURL, NSURL *url) {
    if (!BeeSaveReleaseURL(initialURL) || ![url.scheme.lowercaseString isEqualToString:@"https"] ||
        url.user || url.password || (url.port && url.port.integerValue != 443) || url.fragment) return NO;
    NSString *host = url.host.lowercaseString;
    if ([host isEqualToString:@"github.com"]) return [initialURL.absoluteString isEqualToString:url.absoluteString];
    return [host isEqualToString:@"release-assets.githubusercontent.com"] ||
           [host isEqualToString:@"objects.githubusercontent.com"];
}

static NSURLSessionConfiguration *BeeSaveDownloadConfiguration(void) {
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = 15;
    config.timeoutIntervalForResource = 300;
    config.HTTPCookieStorage = nil;
    config.HTTPShouldSetCookies = NO;
    config.URLCredentialStorage = nil;
    config.URLCache = nil;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
#if defined(BEESAVE_UPDATE_NETWORK_TESTS)
    extern NSArray<Class> *BeeSaveNetworkTestProtocols(void);
    config.protocolClasses = BeeSaveNetworkTestProtocols();
#endif
    return config;
}
