//
//  EnvironmentManager.m
//  Dopamine
//
//  Created by Lars Fröder on 10.01.24.
//

#import "DOEnvironmentManager.h"
#import "DOAppRegistration.h"
#import "DOHelperDiagnostics.h"
#import "UIImage+JPEG2000.h"

#import <sys/sysctl.h>
#import <sys/mount.h>
#import <sys/utsname.h>
#import <sys/stat.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <signal.h>
#import <sys/wait.h>
#import <time.h>
#import <CoreServices/LSApplicationProxy.h>
#import <mach-o/dyld.h>
#import <libgrabkernel2/libgrabkernel2.h>
#import <libjailbreak/info.h>
#import <libjailbreak/codesign.h>
#import <libjailbreak/util.h>
#import <libjailbreak/display.h>
#import <libjailbreak/machine_info.h>
#import <libjailbreak/carboncopy.h>

#import <IOKit/IOKitLib.h>
#import "DOUIManager.h"
#import "DOExploitManager.h"
#import "DOPreferenceManager.h"
#import "NSData+Hex.h"
#import <LocalAuthentication/LocalAuthentication.h>

int reboot3(uint64_t flags, ...);
CFPropertyListRef MGCopyAnswer(CFStringRef);
extern char **environ;

static NSRecursiveLock *DOPrivilegeLock(void)
{
    static NSRecursiveLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSRecursiveLock new]; });
    return lock;
}

static NSLock *DOAppRecoveryLock(void)
{
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    return lock;
}

// A failed cleanup must not silently allow another operation to reuse leaked
// credentials. Restarting the app is required before it can try again.
static BOOL DOPrivilegeCleanupFailed = NO;

static NSError *DORecoveryError(NSString *stage, NSInteger code, NSString *detail)
{
    NSString *message = [NSString stringWithFormat:@"%@: %@ (%ld)", stage, detail, (long)code];
    [[DOUIManager sharedInstance] sendLog:message debug:NO];
    return [NSError errorWithDomain:bootstrapErrorDomain code:code ?: -1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *DOValidRootPath(void)
{
    const char *root = jbinfo(rootPath);
    if (!root || !root[0] || root[0] != '/') return nil;
    NSString *path = [[NSString stringWithUTF8String:root] stringByStandardizingPath];
    // Never let an empty/stale root resolve recovery commands into stock iOS.
    if (!path.length || [path isEqualToString:@"/"] || ![path.lastPathComponent hasPrefix:@".jbroot-"]) return nil;
    return path;
}

static double DOMonotonicTime(void)
{
    struct timespec time;
    if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) return -1;
    return time.tv_sec + time.tv_nsec / 1000000000.0;
}

static int DOHelperExitStatus(int status)
{
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -EIO;
}

@interface DOEnvironmentManager ()
- (void)refreshJailbreakRootIfNeeded;
- (NSError *)validateRecoveryEnvironment;
- (NSError *)registerBundledApps:(NSArray<NSDictionary<NSString *, NSString *> *> *)apps;
- (int)waitForSpawnedHelper:(pid_t)pid timeout:(NSTimeInterval)timeout processGroup:(BOOL)processGroup;
@end

@implementation DOEnvironmentManager

+ (instancetype)sharedManager
{
    static DOEnvironmentManager *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[DOEnvironmentManager alloc] init];
    });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _bootstrapNeedsMigration = NO;
        _bootstrapper = [[DOBootstrapper alloc] init];
        if ([self isJailbroken]) {
            const char *root = jbclient_get_jbroot();
            if (root && root[0] == '/' && root[1]) {
                gSystemInfo.jailbreakInfo.rootPath = strdup(root);
            }
        }
        else if ([self isInstalledThroughTrollStore]) {
            [self locateJailbreakRoot];
        }
    }
    return self;
}

- (NSString *)nightlyHash
{
#ifdef NIGHTLY
    return [NSString stringWithUTF8String:COMMIT_HASH];
#else
    return nil;
#endif
}

- (NSString *)appVersion
{
    return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
}

- (NSString *)appVersionDisplayString
{
    NSString *portVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"DORootHidePortVersion"] ?: self.appVersion;
    NSString *nightlyHash = [self nightlyHash];
    if (nightlyHash.length >= 6) {
        portVersion = [portVersion stringByAppendingFormat:@"~%@", [nightlyHash substringToIndex:6]];
    }
    return [NSString stringWithFormat:@"%@ (%@)", portVersion, DOLocalizedString(@"Experimental_RootHide_Port")];
}

- (NSString *)privatePrebootPath
{
    return @"/private/preboot";
}

- (NSString *)activePrebootPath
{
    NSString *bootManifestString = [NSString stringWithUTF8String:boot_manifest_hash()];
    return [[self privatePrebootPath] stringByAppendingPathComponent:bootManifestString];
}


