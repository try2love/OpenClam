// No live display configuration calls: regression cases for safe re-identification.
#import <CoreGraphics/CoreGraphics.h>
static CGError testBegin(CGDisplayConfigRef *config);
static CGError testComplete(CGDisplayConfigRef config, CGConfigureOption option);
static CGError testCancel(CGDisplayConfigRef config);
#define CGBeginDisplayConfiguration testBegin
#define CGCompleteDisplayConfiguration testComplete
#define CGCancelDisplayConfiguration testCancel
#define OPENCLAM_REBIND_TEST
#include "../Sources/display-rebind.m"

static unsigned int staged, completed, cancelled;
static CGError testBegin(CGDisplayConfigRef *config) { *config = (CGDisplayConfigRef)(uintptr_t)1; return kCGErrorSuccess; }
static CGError testComplete(CGDisplayConfigRef config, CGConfigureOption option) {
    (void)config; (void)option; completed++; return kCGErrorSuccess;
}
static CGError testCancel(CGDisplayConfigRef config) { (void)config; cancelled++; return kCGErrorSuccess; }
static CGError testStage(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled) {
    (void)config; (void)display; (void)enabled; staged++; return kCGErrorSuccess;
}
static CGError disappearedList(uint32_t capacity, CGDirectDisplayID *ids, uint32_t *count) {
    (void)capacity; (void)ids; *count = 0; return kCGErrorSuccess;
}

static NSDictionary *record(unsigned int display, NSString *identity, unsigned long long registry,
    BOOL builtin, BOOL active, BOOL asleep, BOOL mirrored) {
    return @{@"id":@(display), @"identity":identity ?: (id)NSNull.null, @"registryID":@(registry),
        @"framebufferIdentity":[NSString stringWithFormat:@"native-%llu", registry],
        @"builtin":@(builtin), @"active":@(active), @"asleep":@(asleep), @"mirrored":@(mirrored)};
}

