#import <Foundation/Foundation.h>
#import "../Application/Dopamine/Jailbreak/DODpkgStatus.h"

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
        NSString *status = @"Package: org.coolstar.sileo-extra\nStatus: install ok installed\nVersion: 99\n\n"
            "Package: org.coolstar.sileo\nStatus: install ok unpacked\nVersion: 2.5.1-12\n\n"
            "Package: com.roothide.manager\nStatus: install ok installed\nVersion: 1.3.9\nDescription: manager\n Package: xyz.willy.Zebra\n";
        check(DODpkgInstalledRecord(status, @"org.coolstar.sileo") == nil, "unpacked package is not installed; prefix match is insufficient");
        check(DODpkgInstalledRecord(status, @"xyz.willy.Zebra") == nil, "continuation field must not create a package record");
        check([DODpkgInstalledRecord(status, @"com.roothide.manager")[@"Version"] isEqual:@"1.3.9"], "exact installed package is found");
        check(DODpkgInstalledRecord(@"Package: a\nVersion: 1\n", @"a") == nil, "missing Status must not produce false success");
        check(DODpkgInstalledRecord(@"Package: a\nStatus: install ok installed\n", @"a") == nil, "missing Version is not a complete installed record");
        check(DODpkgInstalledRecord(@"Package: a\nStatus: deinstall ok config-files\nVersion: 1\n", @"a") == nil, "removed package records must not imply app presence");
        check([DODpkgInstalledRecord(@"Package: xyz.willy.zebra\r\nVersion: 1.1.36-2-1+debug\r\nStatus: install ok installed\r\n", @"xyz.willy.zebra")[@"Version"] isEqual:@"1.1.36-2-1+debug"], "field order and CRLF database are supported");
        check(DODpkgInstalledRecord(nil, @"a") == nil && DODpkgInstalledRecord(status, @"") == nil, "unreadable or empty inputs fail closed");
        puts("dpkg installed-state parser: PASS");
    }
    return 0;
}
