// Same-state probe of the actual SkyLight clamshell-request path.
// No closed-state request, injected entitlement, or system setting mutation.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <unistd.h>
#import <signal.h>

@interface NSObject (OpenClamPowerProbe)
- (id)initAsyncPowerControlClient:(NSError **)error notifyQueue:(dispatch_queue_t)queue
                notificationType:(NSUInteger)type notificationBlock:(void (^)(NSDictionary *))block;
- (id)initPowerControlClient:(NSError **)error notifyQueue:(dispatch_queue_t)queue
           notificationType:(NSUInteger)type notificationBlock:(void (^)(NSDictionary *))block;
- (unsigned long long)requestStateChange:(NSDictionary *)request error:(NSError **)error;
- (id)service;
- (BOOL)connected;
- (BOOL)enabled;
@end

static void emit(NSDictionary *record) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
    fflush(stdout);
}

static NSDictionary *errorInfo(NSError *error) {
    return error && error.code != 0 ? @{@"domain":error.domain, @"code":@(error.code), @"message":error.localizedDescription} : @{};
}

static id property(io_service_t service, NSString *key) {
    return CFBridgingRelease(IORegistryEntryCreateCFProperty(service, (__bridge CFStringRef)key, NULL, 0));
}

// Explicit allowlist: no EDID, display serials, device UUIDs or full registry dump.
static NSArray *routing(void) {
    NSMutableArray *records = [NSMutableArray array];
    for (NSString *className in @[@"IOMobileFramebuffer", @"AppleDCPDPTXRemotePortUFP", @"AppleATCDPAltModePort"]) {
        io_iterator_t iterator = 0;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className.UTF8String), &iterator) != KERN_SUCCESS) continue;
        io_service_t service;
        while ((service = IOIteratorNext(iterator))) {
            io_name_t name = {0}; IORegistryEntryGetName(service, name);
            NSMutableDictionary *record = [@{@"class":className, @"name":@(name)} mutableCopy];
            for (NSString *key in @[@"IONameMatched", @"IdleState"]) {
                id value = property(service, key);
                if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) record[key] = value;
            }
            for (NSString *key in @[@"DisplayAttributes", @"IOMFBUUID"]) {
                record[[key stringByAppendingString:@"Present"]] = @(property(service, key) != nil);
            }
            id power = property(service, @"IOPowerManagement");
            if ([power isKindOfClass:NSDictionary.class]) {
                NSMutableDictionary *selected = [NSMutableDictionary dictionary];
                for (NSString *key in @[@"CurrentPowerState", @"DevicePowerState", @"MaxPowerState"]) {
                    if ([power[key] isKindOfClass:NSNumber.class]) selected[key] = power[key];
                }
                record[@"power"] = selected;
            }
            id log = property(service, @"EventLog");
            if ([log isKindOfClass:NSArray.class]) {
                NSMutableArray *events = [NSMutableArray array];
                for (id entry in log) {
                    if (![entry isKindOfClass:NSDictionary.class]) continue;
                    id payload = entry[@"EventPayload"];
                    if (![payload isKindOfClass:NSDictionary.class]) continue;
                    NSMutableDictionary *event = [NSMutableDictionary dictionary];
                    for (NSString *key in @[@"Action", @"State", @"Value", @"Valid", @"MaxW", @"MaxH"]) {
                        id value = payload[key];
                        if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) event[key] = value;
                    }
                    if (event.count) [events addObject:event];
                }
                record[@"recentPortEvents"] = events.count > 12 ? [events subarrayWithRange:NSMakeRange(events.count-12,12)] : events;
            }
            [records addObject:record]; IOObjectRelease(service);
        }
        IOObjectRelease(iterator);
    }
    return records;
}

static NSDictionary *state(void) {
    io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    id closed = nil;
    if (root) {
        closed = CFBridgingRelease(IORegistryEntryCreateCFProperty(root, CFSTR("AppleClamshellState"), NULL, 0));
        IOObjectRelease(root);
    }
    CGDirectDisplayID ids[32]; uint32_t count = 0;
    CGError result = CGGetOnlineDisplayList(32, ids, &count);
    NSMutableArray *displays = [NSMutableArray array];
    if (result == kCGErrorSuccess) for (uint32_t i=0; i<count; i++) {
        [displays addObject:@{@"id":@(ids[i]), @"builtin":@(CGDisplayIsBuiltin(ids[i]) != 0),
                             @"active":@(CGDisplayIsActive(ids[i]) != 0)}];
    }
    return @{@"lidClosed":closed ?: NSNull.null, @"displayQueryReturn":@(result), @"displays":displays};
}