- (BOOL)isArm64e
{
    cpu_subtype_t cpusubtype = 0;
    size_t len = sizeof(cpusubtype);
    if (sysctlbyname("hw.cpusubtype", &cpusubtype, &len, NULL, 0) == -1) return NO;
    return (cpusubtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E;
}

- (BOOL)isSPTM
{
    if (@available(iOS 17.0, *)) {
        io_registry_entry_t memory_map = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen/memory-map");
        if (memory_map == IO_OBJECT_NULL)   return NO;

        CFArrayRef keys = (CFArrayRef)IORegistryEntryCreateCFProperty(memory_map, CFSTR(kIORegistryEntryPropertyKeysKey), kCFAllocatorDefault, 0);
        IOObjectRelease(memory_map);
        if (!keys)  return NO;

        CFRange range = CFRangeMake(0, CFArrayGetCount(keys));

        bool isSPTM = CFArrayContainsValue(keys, range, CFSTR("SPTM")) && CFArrayContainsValue(keys, range, CFSTR("TXM"));
        CFRelease(keys);

        return isSPTM;
    }
    return false;
}

- (NSString *)versionSupportString
{
    cpu_subtype_t cpuFamily = 0;
    size_t cpuFamilySize = sizeof(cpuFamily);
    sysctlbyname("hw.cpufamily", &cpuFamily, &cpuFamilySize, NULL, 0);

    if ([self isArm64e]) {
        if (cpuFamily == CPUFAMILY_ARM_VORTEX_TEMPEST || cpuFamily == CPUFAMILY_ARM_LIGHTNING_THUNDER) {
            return @"iOS 15.0 - 18.7.1, 26.0 - 26.0.1 (A12/A13, PPL)";
        }
        else if (![self isSPTM]) {
            return @"iOS 15.0 - 17.3.1 (PPL)";
        }
        else {
            return @"iOS 17.0 - 17.3.1 (SPTM)";
        }
    }
    else {
        return @"iOS 15.0 - 18.7.1 (arm64)";
    }
}

- (BOOL)isInstalledThroughTrollStore
{
    static BOOL trollstoreInstallation = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString* trollStoreMarkerPath = [[[NSBundle mainBundle].bundlePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"_TrollStore"];
        trollstoreInstallation = [[NSFileManager defaultManager] fileExistsAtPath:trollStoreMarkerPath];
    });
    return trollstoreInstallation;
}

- (void)updateJailbreakState
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        char *jbVersionC = NULL;
        _isJailbroken = jbclient_dopamine_is_jailbroken(&jbVersionC) && jbclient_roothide_jailbroken();
        if (jbVersionC) {
            _jailbrokenVersion = [NSString stringWithUTF8String:jbVersionC];
            free(jbVersionC);
        }
    });
}

- (BOOL)isJailbroken
{
    [self updateJailbreakState];
    return _isJailbroken;
}

- (void)setJailbroken:(BOOL)jailbroken withVersion:(NSString *)version
{
    _isJailbroken = jailbroken;
    _jailbrokenVersion = _isJailbroken ? [version copy] : nil;
}

- (BOOL)isJailbrokenWithOtherJailbreak
{
    if (![self isJailbroken]) {
        uint32_t csFlags = 0;
        csops(getpid(), CS_OPS_STATUS, &csFlags, sizeof(csFlags));

        // Palera1n
        if (csFlags & CS_PLATFORM_BINARY) return YES;

        // Older Dopamine build
        if (!access("/usr/lib/systemhook.dylib", F_OK)) return YES;
    }
    return NO;
}

- (NSString *)jailbrokenVersion
{
    [self updateJailbreakState];
    if (!_isJailbroken) return nil;
    return _jailbrokenVersion;
}

- (NSString *)systemVersion
{
    return (__bridge NSString *)MGCopyAnswer((__bridge CFStringRef)@"ProductVersion");
}

- (BOOL)isBootstrapped
{
    [self refreshJailbreakRootIfNeeded];
    if (!DOValidRootPath()) return NO;
    __block BOOL valid = NO;
    void (^check)(void) = ^{
        NSString *root = DOValidRootPath();
        BOOL directory = NO;
        NSFileManager *fm = [NSFileManager defaultManager];
        valid = root && [fm fileExistsAtPath:root isDirectory:&directory] && directory &&
            [fm fileExistsAtPath:[root stringByAppendingPathComponent:@".installed_dopamine"]] &&
            [fm isExecutableFileAtPath:[root stringByAppendingPathComponent:@"basebin/jbctl"]] &&
            [fm isExecutableFileAtPath:[root stringByAppendingPathComponent:@"usr/bin/dpkg"]] &&
            [fm isReadableFileAtPath:[root stringByAppendingPathComponent:@"var/lib/dpkg/status"]];
    };
    // TrollStore can inspect an inactive environment without elevation.
    if ([self isInstalledThroughTrollStore]) {
        return [self runUnsandboxedChecked:check] == nil && valid;
    }
    if (![self isJailbroken] && geteuid() != 0) return NO;
    __block NSError *sandboxError = nil;
    NSError *rootError = [self runAsRootChecked:^{ sandboxError = [self runUnsandboxedChecked:check]; }];
    return !rootError && !sandboxError && valid;
}

- (void)refreshJailbreakRootIfNeeded
{
    if (jbinfo(rootPath) && jbinfo(rootPath)[0]) return;
    if (![self isJailbroken]) return;
    NSRecursiveLock *lock = DOPrivilegeLock();
    [lock lock];
    @try {
        if (!jbinfo(rootPath) || !jbinfo(rootPath)[0]) {
            const char *root = jbclient_get_jbroot();
            if (root && root[0] == '/' && root[1]) {
                // Publish only a successful lookup. Do not free a path that
                // concurrent C callers could still be reading.
                gSystemInfo.jailbreakInfo.rootPath = strdup(root);
            }
        }
    }
    @finally { [lock unlock]; }
}

- (void)runUnsandboxed:(void (^)(void))unsandboxBlock
{
    [self runUnsandboxedChecked:unsandboxBlock];
}

- (void)runAsRoot:(void (^)(void))rootBlock
{
    [self runAsRootChecked:rootBlock];
}

- (NSError *)runUnsandboxedChecked:(void (^)(void))unsandboxBlock
{
    NSRecursiveLock *lock = DOPrivilegeLock();
    [lock lock];
    NSError *error = nil;
    BOOL changedLabel = NO;
    uint64_t labelBackup = 0;
    @try {
        if (DOPrivilegeCleanupFailed) {
            error = DORecoveryError(@"Sandbox", -EPERM, @"Previous credential cleanup failed; close and reopen Dopamine.");
        }
        else if ([self isInstalledThroughTrollStore] || (![self isJailbroken] && geteuid() == 0)) {
            unsandboxBlock();
        }
        else if (![self isJailbroken]) {
            error = DORecoveryError(@"Sandbox", -ENOTCONN, @"The jailbreak service is unavailable.");
        }
        else {
            int result = jbclient_root_set_mac_label(1, -1, &labelBackup);
            if (result != 0) error = DORecoveryError(@"Sandbox", result, @"Could not obtain filesystem access.");
            else {
                changedLabel = YES;
                unsandboxBlock();
            }
        }
    }
    @finally {
        if (changedLabel) {
            int result = jbclient_root_set_mac_label(1, labelBackup, NULL);
            if (result != 0) {
                DOPrivilegeCleanupFailed = YES;
                error = DORecoveryError(@"Sandbox cleanup", result, @"Could not restore the sandbox label; close and reopen Dopamine.");
            }
        }
        [lock unlock];
    }
    return error;
}

