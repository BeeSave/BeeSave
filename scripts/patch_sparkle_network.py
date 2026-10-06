"""Create the reviewed downloader patch against the pinned upstream source."""
from pathlib import Path
import argparse
import difflib

def patched(original):
    text = original.replace('#import "SUErrors.h"', '#import "SUErrors.h"\n#import "BeeSaveDownloadPolicy.h"')
    text = text.replace('<NSURLSessionDownloadDelegate>', '<NSURLSessionDownloadDelegate, NSURLSessionDataDelegate>')
    text = text.replace('    BOOL _receivedExpectedBytes;', '''    BOOL _receivedExpectedBytes;
    BOOL _finished;
    NSUInteger _redirectCount;
    NSMutableData *_temporaryData;
    NSString *_ownedDownloadDirectory;''')
    start = text.index('- (void)startDownloadWithRequest:')
    end = text.index('// Don\'t implement dealloc', start)
    text = text[:start] + '''- (void)failDownload:(NSError *)error SPU_OBJC_DIRECT
{
    if (_finished || _delegate == nil) return;
    _finished = YES;
    [_delegate downloaderDidFailWithError:error];
    if (_ownedDownloadDirectory != nil) {
        [[NSFileManager defaultManager] removeItemAtPath:_ownedDownloadDirectory error:NULL];
        _ownedDownloadDirectory = nil;
    }
    [self _cleanup];
}

- (NSError *)downloadPolicyError:(NSString *)message SPU_OBJC_DIRECT
{
    return [NSError errorWithDomain:SUSparkleErrorDomain code:SUDownloadError
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (BOOL)validateResponse:(NSURLResponse *)response SPU_OBJC_DIRECT
{
    uint64_t limit = (_mode == SPUDownloadModeTemporary) ? BeeSaveFeedLimit : BeeSaveArchiveLimit;
    if (![response isKindOfClass:NSHTTPURLResponse.class] ||
        ((NSHTTPURLResponse *)response).statusCode != 200 ||
        !BeeSaveDownloadURL(_sessionTask.originalRequest.URL, response.URL) ||
        (response.expectedContentLength > 0 && (uint64_t)response.expectedContentLength > limit)) {
        [self failDownload:[self downloadPolicyError:@"The update response violates the BeeSave download policy."]];
        return NO;
    }
    return YES;
}

- (void)startDownloadWithRequest:(NSURLRequest *)request SPU_OBJC_DIRECT
{
    if (request == nil || !BeeSaveReleaseURL(request.URL)) {
        [self failDownload:[self downloadPolicyError:@"Only pinned BeeSave HTTPS release assets are allowed."]];
        return;
    }
    NSMutableURLRequest *safeRequest = [request mutableCopy];
    safeRequest.timeoutInterval = 15;
    safeRequest.HTTPShouldHandleCookies = NO;
    [safeRequest setValue:nil forHTTPHeaderField:@"Authorization"];
    [safeRequest setValue:nil forHTTPHeaderField:@"Cookie"];
    _downloadSession = [NSURLSession sessionWithConfiguration:BeeSaveDownloadConfiguration()
                                                   delegate:self delegateQueue:NSOperationQueue.mainQueue];
    if (_mode == SPUDownloadModePersistent) {
        _sessionTask = [_downloadSession downloadTaskWithRequest:safeRequest];
    } else {
        _temporaryData = [NSMutableData data];
        _sessionTask = [_downloadSession dataTaskWithRequest:safeRequest];
    }
    [_sessionTask resume];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
 willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler
{
    if (_finished || task != _sessionTask || ++_redirectCount > 5 ||
        !BeeSaveDownloadURL(task.originalRequest.URL, request.URL)) {
        completionHandler(nil);
        [self failDownload:[self downloadPolicyError:@"The update redirect is not allowed."]];
        return;
    }
    NSMutableURLRequest *safeRequest = [request mutableCopy];
    safeRequest.HTTPShouldHandleCookies = NO;
    [safeRequest setValue:nil forHTTPHeaderField:@"Authorization"];
    [safeRequest setValue:nil forHTTPHeaderField:@"Cookie"];
    completionHandler(safeRequest);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
 didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler
{
    // Keep normal TLS validation; never prompt for or transmit account credentials.
    BOOL tls = [challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust];
    completionHandler(tls ? NSURLSessionAuthChallengePerformDefaultHandling : NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
 didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
    BOOL allowed = !_finished && task == _sessionTask && [self validateResponse:response];
    completionHandler(allowed ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data
{
    if (_finished || task != _sessionTask) return;
    if (data.length > BeeSaveFeedLimit - _temporaryData.length) {
        [self failDownload:[self downloadPolicyError:@"The update feed exceeds 1 MiB."]];
        return;
    }
    [_temporaryData appendData:data];
}

''' + text[end:]
    text = text.replace('    _delegate = nil;\n}', '    _delegate = nil;\n    _temporaryData = nil;\n}')
    start = text.index('static bool SPUValidateStatusCodeAndFailIfInvalid')
    end = text.index('- (void)URLSession:', start)
    text = text[:start] + text[end:]
    text = text.replace('''    if (!SPUValidateStatusCodeAndFailIfInvalid(downloadTask.response, downloadTask.originalRequest.URL, _delegate)) {
        return;
    }''', '''    if (_finished || downloadTask != _sessionTask || ![self validateResponse:downloadTask.response]) return;
    NSNumber *size = nil;
    NSError *sizeError = nil;
    if (![location getResourceValue:&size forKey:NSURLFileSizeKey error:&sizeError] ||
        size.unsignedLongLongValue > BeeSaveArchiveLimit) {
        [self failDownload:sizeError ?: [self downloadPolicyError:@"The update archive exceeds 200 MiB."]];
        return;
    }''')
    text = text.replace('    if (tempDir == nil)\n', '    _ownedDownloadDirectory = tempDir;\n    if (tempDir == nil)\n')
    # All persistent error paths now release the session and their own temporary directory once.
    text = text.replace('[_delegate downloaderDidFailWithError:bookmarkError];', '[self failDownload:bookmarkError];')
    start = text.index('- (void)URLSession:', text.index('- (void)cleanup:'))
    prefix, tail = text[:start], text[start:]
    tail = tail.replace('[_delegate downloaderDidFailWithError:error];', '[self failDownload:error];')
    tail = tail.replace('            NSString *toPath = [downloadFileNameDirectory stringByAppendingPathComponent:name];', '''            name = name.lastPathComponent;
            if (name.length == 0 || [name isEqualToString:@"."] || [name isEqualToString:@".."]) name = _desiredFilename.lastPathComponent;
            NSString *toPath = [downloadFileNameDirectory stringByAppendingPathComponent:name];''')
    tail = tail.replace('''                    _sessionTask = nil;
                    
                    [_delegate downloaderDidFinishWithTemporaryDownloadData:nil];''', '''                    _finished = YES;
                    _ownedDownloadDirectory = nil;
                    [_delegate downloaderDidFinishWithTemporaryDownloadData:nil];
                    [self _cleanup];''')
    tail = tail.replace('totalBytesWritten:(int64_t)__unused totalBytesWritten', 'totalBytesWritten:(int64_t)totalBytesWritten')
    tail = tail.replace('''    if (_mode != SPUDownloadModePersistent) {''', '''    if (_finished || downloadTask != _sessionTask || _mode != SPUDownloadModePersistent) {''')
    tail = tail.replace('''    if (!_receivedExpectedBytes) {''', '''    if (totalBytesWritten < 0 || (uint64_t)totalBytesWritten > BeeSaveArchiveLimit ||
        (totalBytesExpectedToWrite > 0 && (uint64_t)totalBytesExpectedToWrite > BeeSaveArchiveLimit)) {
        [self failDownload:[self downloadPolicyError:@"The update archive exceeds 200 MiB."]];
        return;
    }
    if (!_receivedExpectedBytes) {''')
    start = tail.index('- (void)URLSession:', tail.index('didWriteData:'))
    tail = tail[:start] + '''- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    if (_finished || task != _sessionTask) return;
    if (error != nil) {
        [self failDownload:error];
    } else if (_mode == SPUDownloadModeTemporary && [self validateResponse:task.response]) {
        SPUDownloadData *data = [[SPUDownloadData alloc] initWithData:_temporaryData URL:task.response.URL
            textEncodingName:task.response.textEncodingName MIMEType:task.response.MIMEType];
        _finished = YES;
        [_delegate downloaderDidFinishWithTemporaryDownloadData:data];
        [self _cleanup];
    }
}

@end
'''
    return prefix + tail

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('original', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    original = args.original.read_text()
    updated = patched(original)
    args.output.write_text(''.join(difflib.unified_diff(original.splitlines(True), updated.splitlines(True),
        fromfile='a/Downloader/SPUDownloader.m', tofile='b/Downloader/SPUDownloader.m')))
