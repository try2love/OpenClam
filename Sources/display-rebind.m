// One actual WindowServer disable/enable transition, with identity checks at
// both commits. Successful completion verifies configuration, not monitor pixels.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <errno.h>
#import <math.h>
#import <pthread.h>
#import <stdbool.h>
#import <stdint.h>
#import <time.h>
#import <unistd.h>

typedef CGError (*DisplayList)(uint32_t, CGDirectDisplayID *, uint32_t *);
typedef CGError (*ConfigureEnabled)(CGDisplayConfigRef, CGDirectDisplayID, bool);
typedef CGError (*CopyDisplayUUID)(CGDirectDisplayID, CFUUIDRef *);
typedef CFDictionaryRef (*CopyDisplayInfo)(CGDirectDisplayID);
static DisplayList displayList;
static ConfigureEnabled configureEnabled;
static CopyDisplayUUID copyUUID;
static CopyDisplayInfo copyInfo;

static void emit(NSString *phase, NSDictionary *fields) {
    NSMutableDictionary *record = [fields mutableCopy];
    record[@"phase"] = phase;
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    if (json) puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    fflush(stdout);
}

static double now(void) {
    struct timespec value; clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec / 1e9;
}

static BOOL lidOpen(void) {
    io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (!root) return NO;
    id closed = CFBridgingRelease(IORegistryEntryCreateCFProperty(root, CFSTR("AppleClamshellState"), NULL, 0));
    IOObjectRelease(root);
    return [closed isKindOfClass:NSNumber.class] && [closed isEqual:@NO];
}

static NSDictionary *framebufferBinding(CGDirectDisplayID display) {
    id info = CFBridgingRelease(copyInfo(display));
    id path = [info isKindOfClass:NSDictionary.class] ? info[@"IODisplayLocation"] : nil;
    if (![path isKindOfClass:NSString.class] || ![path hasPrefix:@"IOService:"]) return nil;
    io_service_t service = IORegistryEntryFromPath(kIOMainPortDefault, [path UTF8String]);
    if (!service) return nil;
    uint64_t value = 0;
    BOOL valid = IOObjectConformsTo(service, "IOMobileFramebuffer") &&
        IORegistryEntryGetRegistryEntryID(service, &value) == KERN_SUCCESS && value;
    id nativeIdentity = valid ? CFBridgingRelease(IORegistryEntryCreateCFProperty(service, CFSTR("IOMFBUUID"), NULL, 0)) : nil;
    IOObjectRelease(service);
    if (!valid) return nil;
    return @{@"registryID":@(value), @"framebufferIdentity":
        [nativeIdentity isKindOfClass:NSString.class] && [nativeIdentity length] ? nativeIdentity : (id)NSNull.null};
}

static NSDictionary *modeInfo(CGDirectDisplayID display) {
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
    if (!mode) return nil;
    double refresh = CGDisplayModeGetRefreshRate(mode);
    NSDictionary *result = isfinite(refresh) && CGDisplayModeGetWidth(mode) && CGDisplayModeGetHeight(mode) ? @{
        @"width":@(CGDisplayModeGetWidth(mode)), @"height":@(CGDisplayModeGetHeight(mode)),
        @"pixelWidth":@(CGDisplayModeGetPixelWidth(mode)), @"pixelHeight":@(CGDisplayModeGetPixelHeight(mode)),
        @"refresh":@(refresh), @"ioModeID":@(CGDisplayModeGetIODisplayModeID(mode)),
        @"ioFlags":@(CGDisplayModeGetIOFlags(mode))} : nil;
    CGDisplayModeRelease(mode);
    return result;
}