- (NSError *)runAsRootChecked:(void (^)(void))rootBlock
{
    NSRecursiveLock *lock = DOPrivilegeLock();
    [lock lock];
    NSError *error = nil;
    uid_t originalUser = geteuid();
    gid_t originalGroup = getegid();
    BOOL obtainedRoot = NO;
    @try {
        if (DOPrivilegeCleanupFailed) {
            error = DORecoveryError(@"Privilege", -EPERM, @"Previous credential cleanup failed; close and reopen Dopamine.");
        }
        else if (originalUser == 0 && originalGroup == 0) {
            rootBlock();
        }
        else if (![self isJailbroken]) {
            error = DORecoveryError(@"Privilege", -ENOTCONN, @"The jailbreak is not active.");
        }
        else {
            int result = jbclient_dopamine_get_root();
            obtainedRoot = (result == 0 || geteuid() != originalUser || getegid() != originalGroup);
            if (result != 0 || geteuid() != 0 || getegid() != 0) {
                error = DORecoveryError(@"Privilege", result ?: -EPERM, @"Could not obtain root credentials.");
            }
            else rootBlock();
        }
    }
    @finally {
        if (obtainedRoot) {
            int result = jbclient_dopamine_drop_root();
            if (result != 0 || geteuid() != originalUser || getegid() != originalGroup) {
                DOPrivilegeCleanupFailed = YES;
                error = DORecoveryError(@"Privilege cleanup", result ?: -EPERM, @"Could not restore credentials; close and reopen Dopamine.");
            }
        }
        [lock unlock];
    }
    return error;
}

- (int)spawnJbctlAsRootWithArgs:(NSArray<NSString *> *)args
{
    [[NSThread currentThread].threadDictionary removeObjectForKey:@"DOHelperDiagnostic"];
    [[NSThread currentThread].threadDictionary removeObjectForKey:@"DOHelperReportedError"];
    [self refreshJailbreakRootIfNeeded];
    NSString *root = DOValidRootPath();
    if (!root) return -ENOENT;
    BOOL legacy = self.jailbrokenVersion &&
        [self.jailbrokenVersion compare:@"3.0.5" options:NSNumericSearch] == NSOrderedAscending;
    BOOL recoveryGroup = args.count >= 2 && [args[0] isEqualToString:@"internal"] &&
        ([args[1] isEqualToString:@"install_pkg"] || [args[1] isEqualToString:@"run_tool"]);
    NSMutableArray<NSString *> *arguments __attribute__((objc_precise_lifetime)) = [NSMutableArray arrayWithObject:[root stringByAppendingPathComponent:@"basebin/jbctl"]];
    [arguments addObjectsFromArray:args];
    if (!legacy) [arguments addObjectsFromArray:@[@"--waitfor", @"3"]];
    char **argv = calloc(arguments.count + 1, sizeof(char *));
    if (!argv) return -ENOMEM;
    for (NSUInteger i = 0; i < arguments.count; i++) argv[i] = (char *)arguments[i].UTF8String;

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int result = posix_spawn_file_actions_init(&actions);
    if (result) { free(argv); return -result; }
    result = posix_spawnattr_init(&attributes);
    if (result) { posix_spawn_file_actions_destroy(&actions); free(argv); return -result; }
    short flags = (legacy ? POSIX_SPAWN_START_SUSPENDED : 0) | (recoveryGroup ? POSIX_SPAWN_SETPGROUP : 0);
    result = posix_spawnattr_setflags(&attributes, flags);
    if (!result && recoveryGroup) result = posix_spawnattr_setpgroup(&attributes, 0);
    NSString *diagnosticPath = nil;
    if (!result && recoveryGroup) {
        NSString *candidate = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"helper-%@.stderr", [NSUUID UUID].UUIDString]];
        // Create as the normal app user so diagnostics stay readable after
        // credential cleanup. Capture stderr without a pipe that could fill.
        result = DOCreateHelperDiagnosticFile(candidate);
        if (!result) {
            diagnosticPath = candidate;
            result = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, candidate.fileSystemRepresentation, O_WRONLY | O_TRUNC, 0600);
        }
        else {
            NSString *message = [NSString stringWithFormat:@"Cannot create helper diagnostic output: %s", strerror(result)];
            [NSThread currentThread].threadDictionary[@"DOHelperDiagnostic"] = message;
            [[DOUIManager sharedInstance] sendLog:message debug:NO];
        }
    }
    int waitPipe[2] = {-1, -1};
    if (!result && !legacy) {
        int originalPipe[2];
        if (pipe(originalPipe) != 0) result = errno;
        else {
            // Keep the source descriptors clear of fd 3, and never let the
            // helper inherit its own writer: EOF must mean cleanup failed.
            waitPipe[0] = fcntl(originalPipe[0], F_DUPFD_CLOEXEC, 4);
            if (waitPipe[0] < 0) result = errno;
            if (!result) {
                waitPipe[1] = fcntl(originalPipe[1], F_DUPFD_CLOEXEC, 4);
                if (waitPipe[1] < 0) result = errno;
            }
            close(originalPipe[0]);
            close(originalPipe[1]);
            if (!result) result = posix_spawn_file_actions_adddup2(&actions, waitPipe[0], 3);
            if (!result) result = posix_spawn_file_actions_addclose(&actions, waitPipe[0]);
            if (!result) result = posix_spawn_file_actions_addclose(&actions, waitPipe[1]);
#ifdef F_SETNOSIGPIPE
            if (!result && fcntl(waitPipe[1], F_SETNOSIGPIPE, 1) < 0) result = errno;
#endif
        }
    }

    __block pid_t pid = -1;
    __block int spawnResult = result;
    __block NSError *sandboxError = nil;
    NSError *privilegeError = nil;
    if (!result) {
        privilegeError = [self runAsRootChecked:^{
            sandboxError = [self runUnsandboxedChecked:^{
                spawnResult = posix_spawn(&pid, argv[0], &actions, &attributes, argv, environ);
            }];
        }];
    }
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    free(argv);

    // On iOS 17+ the requested action may run only after BOTH scopes have
    // completed successfully. Failure kills the waiting/suspended child.
    if (privilegeError || sandboxError) spawnResult = EPERM;
    if (!spawnResult && pid > 0) {
        if (legacy) {
            if (kill(pid, SIGCONT) != 0) spawnResult = errno;
        }
        else {
            char token = 'w';
            ssize_t written;
            do { written = write(waitPipe[1], &token, sizeof(token)); } while (written < 0 && errno == EINTR);
            if (written != sizeof(token)) spawnResult = written < 0 ? errno : EIO;
        }
    }
    if (waitPipe[0] >= 0) close(waitPipe[0]);
    if (waitPipe[1] >= 0) close(waitPipe[1]);
    if (spawnResult || pid <= 0) {
        if (pid > 0) {
            // A closed handshake pipe usually makes jbctl fail immediately.
            // Still bound cleanup, and never wait for pid 0 or an arbitrary PID.
            [self waitForSpawnedHelper:pid timeout:1 processGroup:recoveryGroup];
        }
        if (diagnosticPath) [[NSFileManager defaultManager] removeItemAtPath:diagnosticPath error:nil];
        return -(spawnResult ?: ECHILD);
    }
    int status = [self waitForSpawnedHelper:pid timeout:120 processGroup:recoveryGroup];
    if (diagnosticPath) {
        NSString *diagnostic = nil;
        BOOL reportedError = NO;
        int diagnosticError = DOReadHelperDiagnosticFile(diagnosticPath, 8192, &diagnostic, &reportedError);
        if (diagnosticError) {
            diagnostic = [NSString stringWithFormat:@"Cannot read complete helper diagnostic output: %s (helper status %d).", strerror(diagnosticError), status];
            status = -diagnosticError;
        }
        [NSThread currentThread].threadDictionary[@"DOHelperReportedError"] = @(reportedError);
        if (diagnostic.length) {
            [NSThread currentThread].threadDictionary[@"DOHelperDiagnostic"] = diagnostic;
            [[DOUIManager sharedInstance] sendLog:diagnostic debug:NO];
        }
        [[NSFileManager defaultManager] removeItemAtPath:diagnosticPath error:nil];
    }
    return status;
}