int main(void) { @autoreleasepool {
    NSDictionary *working = record(2, @"working", 200, NO, YES, NO, NO);
    NSDictionary *target = record(3, @"target", 300, NO, YES, NO, NO);
    NSArray *initial = @[working, target];
    NSDictionary *binding = captureBinding(target);
    NSCAssert(pinnedTarget(initial, binding, @300) == target && safeTopology(initial, 3), @"valid initial pair");

    // After disabling, CG IDs can change. Only stable identity plus framebuffer
    // binding authorizes the next mutation, and disabled entries must be kept.
    NSDictionary *renumbered = record(9, @"target", 300, NO, NO, YES, NO);
    NSArray *disabled = @[working, renumbered];
    NSCAssert([pinnedTarget(disabled, binding, @300)[@"id"] isEqual:@9] && safeTopology(disabled, 9), @"re-find disabled endpoint");
    NSCAssert(!pinnedTarget(@[working, record(3, @"replacement", 300, NO, YES, NO, NO)], binding, @300), @"reject reused CG ID");
    NSCAssert(!pinnedTarget(@[working, record(3, @"target", 400, NO, YES, NO, NO)], binding, @300), @"reject relocated framebuffer");
    NSCAssert(!pinnedTarget(@[working, target, record(4, @"other", 300, NO, NO, YES, NO)], binding, @300), @"reject duplicate framebuffer including disabled entries");
    NSCAssert(!pinnedTarget(@[working, target, record(4, @"target", 400, NO, NO, YES, NO)], binding, @300), @"reject duplicate identity");
    NSCAssert(!pinnedTarget(@[working, record(3, @"target", 300, YES, YES, NO, NO)], binding, @300), @"never enable rebound internal endpoint");
    NSCAssert(pinnedTarget(@[working, target, record(1, @"internal", 300, YES, NO, YES, NO)], binding, @300) == target, @"allow inactive internal alias on shared framebuffer");
    NSCAssert(!pinnedTarget(@[working, target, record(1, @"internal", 300, YES, YES, NO, NO)], binding, @300), @"reject external alias after internal reclaimed framebuffer, including recovery");
    NSCAssert(pinnedTarget(@[working, target, record(1, nil, 300, YES, NO, YES, NO)], binding, @300) == target, @"inactive internal without CG UUID remains harmless");
    NSDictionary *disabledWithoutUUID = record(9, nil, 300, NO, NO, YES, NO);
    NSCAssert(pinnedTarget(@[working, disabledWithoutUUID], binding, @300) == disabledWithoutUUID, @"disabled target retains exact independent native identity");
    NSCAssert(!pinnedTarget(@[working, record(9, nil, 300, NO, YES, NO, NO)], binding, @300), @"active target must regain original CG identity");
    NSMutableDictionary *changedNative = [disabledWithoutUUID mutableCopy]; changedNative[@"framebufferIdentity"] = @"replacement-native";
    NSCAssert(!pinnedTarget(@[working, changedNative], binding, @300), @"reject same framebuffer after native sink identity changed");
    NSCAssert(!pinnedTarget(@[working, record(9, @"replacement", 300, NO, NO, YES, NO)], binding, @300), @"known conflicting CG identity never uses missing-identity fallback");
    NSMutableDictionary *nativeCollision = [record(4, @"other", 400, NO, NO, YES, NO) mutableCopy];
    nativeCollision[@"framebufferIdentity"] = target[@"framebufferIdentity"];
    NSCAssert(!pinnedTarget(@[working, target, nativeCollision], binding, @300), @"reject duplicate native identity across external endpoints");
    NSMutableDictionary *missingNative = [target mutableCopy]; missingNative[@"framebufferIdentity"] = NSNull.null;
    NSCAssert(!captureBinding(missingNative), @"never begin without both independent identities");
    NSCAssert(!safeTopology(@[target], 3), @"must preserve another external");
    NSCAssert(!safeTopology(@[target, record(2, @"working", 200, NO, YES, YES, NO)], 3), @"other external must be awake");
    NSCAssert(!safeTopology(@[working, target, record(1, @"internal", 100, YES, YES, NO, NO)], 3), @"internal must be off");
    NSCAssert(!safeTopology(@[target, record(2, @"working", 200, NO, YES, NO, YES)], 3), @"reject mirror topology");
    // A target can disappear after staging succeeded. Never send that queued
    // numeric ID to CGComplete, including during best-effort recovery.
    displayList = disappearedList; configureEnabled = testStage;
    NSCAssert(!commit(3, NO, @"test_staging_race", binding, @300, YES), @"cancel normal stale staged ID");
    NSCAssert(!commit(3, YES, @"test_recovery_race", binding, @300, NO), @"cancel recovery stale staged ID");
    NSCAssert(staged == 2 && cancelled == 2 && completed == 0, @"no stale ID reaches actual commit");
    NSCAssert(completionReady(YES, YES, NO, NO, 1, 0.75, 3, 0), @"accept observed private-enable missing callback only after repeated stable state");
    NSCAssert(!completionReady(YES, YES, NO, NO, 1, 0.74, 3, 0), @"require full stable duration");
    NSCAssert(!completionReady(YES, YES, NO, NO, 1, 1, 2, 0), @"one slow query cannot substitute for three samples");
    NSCAssert(!completionReady(YES, YES, NO, YES, 1, 1, 3, 0), @"pending reconfiguration blocks enable acceptance");
    NSCAssert(!completionReady(YES, YES, NO, NO, 0.24, 1, 3, 0), @"recent event blocks enable acceptance");
    NSCAssert(!completionReady(YES, NO, YES, NO, 1, 1, 3, 1), @"callback cannot override wrong target state");
    NSCAssert(completionReady(YES, YES, YES, NO, 1, 1, 3, 1), @"normal callback enable remains accepted");
    NSCAssert(!completionReady(NO, YES, NO, NO, 1, 1, 3, 1), @"disable must still observe new completion callback");
    NSCAssert(!completionReady(NO, YES, YES, NO, 1, 1, 3, 0.24), @"disable retains settled interval");
    NSCAssert(completionReady(NO, YES, YES, NO, 1, 1, 3, 0.25), @"disable accepts original complete settled predicate");
    puts("32 display rebind identity/topology/race/completion cases passed; no display writes");
    return 0;
}}
