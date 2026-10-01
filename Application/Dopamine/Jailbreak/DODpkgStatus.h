#import <Foundation/Foundation.h>

// A package name must match the whole field, and an unpacked/configuration-
// failed record is not an installed package. dpkg's database can retain both.
static inline NSDictionary<NSString *, NSString *> *DODpkgInstalledRecord(NSString *status, NSString *identifier)
{
    if (!status.length || !identifier.length) return nil;
    status = [status stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    for (NSString *paragraph in [status componentsSeparatedByString:@"\n\n"]) {
        NSMutableDictionary *fields = [NSMutableDictionary dictionary];
        for (NSString *line in [paragraph componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@" "] || [line hasPrefix:@"\t"]) continue;
            NSRange colon = [line rangeOfString:@":"];
            if (colon.location == NSNotFound) continue;
            NSString *key = [line substringToIndex:colon.location];
            NSString *value = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            fields[key] = value;
        }
        if ([fields[@"Package"] isEqualToString:identifier] &&
            [fields[@"Status"] isEqualToString:@"install ok installed"] &&
            [fields[@"Version"] length]) {
            return fields;
        }
    }
    return nil;
}