- (int)waitForSpawnedHelper:(pid_t)pid timeout:(NSTimeInterval)timeout processGroup:(BOOL)processGroup
{
    if (pid <= 0) return -EINVAL;
    double now = DOMonotonicTime();
    if (now < 0) return -errno;
    double deadline = now + timeout;
    int status = 0;
    for (;;) {
        pid_t result = waitpid(pid, &status, WNOHANG);
        if (result == pid && (WIFEXITED(status) || WIFSIGNALED(status))) return DOHelperExitStatus(status);
        if (result < 0 && errno != EINTR) return -errno;
        now = DOMonotonicTime();
        if (now < 0) return -errno;
        if (now >= deadline) break;
        usleep(20000);
    }

    __block int terminationError = 0;
    __block BOOL exited = NO;
    __block int exitStatus = 0;
    void (^terminate)(void) = ^{
        // A successful child-specific wait proves ownership. A child that
        // exits immediately afterwards remains a zombie until we reap it, so
        // its PID cannot be recycled into an unrelated process before kill.
        int childStatus = 0;
        pid_t result;
        do { result = waitpid(pid, &childStatus, WNOHANG); } while (result < 0 && errno == EINTR);
        if (result == pid && (WIFEXITED(childStatus) || WIFSIGNALED(childStatus))) { exited = YES; exitStatus = DOHelperExitStatus(childStatus); return; }
        if (result < 0) { terminationError = errno; return; }
        pid_t target = processGroup && getpgid(pid) == pid ? -pid : pid;
        terminationError = kill(target, SIGKILL) == 0 ? 0 : errno;
    };
    NSError *rootError = [self runAsRootChecked:terminate];
    // If privilege cleanup had already failed, try the caller's current
    // credentials too. An owned child may still have our real UID.
    if (rootError) terminate();
    if (exited) return exitStatus;
    if (terminationError && terminationError != ESRCH) {
        DORecoveryError(@"Helper timeout", -terminationError, @"The owned helper could not be terminated.");
        return -terminationError;
    }
    // Reap after SIGKILL, but never turn cleanup into another unlimited wait.
    deadline = DOMonotonicTime() + 5;
    BOOL reaped = NO;
    for (;;) {
        pid_t result = waitpid(pid, &status, WNOHANG);
        if ((result == pid && (WIFEXITED(status) || WIFSIGNALED(status))) || (result < 0 && errno == ECHILD)) { reaped = YES; break; }
        if (result < 0 && errno != EINTR) return -errno;
        now = DOMonotonicTime();
        if (now < 0 || now >= deadline) break;
        usleep(20000);
    }
    DORecoveryError(@"Helper timeout", -ETIMEDOUT, [NSString stringWithFormat:@"The helper exceeded %.0f seconds. %@", timeout, reaped ? @"It was terminated." : @"Termination was requested; exit was not observed."]);
    return -ETIMEDOUT;
}

- (int)runTrollStoreAction:(NSString *)action
{
    if (![self isInstalledThroughTrollStore]) return -1;

    uint32_t selfPathSize = PATH_MAX;
    char selfPath[selfPathSize];
    _NSGetExecutablePath(selfPath, &selfPathSize);
    return exec_cmd_root(selfPath, "trollstore", action.UTF8String, NULL);
}

