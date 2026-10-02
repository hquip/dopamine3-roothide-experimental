#pragma once
#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <sys/stat.h>
#include <unistd.h>

// Keep the displayed output bounded, but inspect every diagnostic byte. The
// pinned uicache can emit Error: and still return zero.
typedef struct {
    BOOL lineStart;
    BOOL reportedError;
    unsigned matched;
    unsigned continuation;
    uint32_t scalar;
    uint32_t minimumScalar;
} DOHelperDiagnosticScanner;

static inline void DOHelperDiagnosticScalar(DOHelperDiagnosticScanner *scanner, uint32_t scalar)
{
    if ([[NSCharacterSet newlineCharacterSet] longCharacterIsMember:scalar]) {
        scanner->lineStart = YES;
        scanner->matched = 0;
        return;
    }
    if (!scanner->lineStart) return;
    if (!scanner->matched && [[NSCharacterSet whitespaceCharacterSet] longCharacterIsMember:scalar]) return;
    if (scalar == (unsigned char)"Error:"[scanner->matched]) {
        if (++scanner->matched == 6) {
            scanner->reportedError = YES;
            scanner->lineStart = NO;
        }
    }
    else scanner->lineStart = NO;
}

static inline void DOScanHelperDiagnosticByte(DOHelperDiagnosticScanner *scanner, unsigned char byte)
{
    if (scanner->continuation) {
        if ((byte & 0xc0) == 0x80) {
            scanner->scalar = (scanner->scalar << 6) | (byte & 0x3f);
            if (--scanner->continuation == 0) {
                uint32_t scalar = scanner->scalar;
                if (scalar < scanner->minimumScalar || scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff)) scalar = 0xfffd;
                DOHelperDiagnosticScalar(scanner, scalar);
            }
            return;
        }
        // A malformed sequence must not discard a following ASCII newline.
        scanner->continuation = 0;
        DOHelperDiagnosticScalar(scanner, 0xfffd);
    }
    if (byte < 0x80) DOHelperDiagnosticScalar(scanner, byte);
    else if (byte >= 0xc2 && byte <= 0xdf) {
        scanner->scalar = byte & 0x1f;
        scanner->minimumScalar = 0x80;
        scanner->continuation = 1;
    }
    else if (byte >= 0xe0 && byte <= 0xef) {
        scanner->scalar = byte & 0x0f;
        scanner->minimumScalar = 0x800;
        scanner->continuation = 2;
    }
    else if (byte >= 0xf0 && byte <= 0xf4) {
        scanner->scalar = byte & 7;
        scanner->minimumScalar = 0x10000;
        scanner->continuation = 3;
    }
    else DOHelperDiagnosticScalar(scanner, 0xfffd);
}

static inline int DOCreateHelperDiagnosticFile(NSString *path)
{
    if (!path.length) return EINVAL;
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) return errno;
    if (close(fd) == 0) return 0;
    int error = errno;
    unlink(path.fileSystemRepresentation);
    return error;
}

// The descriptor remains owned by the caller. Keeping the actual read loop
// here also permits testing I/O errors after a successful open/fstat.
static inline int DOReadHelperDiagnosticDescriptor(int fd, NSUInteger displayLimit, NSString **output, BOOL *reportedError)
{
    if (output) *output = nil;
    if (reportedError) *reportedError = NO;
    int error = 0;
    struct stat initial;
    if (fstat(fd, &initial) != 0) error = errno;
    else if (!S_ISREG(initial.st_mode) || initial.st_size < 0) error = EINVAL;
    NSMutableData *display = [NSMutableData data];
    NSMutableData *errorLine = [NSMutableData data];
    BOOL captureErrorLine = NO;
    DOHelperDiagnosticScanner scanner = { .lineStart = YES };
    off_t remaining = error ? 0 : initial.st_size;
    while (!error && remaining > 0) {
        unsigned char buffer[4096];
        size_t requested = remaining < (off_t)sizeof(buffer) ? (size_t)remaining : sizeof(buffer);
        ssize_t count = read(fd, buffer, requested);
        if (count < 0) {
            if (errno == EINTR) continue;
            error = errno;
            break;
        }
        if (!count) { error = EIO; break; }
        remaining -= count;
        NSUInteger copied = MIN((NSUInteger)count, displayLimit - display.length);
        if (copied) [display appendBytes:buffer length:copied];
        for (ssize_t i = 0; i < count; i++) {
            BOOL hadError = scanner.reportedError;
            DOScanHelperDiagnosticByte(&scanner, buffer[i]);
            if (!hadError && scanner.reportedError) {
                [errorLine appendBytes:"Error:" length:MIN((NSUInteger)6, displayLimit)];
                captureErrorLine = YES;
            }
            else if (captureErrorLine) {
                if (errorLine.length < displayLimit) [errorLine appendBytes:&buffer[i] length:1];
                if (scanner.lineStart) captureErrorLine = NO;
            }
        }
    }
    // Do not accept incomplete output from a helper that is still writing.
    struct stat final;
    if (!error && fstat(fd, &final) != 0) error = errno;
    else if (!error && final.st_size != initial.st_size) error = EAGAIN;
    if (error) return error;

    // An error beyond the display prefix must retain its own explanation,
    // rather than returning a long successful preamble as the failure detail.
    if (scanner.reportedError) display = errorLine;

    // If the display limit splits UTF-8, drop only that unfinished scalar. A
    // read-buffer boundary never affects the scanner's independent state.
    NSUInteger length = display.length;
    if (length) {
        const unsigned char *bytes = display.bytes;
        NSUInteger start = length - 1;
        while (start > 0 && (bytes[start] & 0xc0) == 0x80) start--;
        unsigned char lead = bytes[start];
        NSUInteger width = lead >= 0xc2 && lead <= 0xdf ? 2 : lead >= 0xe0 && lead <= 0xef ? 3 : lead >= 0xf0 && lead <= 0xf4 ? 4 : 1;
        if (length - start < width) length = start;
    }
    NSString *text = [[NSString alloc] initWithBytes:display.bytes length:length encoding:NSUTF8StringEncoding];
    if (!text) text = [[NSString alloc] initWithBytes:display.bytes length:length encoding:NSISOLatin1StringEncoding];
    if (output) *output = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    if (reportedError) *reportedError = scanner.reportedError;
    return 0;
}

static inline int DOReadHelperDiagnosticFile(NSString *path, NSUInteger displayLimit, NSString **output, BOOL *reportedError)
{
    if (output) *output = nil;
    if (reportedError) *reportedError = NO;
    if (!path.length) return EINVAL;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return errno;
    int error = DOReadHelperDiagnosticDescriptor(fd, displayLimit, output, reportedError);
    if (close(fd) != 0 && !error) {
        error = errno;
        if (output) *output = nil;
        if (reportedError) *reportedError = NO;
    }
    return error;
}
