#pragma once
#import <Foundation/Foundation.h>

// RootHide's uicache applies jbroot() to every -p argument. Pass a path in
// that virtual filesystem, never an already expanded physical jailbreak root.
static inline NSString *DOVirtualBundledAppPath(NSString *appName)
{
    if (![appName isKindOfClass:[NSString class]] || appName.length <= 4 ||
        ![appName hasSuffix:@".app"] || [appName hasPrefix:@"."] ||
        [appName containsString:@"/"] || [appName containsString:@"\\"] ||
        [appName rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound) return nil;
    return [@"/Applications" stringByAppendingPathComponent:appName];
}

// Compare LS paths without touching the filesystem as mobile. Only the
// expected path is resolved under root beforehand. /var and /private/var are
// aliases on iOS; do not normalize an arbitrary /private prefix away.
static inline NSString *DOCanonicalRegistrationPath(NSString *path)
{
    if (![path isKindOfClass:[NSString class]] || ![path hasPrefix:@"/"] ||
        [path rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound) return nil;
    NSMutableArray<NSString *> *components = [NSMutableArray array];
    for (NSString *component in [path componentsSeparatedByString:@"/"]) {
        if (!component.length || [component isEqualToString:@"."]) continue;
        if ([component isEqualToString:@".."]) return nil;
        [components addObject:component];
    }
    if (components.count >= 2 && [components[0] isEqualToString:@"private"] &&
        [components[1] isEqualToString:@"var"]) [components removeObjectAtIndex:0];
    if (!components.count) return nil;
    return [@"/" stringByAppendingString:[components componentsJoinedByString:@"/"]];
}

static inline BOOL DORegistrationPathMatches(NSString *registeredPath, NSString *expectedPath)
{
    NSString *registered = DOCanonicalRegistrationPath(registeredPath);
    NSString *expected = DOCanonicalRegistrationPath(expectedPath);
    return registered && expected && [registered isEqualToString:expected];
}

// The bundled uicache 2.1.6-4 reports parse/registration failures on stderr
// but still exits zero. An existing LS proxy must not hide that failure.
static inline BOOL DOUICacheRegistrationFailed(NSInteger status, NSString *diagnostic)
{
    if (status != 0) return YES;
    for (NSString *line in [diagnostic componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed hasPrefix:@"Error:"]) return YES;
    }
    return NO;
}