- (void)respring
{
    [self spawnJbctlAsRootWithArgs:@[@"respring"]];
}

- (void)rebootUserspace
{
    [self spawnJbctlAsRootWithArgs:@[@"reboot_userspace"]];
}

- (NSError *)rebuildIconCache
{
    NSLock *lock = DOAppRecoveryLock();
    if (![lock tryLock]) return DORecoveryError(@"Rebuild icons", -EBUSY, @"Another app operation is already running.");
    NSError *error = nil;
    @try {
        if ([self isJailbroken]) error = [self validateRecoveryEnvironment];
        if (!error) {
            int status = [self spawnJbctlAsRootWithArgs:@[@"rebuild_icon_cache"]];
            if (status) error = DORecoveryError(@"Rebuild icons", status, @"The helper did not complete the database rebuild.");
        }
    }
    @finally { [lock unlock]; }
    return error;
}

- (NSError *)refreshJailbreakApps
{
    NSLock *lock = DOAppRecoveryLock();
    if (![lock tryLock]) return DORecoveryError(@"Refresh apps", -EBUSY, @"Another app operation is already running.");
    NSError *error = nil;
    @try {
        error = [self validateRecoveryEnvironment];
        if (!error) {
            for (NSDictionary *app in DOBundledJailbreakApps()) {
                error = [self->_bootstrapper verifyBundledApp:app];
                if (error) break;
            }
        }
        if (!error) error = [self registerBundledApps:DOBundledJailbreakApps()];
    }
    @finally { [lock unlock]; }
    return error;
}

- (void)unregisterJailbreakApps
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSArray *jailbreakApps = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:JBROOT_PATH(@"/Applications") error:nil];
            if (jailbreakApps.count) {
                for (NSString *jailbreakApp in jailbreakApps) {
                    NSString *jailbreakAppPath = [JBROOT_PATH(@"/Applications") stringByAppendingPathComponent:jailbreakApp];
                    exec_cmd(JBROOT_PATH("/usr/bin/uicache"), "-u", jailbreakAppPath.fileSystemRepresentation, NULL);
                }
            }
        }];
    }];
}

- (void)reboot
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            reboot3(0x8000000000000000, 0);
        }];
    }];
}


- (void)changeMobilePassword:(NSString *)newPassword
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSString *dashCommand = [NSString stringWithFormat:@"printf \"%%s\\n\" \"%@\" | %@ usermod 501 -h 0", newPassword, JBROOT_PATH(@"/usr/sbin/pw")];
            exec_cmd(JBROOT_PATH("/usr/bin/dash"), "-c", dashCommand.UTF8String, NULL);
        }];
    }];
}

- (NSError*)updateEnvironment
{
    NSString *newBasebinTarPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"basebin.tar"];
    int result = jbclient_platform_stage_jailbreak_update(newBasebinTarPath.fileSystemRepresentation);
    if (result == 0) {
        [self rebootUserspace];
        return nil;
    }
    return [NSError errorWithDomain:@"Dopamine" code:result userInfo:nil];
}

- (void)updateJailbreakFromTIPA:(NSString *)tipaPath
{
    [self spawnJbctlAsRootWithArgs:@[@"update", @"tipa", tipaPath]];
}

- (BOOL)isTweakInjectionEnabled
{
    return ![[NSFileManager defaultManager] fileExistsAtPath:JBROOT_PATH(@"/basebin/.safe_mode")];
}

- (void)setTweakInjectionEnabled:(BOOL)enabled
{
    NSString *safeModePath = JBROOT_PATH(@"/basebin/.safe_mode");
    if ([self isJailbroken]) {
        [self runAsRoot:^{
            [self runUnsandboxed:^{
                if (enabled) {
                    [[NSFileManager defaultManager] removeItemAtPath:safeModePath error:nil];
                }
                else {
                    [[NSData data] writeToFile:safeModePath atomically:YES];
                }
/*************************** roothide specific *******************/
                setBasebinDependency(enabled);
/*************************** roothide specific *******************/
            }];
        }];
    }
}

- (BOOL)isIDownloadEnabled
{
    __block BOOL isEnabled = NO;
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSDictionary *disabledDict = [NSDictionary dictionaryWithContentsOfFile:@"/var/db/com.apple.xpc.launchd/disabled.plist"];
            NSNumber *idownloaddDisabledNum = disabledDict[@"com.opa334.Dopamine.idownloadd"];
            if (idownloaddDisabledNum) {
                isEnabled = ![idownloaddDisabledNum boolValue];
            }
            else {
                isEnabled = NO;
            }
        }];
    }];
    return isEnabled;
}

- (void)setIDownloadEnabled:(BOOL)enabled needsUnsandbox:(BOOL)needsUnsandbox
{
    void (^updateBlock)(void) = ^{
        if (enabled) {
            exec_cmd_trusted(JBROOT_PATH("/usr/bin/launchctl"), "enable", "system/com.opa334.Dopamine.idownloadd", NULL);
        }
        else {
            exec_cmd_trusted(JBROOT_PATH("/usr/bin/launchctl"), "disable", "system/com.opa334.Dopamine.idownloadd", NULL);
        }
    };

    if (needsUnsandbox) {
        [self runAsRoot:^{
            [self runUnsandboxed:updateBlock];
        }];
    }
    else {
        updateBlock();
    }
}