// Identities and registry paths stay in memory. Only allowlisted step records
// are emitted. The SLS list includes disabled endpoints absent from CG online.
static NSArray<NSDictionary *> *readDisplays(void) {
    uint32_t count = 0;
    CGError listResult = displayList(0, NULL, &count);
    if (listResult != kCGErrorSuccess || !count || count > 128) {
        emit(@"read_displays_failed", @{@"result":@"count_query_failed_or_invalid", @"return":@(listResult), @"count":@(count)});
        return nil;
    }
    CGDirectDisplayID ids[128]; uint32_t capacity = count;
    listResult = displayList(capacity, ids, &count);
    if (listResult != kCGErrorSuccess || count > capacity) {
        emit(@"read_displays_failed", @{@"result":@"values_query_failed_or_grew", @"return":@(listResult), @"count":@(count), @"capacity":@(capacity)});
        return nil;
    }
    NSMutableArray *records = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (uint32_t i = 0; i < count; ++i) {
        if (!ids[i] || [seen containsObject:@(ids[i])]) {
            emit(@"read_displays_failed", @{@"result":@"zero_or_duplicate_display_id", @"displayID":@(ids[i]), @"index":@(i)});
            return nil;
        }
        [seen addObject:@(ids[i])];
        CFUUIDRef uuid = NULL;
        CGError result = copyUUID(ids[i], &uuid);
        NSString *identity = result == kCGErrorSuccess && uuid ? CFBridgingRelease(CFUUIDCreateString(NULL, uuid)) : nil;
        if (uuid) CFRelease(uuid);
        // An inactive endpoint can lack its WindowServer UUID. Retain its
        // flags and native binding so it still participates in safety checks.
        NSDictionary *native = framebufferBinding(ids[i]);
        [records addObject:@{@"id":@(ids[i]), @"identity":identity ?: (id)NSNull.null, @"identityReturn":@(result),
            @"registryID":native[@"registryID"] ?: (id)NSNull.null,
            @"framebufferIdentity":native[@"framebufferIdentity"] ?: (id)NSNull.null,
            @"builtin":@(CGDisplayIsBuiltin(ids[i]) != 0), @"active":@(CGDisplayIsActive(ids[i]) != 0),
            @"asleep":@(CGDisplayIsAsleep(ids[i]) != 0), @"mirrored":@(CGDisplayIsInMirrorSet(ids[i]) != 0)}];
    }
    return records;
}

static NSDictionary *captureBinding(NSDictionary *record) {
    if (![record[@"identity"] isKindOfClass:NSString.class] ||
        ![record[@"framebufferIdentity"] isKindOfClass:NSString.class]) return nil;
    // These UUIDs use different namespaces. Preserve and compare each only
    // against its own source; never equate a CG UUID with an IOMFBUUID.
    return @{@"identity":record[@"identity"], @"framebufferIdentity":record[@"framebufferIdentity"]};
}

static NSDictionary *pinnedTarget(NSArray<NSDictionary *> *records, NSDictionary *binding, NSNumber *registryID) {
    if (!binding) return nil;
    NSDictionary *target = nil; unsigned int identityCount = 0, externalRegistryCount = 0, nativeIdentityCount = 0;
    BOOL internalOwnsFramebuffer = NO;
    for (NSDictionary *record in records) {
        if ([record[@"identity"] isEqual:binding[@"identity"]]) identityCount++;
        if (![record[@"builtin"] boolValue] && [record[@"framebufferIdentity"] isEqual:binding[@"framebufferIdentity"]]) nativeIdentityCount++;
        if ([record[@"registryID"] isEqual:registryID]) {
            // SLS may retain the inactive internal endpoint on the shared
            // framebuffer. Only one external may bind it, and an active
            // internal owner invalidates even a recovery-enable request.
            if (![record[@"builtin"] boolValue]) { externalRegistryCount++; target = record; }
            else if ([record[@"active"] boolValue]) internalOwnsFramebuffer = YES;
        }
    }
    if (externalRegistryCount != 1 || nativeIdentityCount != 1 || internalOwnsFramebuffer ||
        ![target[@"framebufferIdentity"] isEqual:binding[@"framebufferIdentity"]]) return nil;
    BOOL sameCGIdentity = identityCount == 1 && [target[@"identity"] isEqual:binding[@"identity"]];
    BOOL disabledWithoutCGIdentity = ![target[@"active"] boolValue] && target[@"identity"] == NSNull.null && identityCount == 0;
    return sameCGIdentity || disabledWithoutCGIdentity ? target : nil;
}

