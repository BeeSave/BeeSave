// BeeSave's additional package checks after Sparkle validates the Ed25519 DMG.
#import <Foundation/Foundation.h>
#import <Security/Security.h>

static NSDictionary *BeeSaveCodeInformation(NSURL *url) {
    SecStaticCodeRef code = NULL;
    if (SecStaticCodeCreateWithPath((__bridge CFURLRef)url, kSecCSDefaultFlags, &code) != errSecSuccess) return nil;
    CFDictionaryRef info = NULL;
    OSStatus status = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info);
    CFRelease(code);
    if (status != errSecSuccess) return nil;
    return CFBridgingRelease(info);
}

static BOOL BeeSaveValidatePackage(NSURL *incomingURL, NSURL *oldURL, NSString *build, NSString *version, NSError **error) {
    NSBundle *incoming = [NSBundle bundleWithURL:incomingURL];
    NSBundle *old = [NSBundle bundleWithURL:oldURL];
    NSDictionary *oldCode = BeeSaveCodeInformation(oldURL);
    NSDictionary *newCode = BeeSaveCodeInformation(incomingURL);
    NSString *team = oldCode[(__bridge NSString *)kSecCodeInfoTeamIdentifier];
    NSDictionary *oldEntitlements = oldCode[(__bridge NSString *)kSecCodeInfoEntitlementsDict];
    NSDictionary *newEntitlements = newCode[(__bridge NSString *)kSecCodeInfoEntitlementsDict];
    BOOL valid = incoming && old && build.length > 0 && version.length > 0 && team.length > 0 &&
        [old.bundleIdentifier isEqualToString:@"com.mubudget.app"] && [incoming.bundleIdentifier isEqualToString:old.bundleIdentifier] &&
        [team isEqualToString:newCode[(__bridge NSString *)kSecCodeInfoTeamIdentifier]] &&
        [incoming.infoDictionary[@"CFBundleVersion"] isEqualToString:build] &&
        [incoming.infoDictionary[@"CFBundleShortVersionString"] isEqualToString:version] &&
        [incoming.infoDictionary[@"SUPublicEDKey"] isEqualToString:old.infoDictionary[@"SUPublicEDKey"]] &&
        [incoming.infoDictionary[@"SURequireSignedFeed"] boolValue] &&
        [incoming.infoDictionary[@"SUVerifyUpdateBeforeExtraction"] boolValue] &&
        [incoming.infoDictionary[@"SUSignedFeedFailureExpirationInterval"] doubleValue] == 0 &&
        (([newCode[(__bridge NSString *)kSecCodeInfoFlags] unsignedIntValue] & 0x10000) != 0) &&
        [newEntitlements isEqualToDictionary:oldEntitlements] && [newEntitlements[@"com.apple.security.app-sandbox"] boolValue] &&
        ![newEntitlements[@"com.apple.security.get-task-allow"] boolValue] &&
        ![newEntitlements[@"com.apple.security.cs.disable-library-validation"] boolValue] &&
        [incoming.executableArchitectures isEqualToArray:@[@(NSBundleExecutableArchitectureARM64)]];
    if (valid) {
        SecStaticCodeRef code = NULL;
        SecRequirementRef requirement = NULL;
        NSString *rule = [NSString stringWithFormat:@"anchor apple generic and identifier \"com.mubudget.app\" and certificate leaf[subject.OU] = \"%@\"", team];
        valid = SecStaticCodeCreateWithPath((__bridge CFURLRef)incomingURL, kSecCSDefaultFlags, &code) == errSecSuccess &&
            SecRequirementCreateWithString((__bridge CFStringRef)rule, kSecCSDefaultFlags, &requirement) == errSecSuccess;
        if (valid) valid = SecStaticCodeCheckValidity(code, kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures, requirement) == errSecSuccess;
        if (requirement) CFRelease(requirement);
        if (code) CFRelease(code);
    }
    if (valid) {
        NSDirectoryEnumerator<NSURL *> *files = [NSFileManager.defaultManager enumeratorAtURL:incomingURL
            includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey] options:0 errorHandler:nil];
        for (NSURL *file in files) {
            NSNumber *regular = nil, *link = nil;
            [file getResourceValue:&regular forKey:NSURLIsRegularFileKey error:NULL];
            [file getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:NULL];
            if (!regular.boolValue || link.boolValue) continue;
            NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:file error:NULL];
            NSData *prefix = [handle readDataUpToLength:4 error:NULL];
            [handle closeAndReturnError:NULL];
            if (prefix.length != 4) continue;
            uint32_t magic = 0;
            [prefix getBytes:&magic length:4];
            if (magic != 0xfeedfacf && magic != 0xcffaedfe && magic != 0xcafebabe && magic != 0xbebafeca) continue;
            NSDictionary *child = BeeSaveCodeInformation(file);
            NSDictionary *rights = child[(__bridge NSString *)kSecCodeInfoEntitlementsDict];
            if (![team isEqualToString:child[(__bridge NSString *)kSecCodeInfoTeamIdentifier]] ||
                ([child[(__bridge NSString *)kSecCodeInfoFlags] unsignedIntValue] & 0x10000) == 0 ||
                [rights[@"com.apple.security.cs.disable-library-validation"] boolValue] ||
                [rights[@"com.apple.security.get-task-allow"] boolValue]) { valid = NO; break; }
        }
    }
    if (!valid && error) *error = [NSError errorWithDomain:@"BeeSave.UpdatePackage" code:1 userInfo:@{NSLocalizedDescriptionKey:@"The update package does not match BeeSave's signed identity, version, architecture, key or entitlements."}];
    return valid;
}