- (void)setIDownloadLoaded:(BOOL)loaded needsUnsandbox:(BOOL)needsUnsandbox
{
    if (loaded) {
        [self setIDownloadEnabled:loaded needsUnsandbox:needsUnsandbox];
    }

    void (^updateBlock)(void) = ^{
        if (loaded) {
            exec_cmd(JBROOT_PATH("/usr/bin/launchctl"), "load", JBROOT_PATH("/basebin/LaunchDaemons/com.opa334.Dopamine.idownloadd.plist"), NULL);
        }
        else {
            exec_cmd(JBROOT_PATH("/usr/bin/launchctl"), "unload", JBROOT_PATH("/basebin/LaunchDaemons/com.opa334.Dopamine.idownloadd.plist"), NULL);
        }
    };

    if (needsUnsandbox) {
        [self runAsRoot:^{
            [self runUnsandboxed:updateBlock];
        }];
    }
    else {
        updateBlock();
    }

    if (!loaded) {
        [self setIDownloadEnabled:loaded needsUnsandbox:needsUnsandbox];
    }
}


- (NSString *)accessibleKernelPath
{
    if ([self isInstalledThroughTrollStore] || getuid() == 0) {
        NSString *kernelcachePath = [[self activePrebootPath] stringByAppendingPathComponent:@"System/Library/Caches/com.apple.kernelcaches/kernelcache"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:kernelcachePath]) {
            return kernelcachePath;
        }
        return @"/System/Library/Caches/com.apple.kernelcaches/kernelcache";
    }
    else {
        NSString *kernelInApp = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"kernelcache"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:kernelInApp]) {
            return kernelInApp;
        }

        [[DOUIManager sharedInstance] sendLog:@"Downloading Kernel" debug:NO];
        NSString *kernelcachePath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/kernelcache"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:kernelcachePath]) {
            if (grab_images([NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]) == false) return nil;
        }
        return kernelcachePath;
    }
}

- (NSString *)accessibleSPTMPath
{
    NSString *sptmInAppPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"sptm.img4"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:sptmInAppPath]) {
        return sptmInAppPath;
    }

    NSString *sptmInDocsPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/sptm.img4"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:sptmInDocsPath]) {
        return sptmInDocsPath;
    }

    sptmInDocsPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/sptm.im4p"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:sptmInDocsPath]) {
        return sptmInDocsPath;
    }

    if ([self isInstalledThroughTrollStore] || getuid() == 0) {
        NSString *sptmPath = [[self activePrebootPath] stringByAppendingPathComponent:@"/usr/standalone/firmware/FUD/Ap,SecurePageTableMonitor.img4"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:sptmPath]) {
            return sptmPath;
        }
    }

    return nil;
}

- (NSString *)accessibleTXMPath
{
    NSString *txmInAppPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"txm.img4"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:txmInAppPath]) {
        return txmInAppPath;
    }

    NSString *txmInDocsPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/txm.img4"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:txmInDocsPath]) {
        return txmInDocsPath;
    }

    txmInDocsPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/txm.im4p"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:txmInDocsPath]) {
        return txmInDocsPath;
    }

    if ([self isInstalledThroughTrollStore] || getuid() == 0) {
        NSString *txmPath = [[self activePrebootPath] stringByAppendingPathComponent:@"/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:txmPath]) {
            return txmPath;
        }
    }

    return nil;
}


- (BOOL)isPACBypassRequired
{
    if (![self isArm64e]) return NO;

    if (@available(iOS 15.2, *)) {
        return NO;
    }
    return YES;
}

- (BOOL)isPPLBypassRequired
{
    return [self isArm64e];
}

- (BOOL)isSupported
{
    //cpu_subtype_t cpuFamily = 0;
    //size_t cpuFamilySize = sizeof(cpuFamily);
    //sysctlbyname("hw.cpufamily", &cpuFamily, &cpuFamilySize, NULL, 0);
    //if (cpuFamily == CPUFAMILY_ARM_TYPHOON) return false; // A8X is unsupported for now (due to 4k page size)

    DOExploitManager *exploitManager = [DOExploitManager sharedManager];
    if ([exploitManager availableExploitsForType:EXPLOIT_TYPE_KERNEL].count) {
        if (![self isPACBypassRequired] || [exploitManager availableExploitsForType:EXPLOIT_TYPE_PAC].count) {
            if (![self isPPLBypassRequired] || [exploitManager availableExploitsForType:EXPLOIT_TYPE_PPL].count) {
                return true;
            }
        }
    }

    return false;
}

- (BOOL)deviceSupportsFaceID
{
    if (![LAContext class]) return NO;

    LAContext *myContext = [[LAContext alloc] init];
    NSError *authError = nil;
    if (![myContext canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:&authError]) {
        NSLog(@"%@", [authError localizedDescription]);
        return NO;
    }

    return myContext.biometryType == LABiometryTypeFaceID;
}

- (BOOL)deviceSupportsLandscapeBootLogo
{
    struct utsname u;
    uname(&u);
    const char *ipadString = "iPad";

    bool isPad = strncmp(u.machine, ipadString, strlen(ipadString)) == 0;
    return isPad && [self deviceSupportsFaceID];
}

