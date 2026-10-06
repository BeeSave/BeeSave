#import <Foundation/Foundation.h>
#import "BeeSavePackagePolicy.h"
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc != 6) return 2;
    NSURL *incoming = [NSURL fileURLWithPath:@(argv[1])];
    NSURL *previous = [NSURL fileURLWithPath:@(argv[2])];
    NSError *error = nil;
    BOOL actual = BeeSaveValidatePackage(incoming, previous, @"6", @"1.2.0", &error);
    BOOL expected = [@(argv[3]) isEqualToString:@"accept"];
    if (actual != expected) {
        fprintf(stderr, "%s: expected %s, got %s (%s)\n", argv[4], argv[3], actual ? "accept" : "reject", error.description.UTF8String);
        return 1;
    }
    fprintf(stdout, "%s: %s\n", argv[4], actual ? "accept" : "reject");
    return 0;
} }
