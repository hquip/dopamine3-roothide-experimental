#import <Foundation/Foundation.h>
#import "../Application/Dopamine/Jailbreak/DOAppRegistration.h"

static void check(BOOL condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

int main(void)
{
    @autoreleasepool {
        NSString *physicalRoot = @"/var/containers/Bundle/Application/.jbroot-0123456789abcdef";
        for (NSString *app in @[@"RootHide.app", @"Sileo.app", @"Zebra.app"]) {
            NSString *virtualPath = DOVirtualBundledAppPath(app);
            check([virtualPath isEqualToString:[@"/Applications/" stringByAppendingString:app]], "uicache receives the virtual app path");
            NSString *expandedOnce = [physicalRoot stringByAppendingString:virtualPath];
            check([expandedOnce isEqualToString:[[physicalRoot stringByAppendingPathComponent:@"Applications"] stringByAppendingPathComponent:app]], "one jbroot expansion reaches the expected physical app");
            check([DOVirtualBundledAppPath(expandedOnce) length] == 0, "an already expanded path cannot become a uicache argument");
        }
        for (NSString *invalid in @[@"", @".app", @"../Sileo.app", @"/Applications/Sileo.app", @"Applications\\Sileo.app", @"Sileo", @"Sileo.app\n"]) {
            check(DOVirtualBundledAppPath(invalid) == nil, "invalid app names fail closed");
        }
        check(DOVirtualBundledAppPath(nil) == nil, "missing app name fails closed");

        check(DOUICacheRegistrationFailed(0, @"Error: Unable to parse app /nested/Sileo.app"), "zero-exit parse failure is an error");
        check(DOUICacheRegistrationFailed(0, @"notice\r\n\tError: Unable to register /Applications/Sileo.app\r\n"), "multiline zero-exit registration failure is an error");
        check(DOUICacheRegistrationFailed(0, @"Error: Unable to find bundle"), "other pinned Error diagnostics fail closed");
        check(DOUICacheRegistrationFailed(7, nil) && DOUICacheRegistrationFailed(-5, @""), "nonzero helper status remains a failure without stderr");
        check(!DOUICacheRegistrationFailed(0, nil) && !DOUICacheRegistrationFailed(0, @""), "empty successful diagnostics remain successful");
        check(!DOUICacheRegistrationFailed(0, @"Warning: using existing registration\nnotice: Error: mentioned in a message"), "benign stderr is preserved without becoming a reported uicache error");

        NSString *expected = [physicalRoot stringByAppendingPathComponent:@"Applications/Sileo.app"];
        check(DORegistrationPathMatches([@"/private" stringByAppendingString:expected], expected), "private var and var aliases match without filesystem reads");
        check(DORegistrationPathMatches([expected stringByAppendingString:@"/"], expected), "trailing path separators do not change identity");
        check(DORegistrationPathMatches([physicalRoot stringByAppendingString:@"//Applications/./Sileo.app"], expected), "lexical dot and duplicate slash normalization is supported");
        check(!DORegistrationPathMatches([physicalRoot stringByAppendingPathComponent:@"Applications/Zebra.app"], expected), "a different application does not match");
        check(!DORegistrationPathMatches(@"/var/containers/Bundle/Application/.jbroot-old/Applications/Sileo.app", expected), "a stale jailbreak root does not match");
        check(!DORegistrationPathMatches(@"/private/Applications/Sileo.app", @"/Applications/Sileo.app"), "only the documented private var alias is normalized");
        for (NSString *invalid in @[@"", @"/", @"Applications/Sileo.app", @"/var/../Applications/Sileo.app", @"/var/Applications/Sileo.app\n"]) {
            check(DOCanonicalRegistrationPath(invalid) == nil, "invalid registration paths fail closed");
        }
        check(!DORegistrationPathMatches(nil, expected) && !DORegistrationPathMatches(expected, nil), "missing registered or expected paths do not match");
        puts("RootHide app registration contracts: PASS");
    }
    return 0;
}