static BOOL safeTopology(NSArray<NSDictionary *> *records, CGDirectDisplayID targetID) {
    BOOL otherExternal = NO;
    if (!records.count) return NO;
    for (NSDictionary *record in records) {
        if ([record[@"builtin"] boolValue] && [record[@"active"] boolValue]) return NO;
        if ([record[@"mirrored"] boolValue]) return NO;
        if ([record[@"id"] unsignedIntValue] != targetID && ![record[@"builtin"] boolValue] &&
            [record[@"active"] boolValue] && ![record[@"asleep"] boolValue]) otherExternal = YES;
    }
    return otherExternal;
}

typedef struct {
    pthread_mutex_t lock;
    uint64_t endCount;
    double lastEvent;
    BOOL pending;
} Changes;

static void changed(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *context) {
    (void)display;
    Changes *changes = context;
    pthread_mutex_lock(&changes->lock);
    changes->lastEvent = now();
    changes->pending = (flags & kCGDisplayBeginConfigurationFlag) != 0;
    if (!changes->pending) changes->endCount++;
    pthread_mutex_unlock(&changes->lock);
}

static uint64_t endCount(Changes *changes) {
    pthread_mutex_lock(&changes->lock);
    uint64_t count = changes->endCount;
    pthread_mutex_unlock(&changes->lock);
    return count;
}

static BOOL commit(CGDirectDisplayID display, BOOL enabled, NSString *phase,
    NSDictionary *binding, NSNumber *registryID, BOOL requireSafeTopology) {
    CGDisplayConfigRef config = NULL;
    NSString *failure = @"commit_failed";
    CGError result = CGBeginDisplayConfiguration(&config);
    if (result == kCGErrorSuccess) {
        result = configureEnabled(config, display, enabled);
        if (result == kCGErrorSuccess) {
            // Staging may deliver callbacks. Do not commit a cached CG ID if a
            // hotplug rebound it while the configuration was being prepared.
            NSArray *records = readDisplays();
            NSDictionary *target = pinnedTarget(records, binding, registryID);
            if (!target || [target[@"id"] unsignedIntValue] != display) {
                result = kCGErrorFailure; failure = @"binding_changed_before_commit";
            } else if (requireSafeTopology && (!lidOpen() || !safeTopology(records, display))) {
                result = kCGErrorFailure; failure = @"topology_changed_before_commit";
            }
        }
        if (result == kCGErrorSuccess) result = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        else CGCancelDisplayConfiguration(config);
    }
    emit(phase, @{@"displayID":@(display), @"enabled":@(enabled), @"return":@(result),
        @"result":result == kCGErrorSuccess ? @"committed_not_verified" : failure});
    return result == kCGErrorSuccess;
}

static BOOL completionReady(BOOL enabled, BOOL stateMatches, BOOL callbackObserved,
    BOOL pending, double eventAge, double stateDuration, unsigned int stableSamples, double settledDuration) {
    if (!stateMatches || pending || eventAge < 0.25) return NO;
    // The private SLS enable operation can restore the exact original endpoint
    // without a new completion callback. Require repeated stable state after
    // the separately verified disable instead of treating commit return as proof.
    if (enabled) return stateDuration >= 0.75 && stableSamples >= 3;
    return callbackObserved && settledDuration >= 0.25;
}

