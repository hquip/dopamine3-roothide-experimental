#import <Foundation/Foundation.h>
#import "../Application/Dopamine/Jailbreak/DOAppRegistration.h"
#import "../Application/Dopamine/Jailbreak/DOHelperDiagnostics.h"

static void check(BOOL condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static NSString *checkDiagnostic(NSData *data, NSUInteger limit, BOOL expectedError)
{
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    check(DOCreateHelperDiagnosticFile(path) == 0, "create diagnostic fixture");
    check([data writeToFile:path atomically:NO], "write diagnostic fixture");
    NSString *output = nil;
    BOOL reportedError = !expectedError;
    int error = DOReadHelperDiagnosticFile(path, limit, &output, &reportedError);
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    check(error == 0 && reportedError == expectedError, "inspect complete diagnostic stream");
    check(output != nil && [output lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= limit, "display stays within byte limit for UTF-8 fixtures");
    return output;
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

        NSString *missing = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
        NSString *output = @"stale";
        BOOL reportedError = YES;
        check(DOCreateHelperDiagnosticFile([missing stringByAppendingPathComponent:@"stderr"]) == ENOENT, "capture creation failure is explicit");
        check(DOReadHelperDiagnosticFile(missing, 8192, &output, &reportedError) == ENOENT && output == nil && !reportedError, "missing diagnostic output fails instead of retaining success");
        check(DOReadHelperDiagnosticFile(NSTemporaryDirectory(), 8192, &output, &reportedError) != 0, "unreadable diagnostic stream fails");
        check(DOCreateHelperDiagnosticFile(missing) == 0, "create protected existing fixture");
        check([@"preserve" writeToFile:missing atomically:NO encoding:NSUTF8StringEncoding error:nil], "populate existing fixture");
        check(DOCreateHelperDiagnosticFile(missing) == EEXIST && [[NSString stringWithContentsOfFile:missing encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"preserve"], "capture creation cannot truncate an existing file");
        int writeOnly = open(missing.fileSystemRepresentation, O_WRONLY | O_CLOEXEC);
        check(writeOnly >= 0, "open write-only fixture for an actual read failure");
        output = @"stale";
        reportedError = YES;
        check(DOReadHelperDiagnosticDescriptor(writeOnly, 8192, &output, &reportedError) == EBADF && output == nil && !reportedError, "read failure after successful fstat cannot become an empty successful diagnostic");
        close(writeOnly);
        [[NSFileManager defaultManager] removeItemAtPath:missing error:nil];

        check([checkDiagnostic([NSData data], 8192, NO) isEqualToString:@""], "empty completed output is valid");
        NSString *longNotice = [[@"notice\n" stringByPaddingToLength:12000 withString:@"notice\n" startingAtIndex:0] stringByAppendingString:@"\nError: registration failed after the display limit\nignored tail"];
        output = checkDiagnostic([longNotice dataUsingEncoding:NSUTF8StringEncoding], 8192, YES);
        check([output isEqualToString:@"Error: registration failed after the display limit"], "late error keeps its explanation instead of the truncated preamble");
        NSString *longIndent = [[@"" stringByPaddingToLength:20000 withString:@" " startingAtIndex:0] stringByAppendingString:@"Error: after long indentation"];
        check([checkDiagnostic([longIndent dataUsingEncoding:NSUTF8StringEncoding], 8192, YES) isEqualToString:@"Error: after long indentation"], "long whitespace does not hide a zero-exit error");
        NSString *longBenign = [[@"notice: " stringByPaddingToLength:20000 withString:@"x" startingAtIndex:0] stringByAppendingString:@"Error: quoted, not a new error line"];
        checkDiagnostic([longBenign dataUsingEncoding:NSUTF8StringEncoding], 8192, NO);
        NSString *longError = [@"Error: " stringByPaddingToLength:20000 withString:@"x" startingAtIndex:0];
        check([checkDiagnostic([longError dataUsingEncoding:NSUTF8StringEncoding], 8192, YES) length] == 8192, "a very long error line has bounded storage");
        for (NSUInteger padding = 4094; padding <= 4095; padding++) {
            NSString *splitUTF8 = [[@"" stringByPaddingToLength:padding withString:@" " startingAtIndex:0] stringByAppendingString:@"\u3000Error: Unicode indentation crosses a read boundary"];
            check([checkDiagnostic([splitUTF8 dataUsingEncoding:NSUTF8StringEncoding], 8192, YES) hasPrefix:@"Error:"], "Unicode indentation survives split UTF-8 reads");
        }
        NSString *splitPrefix = [[@"" stringByPaddingToLength:4094 withString:@" " startingAtIndex:0] stringByAppendingString:@"Error: token crosses a read boundary"];
        checkDiagnostic([splitPrefix dataUsingEncoding:NSUTF8StringEncoding], 8192, YES);
        NSString *splitNewline = [[@"x" stringByPaddingToLength:8191 withString:@"x" startingAtIndex:0] stringByAppendingString:@"\u2028Error: Unicode newline crosses a read boundary"];
        checkDiagnostic([splitNewline dataUsingEncoding:NSUTF8StringEncoding], 8192, YES);
        NSString *displayUTF8 = [[@"x" stringByPaddingToLength:8191 withString:@"x" startingAtIndex:0] stringByAppendingString:@"汉 tail"];
        output = checkDiagnostic([displayUTF8 dataUsingEncoding:NSUTF8StringEncoding], 8192, NO);
        check(output.length == 8191 && [output hasSuffix:@"x"], "display truncation drops an incomplete UTF-8 scalar without mojibake");
        unsigned char malformed[] = { 0xe3, 0x80, '\n', 'E', 'r', 'r', 'o', 'r', ':', ' ', 'x' };
        check([checkDiagnostic([NSData dataWithBytes:malformed length:sizeof(malformed)], 8192, YES) isEqualToString:@"Error: x"], "malformed UTF-8 cannot swallow a following error line");

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
