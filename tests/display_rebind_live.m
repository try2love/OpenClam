// Independent parent for the production display-rebind executable. Never use
// this helper outside the guarded live test in external_rebind_live.py.
#define OPENCLAM_REBIND_TEST 1
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
#import "../Sources/display-rebind.m"
#pragma clang diagnostic pop
#import <signal.h>
#import <spawn.h>
#import <sys/wait.h>

extern char **environ;
static volatile sig_atomic_t interrupted = 0;
static void stopTest(int value) { (void)value; interrupted = 1; }

static NSDictionary *otherDisplays(NSArray<NSDictionary *> *records, NSDictionary *binding, NSNumber *registryID) {
    NSDictionary *target = pinnedTarget(records, binding, registryID);
    if (!target) return nil;
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSDictionary *record in records) {
        if ([record[@"id"] isEqual:target[@"id"]]) continue;
        NSMutableDictionary *state = [record mutableCopy];
        state[@"mode"] = modeInfo([record[@"id"] unsignedIntValue]) ?: (id)NSNull.null;
        result[record[@"id"]] = state;
    }
    return result;
}

static BOOL restoredTarget(NSDictionary *binding, NSNumber *registryID, NSDictionary *mode) {
    NSDictionary *target = pinnedTarget(readDisplays(), binding, registryID);
    return target && [target[@"active"] boolValue] && ![target[@"asleep"] boolValue] &&
        [modeInfo([target[@"id"] unsignedIntValue]) isEqual:mode];
}

int main(int argc, const char **argv) { @autoreleasepool {
    if (argc != 4) return 2; // production helper path, registry ID, CG display ID
    signal(SIGINT, stopTest); signal(SIGTERM, stopTest);
    void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
    displayList = sky ? (DisplayList)dlsym(sky, "SLSGetDisplayList") : NULL;
    configureEnabled = sky ? (ConfigureEnabled)dlsym(sky, "SLSConfigureDisplayEnabled") : NULL;
    copyUUID = sky ? (CopyDisplayUUID)dlsym(sky, "SLSCopyDisplayUUID") : NULL;
    copyInfo = sky ? (CopyDisplayInfo)dlsym(sky, "SLSCopyDisplayInfoDictionary") : NULL;
    if (!displayList || !configureEnabled || !copyUUID || !copyInfo) return 3;
    uint64_t values[2];
    for (int i = 0; i < 2; ++i) {
        char *end = NULL; errno = 0;
        values[i] = strtoull(argv[i + 2], &end, 10);
        if (!argv[i + 2][0] || strspn(argv[i + 2], "0123456789") != strlen(argv[i + 2]) ||
            errno || *end || !values[i] || (i == 1 && values[i] > UINT32_MAX)) return 2;
    }
    NSNumber *registryID = @(values[0]);
    CGDirectDisplayID display = (CGDirectDisplayID)values[1];
    NSArray *records = readDisplays(); NSDictionary *binding = nil;
    for (NSDictionary *record in records) if ([record[@"id"] unsignedIntValue] == display) binding = captureBinding(record);
    NSDictionary *target = binding ? pinnedTarget(records, binding, registryID) : nil;
    NSDictionary *mode = target ? modeInfo(display) : nil;
    NSDictionary *others = otherDisplays(records, binding, registryID);
    NSMutableArray *displayStates = [NSMutableArray array];
    for (NSDictionary *record in records) {
        NSMutableDictionary *state = [record mutableCopy];
        state[@"identityAvailable"] = @([record[@"identity"] isKindOfClass:NSString.class]);
        [state removeObjectForKey:@"identity"];
        state[@"framebufferIdentityAvailable"] = @([record[@"framebufferIdentity"] isKindOfClass:NSString.class]);
        [state removeObjectForKey:@"framebufferIdentity"]; [displayStates addObject:state];
    }
    BOOL physicalLidOpen = lidOpen(), topologySafe = safeTopology(records, display);
    emit(@"live_parent_precondition", @{@"displayID":@(display), @"registryID":registryID,
        @"listAvailable":@(records != nil), @"displayCount":@(records.count),
        @"identityAvailable":@(binding != nil), @"uniqueTargetAvailable":@(target != nil),
        @"modeAvailable":@(mode != nil), @"otherStatesAvailable":@(others != nil),
        @"targetActive":@([target[@"active"] boolValue]), @"targetAsleep":@([target[@"asleep"] boolValue]),
        @"physicalLidOpen":@(physicalLidOpen), @"topologySafe":@(topologySafe), @"displayStates":displayStates});
    if (!target || !mode || !others || ![target[@"active"] boolValue] || [target[@"asleep"] boolValue] ||
        !physicalLidOpen || !topologySafe) {
        emit(@"live_parent_refused", @{@"result":@"unsafe_initial_state"}); return 3;
    }
    emit(@"live_parent_start", @{@"displayID":@(display), @"registryID":registryID, @"mode":mode});
    pid_t child = 0;
    char *childArgs[] = {(char *)argv[1], (char *)argv[2], (char *)argv[3], NULL};
    int spawned = posix_spawn(&child, argv[1], NULL, NULL, childArgs, environ);
    if (spawned) { emit(@"live_parent_spawn", @{@"return":@(spawned)}); return 3; }
    BOOL unchanged = YES, timedOut = NO, finished = NO;
    int status = 0; double deadline = now() + 12;
    while (!finished) {
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child) { finished = YES; break; }
        if (result < 0 && errno != EINTR) break;
        if (![otherDisplays(readDisplays(), binding, registryID) isEqual:others]) unchanged = NO;
        if (interrupted || !unchanged || now() >= deadline) {
            timedOut = now() >= deadline;
            kill(child, SIGTERM);
            double stopDeadline = now() + 1;
            while (now() < stopDeadline) {
                if (waitpid(child, &status, WNOHANG) == child) { finished = YES; break; }
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
            }
            if (!finished) {
                kill(child, SIGKILL);
                while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
                finished = YES;
            }
            break;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
    }
    BOOL childOK = finished && WIFEXITED(status) && WEXITSTATUS(status) == 0;
    BOOL restored = restoredTarget(binding, registryID, mode);
    // The parent retained the identity independently of the child, so even a
    // killed child cannot lose its cleanup target. This never disables a screen.
    BOOL recoveryNeeded = !restored;
    if (recoveryNeeded) {
        recoverTarget(binding, registryID);
        double recoveryDeadline = now() + 3;
        while (!(restored = restoredTarget(binding, registryID, mode)) && now() < recoveryDeadline)
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
    }
    unchanged = unchanged && [otherDisplays(readDisplays(), binding, registryID) isEqual:others];
    BOOL passed = childOK && !interrupted && !timedOut && unchanged && restored;
    emit(@"live_parent_complete", @{@"passed":@(passed), @"childOK":@(childOK),
        @"timedOut":@(timedOut), @"recoveryNeeded":@(recoveryNeeded),
        @"targetActiveAwakeOriginalMode":@(restored), @"otherDisplaysUnchanged":@(unchanged)});
    return passed ? 0 : 3;
}}