// A callback never changes configuration. Disable requires a completed change;
// enable additionally supports the observed private-SLS missing-callback case.
static NSString *waitForState(NSDictionary *binding, NSNumber *registryID, BOOL enabled,
    NSDictionary *savedMode, Changes *changes, uint64_t previousEnd, double duration) {
    double deadline = now() + duration;
    double stableSince = 0, stateStableSince = 0, lastSample = 0;
    unsigned int sampleCount = 0, stableSamples = 0; double maxQueryDuration = 0;
    CGDirectDisplayID lastDisplay = kCGNullDirectDisplay;
    BOOL lastActive = NO, lastAsleep = NO, lastModeMatches = NO, lastStateMatches = NO;
    while (now() < deadline) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
        double queryStarted = now();
        if (!lidOpen()) return @"physical_lid_changed";
        NSArray *records = readDisplays();
        NSDictionary *target = pinnedTarget(records, binding, registryID);
        if (!target) return @"target_identity_lost_or_ambiguous";
        CGDirectDisplayID display = [target[@"id"] unsignedIntValue];
        if (!safeTopology(records, display)) return @"topology_changed";
        lastDisplay = display;
        lastActive = [target[@"active"] boolValue]; lastAsleep = [target[@"asleep"] boolValue];
        lastModeMatches = [modeInfo(display) isEqual:savedMode];
        BOOL matches = lastActive == enabled;
        if (enabled) matches = matches && !lastAsleep;
        if (matches && enabled && !lastModeMatches) return @"mode_changed";
        double current = now();
        sampleCount++; maxQueryDuration = fmax(maxQueryDuration, current-queryStarted);
        lastSample = current; lastStateMatches = matches;
        if (matches) { if (!stateStableSince) stateStableSince = current; stableSamples++; }
        else { stateStableSince = 0; stableSamples = 0; }
        pthread_mutex_lock(&changes->lock);
        BOOL callbackObserved = changes->endCount > previousEnd, pending = changes->pending;
        double eventAge = current - changes->lastEvent;
        BOOL settled = callbackObserved && !pending && eventAge >= 0.25;
        pthread_mutex_unlock(&changes->lock);
        if (matches && settled) {
            if (!stableSince) stableSince = current;
        } else stableSince = 0;
        if (completionReady(enabled, matches, callbackObserved, pending, eventAge,
            stateStableSince ? current-stateStableSince : 0, stableSamples,
            stableSince ? current-stableSince : 0)) {
            emit(enabled ? @"enabled_settled" : @"disabled_settled",
                @{@"result":@"configuration_verified", @"displayID":@(display),
                  @"completionCallbackObserved":@(callbackObserved), @"stableSamples":@(stableSamples),
                  @"stateStableDuration":@(stateStableSince ? current-stateStableSince : 0)});
            return nil;
        }
    }
    double current = now();
    pthread_mutex_lock(&changes->lock);
    uint64_t currentEnd = changes->endCount;
    BOOL pending = changes->pending;
    double lastEvent = changes->lastEvent;
    pthread_mutex_unlock(&changes->lock);
    emit(@"settle_timeout", @{@"desiredEnabled":@(enabled), @"displayID":@(lastDisplay),
        @"previousEndCount":@(previousEnd), @"currentEndCount":@(currentEnd), @"pending":@(pending),
        @"lastEventAge":lastEvent ? (id)@(current-lastEvent) : NSNull.null,
        @"sampleAge":lastSample ? (id)@(current-lastSample) : NSNull.null,
        @"sampleCount":@(sampleCount), @"maxQueryDuration":@(maxQueryDuration),
        @"targetActive":@(lastActive), @"targetAsleep":@(lastAsleep),
        @"modeMatches":@(lastModeMatches), @"stateMatches":@(lastStateMatches),
        @"stateStableDuration":@(stateStableSince ? current-stateStableSince : 0),
        @"settledStableDuration":@(stableSince ? current-stableSince : 0)});
    return @"configuration_did_not_settle";
}

static void recoverTarget(NSDictionary *binding, NSNumber *registryID) {
    NSDictionary *target = pinnedTarget(readDisplays(), binding, registryID);
    if (!target) {
        emit(@"recovery", @{@"result":@"skipped_identity_unavailable"}); return;
    }
    if ([target[@"active"] boolValue] && ![target[@"asleep"] boolValue]) {
        emit(@"recovery", @{@"result":@"skipped_already_active_awake",
            @"displayID":target[@"id"], @"modeVerified":@NO}); return;
    }
    // Only the exact original external may be re-enabled. Never fall back to
    // a stale CG ID or a framebuffer that now represents the internal panel.
    commit([target[@"id"] unsignedIntValue], YES, @"recovery_enable", binding, registryID, NO);
}