- (NSError *)prepareBootstrap
{
    __block NSError *errOut;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [_bootstrapper prepareBootstrapWithCompletion:^(NSError *error) {
        errOut = error;
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    return errOut;
}

- (NSError *)finalizeBootstrap
{
    return [_bootstrapper finalizeBootstrap];
}

- (NSError *)deleteBootstrap
{
    if (![self isJailbroken] && getuid() != 0) {
        int r = [self runTrollStoreAction:@"delete-bootstrap"];
        if (r != 0) {
            // TODO: maybe handle error
        }
        return nil;
    }
    else if ([self isJailbroken]) {
        __block NSError *error;
        [self runAsRoot:^{
            [self runUnsandboxed:^{
                error = [self->_bootstrapper deleteBootstrap];
            }];
        }];
        return error;
    }
    else {
        // Let's hope for the best
        return [_bootstrapper deleteBootstrap];
    }
}

- (NSError *)validateRecoveryEnvironment
{
    if (![self isJailbroken]) return DORecoveryError(@"Check environment", -ENOTCONN, @"The jailbreak is not active.");
    NSString *expectedVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"DORootHideRuntimeVersion"] ?: [[NSBundle mainBundle] objectForInfoDictionaryKey:@"DORootHidePortVersion"];
    expectedVersion = [expectedVersion stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *activeVersion = [self.jailbrokenVersion stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // Installing the app alone does not replace the running basebin helpers.
    // This disk-version gate prevents new recovery commands reaching an old
    // runtime; it is not proof of mapped-image identity after a manual swap.
    if (!expectedVersion.length || ![activeVersion isEqualToString:expectedVersion]) {
        NSString *message = [NSString stringWithFormat:DOLocalizedString(@"Recovery_Runtime_Version_Mismatch"), activeVersion ?: @"?", expectedVersion ?: @"?"];
        return DORecoveryError(@"Check runtime", -EPROTONOSUPPORT, message);
    }
    [self refreshJailbreakRootIfNeeded];
    __block NSError *error = nil;
    NSError *privilegeError = [self runAsRootChecked:^{
        NSError *sandboxError = [self runUnsandboxedChecked:^{
            NSString *root = DOValidRootPath();
            BOOL directory = NO;
            NSFileManager *fm = [NSFileManager defaultManager];
            if (!root || ![fm fileExistsAtPath:root isDirectory:&directory] || !directory) {
                error = DORecoveryError(@"Check environment", -ENOENT, @"The jailbreak root is empty, stale, or missing.");
                return;
            }
            for (NSString *tool in @[@"basebin/jbctl", @"usr/bin/dpkg", @"usr/bin/uicache"]) {
                NSString *path = [root stringByAppendingPathComponent:tool];
                if (![fm isExecutableFileAtPath:path]) {
                    error = DORecoveryError(@"Check environment", -ENOENT, [NSString stringWithFormat:@"Missing executable: %@", path]);
                    return;
                }
            }
            NSString *status = [root stringByAppendingPathComponent:@"var/lib/dpkg/status"];
            if (![fm isReadableFileAtPath:status]) error = DORecoveryError(@"Check environment", -ENOENT, [NSString stringWithFormat:@"Missing dpkg database: %@", status]);
        }];
        if (sandboxError) error = sandboxError;
    }];
    return privilegeError ?: error;
}

- (NSError *)registerBundledApps:(NSArray<NSDictionary<NSString *, NSString *> *> *)apps
{
    NSString *root = DOValidRootPath();
    if (!root) return DORecoveryError(@"Register apps", -ENOENT, @"The jailbreak root is unavailable.");
    NSString *uicache = [root stringByAppendingPathComponent:@"usr/bin/uicache"];
    BOOL attemptedFullRegistration = NO;
    for (NSDictionary *app in apps) {
        NSString *virtualPath = DOVirtualBundledAppPath(app[@"App"]);
        if (!virtualPath) return DORecoveryError(@"Register apps", -EINVAL, @"The bundled app name is invalid.");
        NSString *path = [[root stringByAppendingPathComponent:@"Applications"] stringByAppendingPathComponent:app[@"App"]];
        __block NSString *expectedPath = nil;
        __block NSError *pathError = nil;
        NSError *privilegeError = [self runAsRootChecked:^{
            pathError = [self runUnsandboxedChecked:^{
                expectedPath = DOCanonicalRegistrationPath([path stringByResolvingSymlinksInPath]);
            }];
        }];
        if (privilegeError || pathError) return privilegeError ?: pathError;
        if (!expectedPath) return DORecoveryError(@"Register apps", -EINVAL, @"The expected app path is invalid.");
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"Registering %@ at %@", app[@"Name"], path] debug:NO];
        int status = [self spawnJbctlAsRootWithArgs:@[@"internal", @"run_tool", uicache, @"-p", virtualPath]];
        NSString *diagnostic = [NSThread currentThread].threadDictionary[@"DOHelperDiagnostic"];
        BOOL reportedError = [[NSThread currentThread].threadDictionary[@"DOHelperReportedError"] boolValue];
        if (reportedError || DOUICacheRegistrationFailed(status, diagnostic)) {
            // RootHide's uicache may reject a virtual -p path even though its
            // full scan can register the same jbroot application.  Use the
            // upstream recovery path once, then verify each app below.
            if (!attemptedFullRegistration) {
                attemptedFullRegistration = YES;
                int fullStatus = [self spawnJbctlAsRootWithArgs:@[@"internal", @"run_tool", uicache, @"-a"]];
                if (fullStatus != 0) {
                    NSString *fullDiagnostic = [NSThread currentThread].threadDictionary[@"DOHelperDiagnostic"];
                    return DORecoveryError(@"Register apps", fullStatus, [NSString stringWithFormat:@"uicache full scan failed while registering %@. %@", app[@"Name"], fullDiagnostic ?: diagnostic ?: @""]);
                }
            }
        }

        // Root queries can see a different LS registration view. Verify after
        // all root scopes exit, and keep other threads from changing process
        // credentials while LaunchServices queries as the mobile app user.
        __block NSError *verificationError = nil;
        NSRecursiveLock *privilegeLock = DOPrivilegeLock();
        [privilegeLock lock];
        @try {
            if (DOPrivilegeCleanupFailed || geteuid() != 501) {
                verificationError = DORecoveryError(@"Verify registration", -EPERM, @"LaunchServices verification requires restored mobile credentials; close and reopen Dopamine.");
            }
            else {
                // This only reads LS metadata and compares strings. Do not
                // request a root-only MAC-label change from a mobile client.
                LSApplicationProxy *proxy = [LSApplicationProxy applicationProxyForIdentifier:app[@"BundleIdentifier"]];
                NSString *registeredPath = proxy.bundleURL.path;
                if (!proxy.installed || !DORegistrationPathMatches(registeredPath, expectedPath)) {
                    verificationError = DORecoveryError(@"Verify registration", -ENOENT, [NSString stringWithFormat:@"%@ was not registered for mobile at %@ (reported path: %@).", app[@"Name"], expectedPath, registeredPath ?: @"none"]);
                }
            }
        }
        @finally { [privilegeLock unlock]; }
        if (verificationError && !attemptedFullRegistration) {
            attemptedFullRegistration = YES;
            int fullStatus = [self spawnJbctlAsRootWithArgs:@[@"internal", @"run_tool", uicache, @"-a"]];
            if (fullStatus != 0) {
                NSString *fullDiagnostic = [NSThread currentThread].threadDictionary[@"DOHelperDiagnostic"];
                return DORecoveryError(@"Register apps", fullStatus, [NSString stringWithFormat:@"uicache full scan failed while verifying %@. %@", app[@"Name"], fullDiagnostic ?: @""]);
            }

            // The full scan may repair a silent -p failure. Re-read
            // LaunchServices as mobile before returning the original error.
            // RootHide's lsd hook starts the full scan asynchronously, so
            // allow its database a bounded window to publish the registration.
            for (NSUInteger retry = 0; retry < 10; retry++) {
                verificationError = nil;
                [privilegeLock lock];
                @try {
                    if (DOPrivilegeCleanupFailed || geteuid() != 501) {
                        verificationError = DORecoveryError(@"Verify registration", -EPERM, @"LaunchServices verification requires restored mobile credentials; close and reopen Dopamine.");
                    }
                    else {
                        LSApplicationProxy *proxy = [LSApplicationProxy applicationProxyForIdentifier:app[@"BundleIdentifier"]];
                        NSString *registeredPath = proxy.bundleURL.path;
                        if (!proxy.installed || !DORegistrationPathMatches(registeredPath, expectedPath)) {
                            verificationError = DORecoveryError(@"Verify registration", -ENOENT, [NSString stringWithFormat:@"%@ was not registered for mobile at %@ (reported path: %@).", app[@"Name"], expectedPath, registeredPath ?: @"none"]);
                        }
                    }
                }
                @finally { [privilegeLock unlock]; }
                if (!verificationError || verificationError.code != -ENOENT || retry == 9) break;
                usleep(200000);
            }
        }
        if (verificationError) return verificationError;
    }
    // Do not rebuild all LaunchServices databases here. It can remove valid
    // registrations and used to hide the actual installation failure.
    return nil;
}

- (NSError *)recoverBundledApps:(NSArray<NSDictionary<NSString *, NSString *> *> *)apps
{
    NSLock *lock = DOAppRecoveryLock();
    if (![lock tryLock]) return DORecoveryError(@"Restore apps", -EBUSY, @"Another app operation is already running.");
    NSError *error = nil;
    @try {
        error = [self validateRecoveryEnvironment];
        if (!error) {
            // Each requested helper action runs after the temporary root/
            // sandbox scopes exit. Never wrap the whole workflow in runAsRoot.
            for (NSDictionary *app in apps) {
                NSString *package = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:app[@"Package"]];
                [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"Installing %@", app[@"Name"]] debug:NO];
                int status = [self->_bootstrapper installPackage:package];
                if (status) {
                    error = DORecoveryError(@"Install apps", status, [NSString stringWithFormat:@"%@ failed (%@). %@", app[@"Name"], status < 0 ? @"spawn/wait error" : @"helper exit status", [NSThread currentThread].threadDictionary[@"DOHelperDiagnostic"] ?: @""]);
                    break;
                }
                error = [self->_bootstrapper verifyBundledApp:app];
                if (error) break;
            }
        }
        if (!error) error = [self registerBundledApps:apps];
        if (error) [[DOUIManager sharedInstance] sendLog:error.localizedDescription debug:NO];
        else [[DOUIManager sharedInstance] sendLog:@"Jailbreak app installation and registration verified." debug:NO];
    }
    @finally { [lock unlock]; }
    return error;
}