static BOOL signature(Class cls, SEL selector, const char *encoding) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || strcmp(method_getTypeEncoding(method), encoding)) {
        emit(@{@"result":@"unsupported_signature", @"selector":NSStringFromSelector(selector),
               @"encoding":method ? @(method_getTypeEncoding(method)) : @"missing"});
        return NO;
    }
    return YES;
}

int main(int argc, const char **argv) { @autoreleasepool {
    if (argc == 2 && !strcmp(argv[1], "snapshot")) {
        emit(@{@"state":state(), @"routing":routing(), @"os":NSProcessInfo.processInfo.operatingSystemVersionString}); return 0;
    }
    if (argc != 2 || (strcmp(argv[1], "sync") && strcmp(argv[1], "async"))) {
        fputs("Usage: clamshell-probe snapshot|sync|async (open-state requests only)\n", stderr); return 2;
    }
    // A hanging private API must not block the collector indefinitely.
    alarm(10);
    NSDictionary *before = state();
    emit(@{@"phase":@"before", @"state":before, @"mode":@(argv[1]), @"os":NSProcessInfo.processInfo.operatingSystemVersionString});
    if (![before[@"lidClosed"] isEqual:@NO] || [before[@"displayQueryReturn"] intValue] != 0 || [before[@"displays"] count] == 0) {
        emit(@{@"result":@"refused", @"reason":@"Requires confirmed open lid and accessible desktop session"}); return 2;
    }
    void *library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
    if (!library) { emit(@{@"result":@"framework_unavailable"}); return 2; }
    Class cls = NSClassFromString(@"SLSDisplayPowerControlClient");
    NSString *__unsafe_unretained *key = (NSString *__unsafe_unretained *)dlsym(library, "kSLSDisplayControlRequestClamshellState");
    BOOL async = !strcmp(argv[1], "async");
    SEL initializer = async ? @selector(initAsyncPowerControlClient:notifyQueue:notificationType:notificationBlock:) : @selector(initPowerControlClient:notifyQueue:notificationType:notificationBlock:);
    if (!cls || !key || !*key ||
        !signature(cls, initializer, "@48@0:8^@16@24Q32@?40") ||
        !signature(cls, @selector(requestStateChange:error:), "Q32@0:8@16^@24") ||
        !signature(cls, @selector(service), "@16@0:8")) return 2;
    NSError *error = nil;
    void (^notification)(NSDictionary *) = ^(NSDictionary *unused) { (void)unused; emit(@{@"notificationReceived":@YES}); };
    id allocated = [cls alloc];
    id client = async ? [allocated initAsyncPowerControlClient:&error notifyQueue:dispatch_get_main_queue() notificationType:0 notificationBlock:notification]
                      : [allocated initPowerControlClient:&error notifyQueue:dispatch_get_main_queue() notificationType:0 notificationBlock:notification];
    emit(@{@"phase":@"initialized", @"clientCreated":@(client != nil), @"error":errorInfo(error)});
    if (!client || error.code != 0) return 3;
    NSDate *readyDeadline = [NSDate dateWithTimeIntervalSinceNow:1];
    [[NSRunLoop currentRunLoop] runUntilDate:readyDeadline];
    error = nil;
    unsigned long long uuid = [client requestStateChange:@{*key:@1} error:&error];
    NSDictionary *requestError = errorInfo(error);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2]];
    id service = [client service];
    BOOL supportsReadback = service && signature([service class], @selector(connected), "B16@0:8") && signature([service class], @selector(enabled), "B16@0:8");
    BOOL connected = supportsReadback && [service connected];
    emit(@{@"phase":@"request_result", @"requestedState":@"open", @"uuid":@(uuid), @"error":requestError,
           @"connectionReadbackAvailable":@(supportsReadback), @"connected":@(connected),
           @"enabled":@(supportsReadback && [service enabled]), @"after":state(),
           @"result":requestError.count ? @"request_rejected" : (connected ? @"open_request_submitted_not_close_verified" : @"connection_not_established")});
    return requestError.count || !connected ? 3 : 0;
}}