#ifndef OPENCLAM_REBIND_TEST
int main(int argc, const char **argv) { @autoreleasepool {
    alarm(10);
    if (argc != 3) { fputs("Usage: display-rebind REGISTRY_ID CG_DISPLAY_ID\n", stderr); return 2; }
    uint64_t values[2] = {0};
    for (int i = 0; i < 2; i++) {
        char *end = NULL; errno = 0;
        values[i] = strtoull(argv[i+1], &end, 10);
        if (!argv[i+1][0] || strspn(argv[i+1], "0123456789") != strlen(argv[i+1]) ||
            errno || *end || !values[i] || (i == 1 && values[i] > UINT32_MAX)) {
            emit(@"precondition", @{@"result":@"invalid_arguments"}); return 2;
        }
    }
    NSNumber *registryID = @(values[0]); CGDirectDisplayID initialID = (CGDirectDisplayID)values[1];
    void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
    displayList = sky ? (DisplayList)dlsym(sky, "SLSGetDisplayList") : NULL;
    configureEnabled = sky ? (ConfigureEnabled)dlsym(sky, "SLSConfigureDisplayEnabled") : NULL;
    copyUUID = sky ? (CopyDisplayUUID)dlsym(sky, "SLSCopyDisplayUUID") : NULL;
    copyInfo = sky ? (CopyDisplayInfo)dlsym(sky, "SLSCopyDisplayInfoDictionary") : NULL;
    if (!displayList || !configureEnabled || !copyUUID || !copyInfo) {
        emit(@"precondition", @{@"result":@"symbol_unavailable"}); return 3;
    }
    NSArray *records = readDisplays(); NSDictionary *binding = nil;
    for (NSDictionary *record in records) if ([record[@"id"] unsignedIntValue] == initialID) binding = captureBinding(record);
    NSDictionary *target = binding ? pinnedTarget(records, binding, registryID) : nil;
    NSDictionary *savedMode = target ? modeInfo(initialID) : nil;
    if (!target || ![target[@"active"] boolValue] || [target[@"asleep"] boolValue] ||
        !savedMode || !lidOpen() || !safeTopology(records, initialID)) {
        emit(@"precondition", @{@"result":@"refused", @"reason":@"requires_unique_active_external_open_lid_internal_off_and_other_awake_external"});
        return 3;
    }
    Changes changes = {.lock=PTHREAD_MUTEX_INITIALIZER};
    CGError callbackResult = CGDisplayRegisterReconfigurationCallback(changed, &changes);
    if (callbackResult != kCGErrorSuccess) {
        emit(@"precondition", @{@"result":@"callback_failed", @"return":@(callbackResult)}); return 3;
    }
    NSString *failure = nil; BOOL disableAttempted = NO;
    emit(@"start", @{@"displayID":@(initialID), @"registryID":registryID, @"mode":savedMode});
    // Revalidate immediately before the first mutation, after callback setup.
    records = readDisplays(); target = pinnedTarget(records, binding, registryID);
    CGDirectDisplayID display = [target[@"id"] unsignedIntValue];
    if (!target || ![target[@"active"] boolValue] || [target[@"asleep"] boolValue] ||
        ![modeInfo(display) isEqual:savedMode] || !lidOpen() || !safeTopology(records, display)) failure = @"precondition_changed";
    if (!failure) {
        uint64_t before = endCount(&changes); disableAttempted = YES;
        if (!commit(display, NO, @"disable", binding, registryID, YES)) failure = @"disable_failed";
        else failure = waitForState(binding, registryID, NO, savedMode, &changes, before, 2.5);
    }
    if (!failure) {
        records = readDisplays(); target = pinnedTarget(records, binding, registryID);
        display = [target[@"id"] unsignedIntValue];
        if (!target || [target[@"active"] boolValue] || !lidOpen() || !safeTopology(records, display)) failure = @"disabled_target_changed";
        else {
            uint64_t before = endCount(&changes);
            if (!commit(display, YES, @"enable", binding, registryID, YES)) failure = @"enable_failed";
            else failure = waitForState(binding, registryID, YES, savedMode, &changes, before, 5.0);
        }
    }
    if (failure) {
        emit(@"failed", @{@"result":failure});
        if (disableAttempted) recoverTarget(binding, registryID);
    }
    CGDisplayRemoveReconfigurationCallback(changed, &changes);
    pthread_mutex_destroy(&changes.lock);
    emit(@"complete", @{@"result":failure ? @"rebind_failed" : @"rebound_not_pixels_verified"});
    return failure ? 3 : 0;
}}
#endif