- (NSError *)repairPackageSources
{
    __block NSError *sourceError = nil;
    NSError *privilegeError = [self runAsRootChecked:^{
        sourceError = [self runUnsandboxedChecked:^{
            sourceError = [self->_bootstrapper repairPackageSources];
        }];
    }];
    return privilegeError ?: sourceError;
}

- (NSError *)reinstallPackageManagers
{
    NSMutableArray *apps = [NSMutableArray array];
    NSArray *selected = [[DOUIManager sharedInstance] enabledPackageManagerKeys];
    for (NSDictionary *app in DOBundledJailbreakApps()) {
        if ([app[@"Identifier"] isEqualToString:@"com.roothide.manager"] || [selected containsObject:app[@"BundleIdentifier"]]) [apps addObject:app];
    }

    NSError *sourceError = [self repairPackageSources];
    if (sourceError) return sourceError;
    return [self recoverBundledApps:apps];
}

- (NSError *)reinstallAllBundledApps
{
    NSError *sourceError = [self repairPackageSources];
    if (sourceError) return sourceError;
    return [self recoverBundledApps:DOBundledJailbreakApps()];
}

- (NSError *)updateBootLogo
{
    const char *bootLogoPath = JBROOT_PATH("/basebin/bootlogo.jp2");
    if ([[DOPreferenceManager sharedManager] boolPreferenceValueForKey:@"bootlogoEnabled" fallback:YES]) {
        UIImage *bootLogoImage;

        if ([[DOPreferenceManager sharedManager] boolPreferenceValueForKey:@"customBootlogoEnabled" fallback:NO]) {
            bootLogoImage = [NSClassFromString(@"UIImage") imageWithContentsOfFile:[DOUIManager sharedInstance].bootlogoPath];
        }

        if (!bootLogoImage) {
            bootLogoImage = [[DOUIManager sharedInstance] renderBootLogo];
        }

        [self runAsRoot:^{
            [self runUnsandboxed:^{
                unlink(bootLogoPath);
                [[bootLogoImage jp2DataWithCompressionQuality:0.9] writeToFile:[NSString stringWithUTF8String:bootLogoPath] atomically:NO];
            }];
        }];

        return nil;
    }
    else {
        [self runAsRoot:^{
            [self runUnsandboxed:^{
                unlink(bootLogoPath);
            }];
        }];
        return nil;
    }
}

@end
