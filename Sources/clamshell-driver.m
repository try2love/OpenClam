// Direct display-driver clamshell request. The Swift owner supplies the
// independent recovery process and verifies the resulting display topology.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <errno.h>
#import <stdlib.h>
#import <unistd.h>

typedef CFTypeRef IOMobileFramebufferRef;
typedef kern_return_t (*OpenFramebuffer)(io_service_t, task_port_t, uint32_t, IOMobileFramebufferRef *);
typedef int (*SetClamshellState)(IOMobileFramebufferRef, uint32_t);

static void emit(NSDictionary *record) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    fflush(stdout);
}

static id lidState(void) {
    io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (!root) return nil;
    id value = CFBridgingRelease(IORegistryEntryCreateCFProperty(root, CFSTR("AppleClamshellState"), NULL, 0));
    IOObjectRelease(root);
    return value;
}

static BOOL hasExternalDisplay(void) {
    CGDirectDisplayID displays[32]; uint32_t count = 0;
    if (CGGetOnlineDisplayList(32, displays, &count) != kCGErrorSuccess) return NO;
    for (uint32_t i = 0; i < count; i++) {
        if (!CGDisplayIsBuiltin(displays[i]) && CGDisplayIsActive(displays[i])) return YES;
    }
    return NO;
}

static BOOL isBuiltinFramebuffer(io_service_t service) {
    if (!IOObjectConformsTo(service, "IOMobileFramebuffer")) return NO;
    id matched = CFBridgingRelease(IORegistryEntryCreateCFProperty(service, CFSTR("IONameMatched"), NULL, 0));
    return [matched isKindOfClass:NSString.class] && [matched hasPrefix:@"disp0,"];
}

static int identify(void) {
    io_iterator_t iterator = 0;
    kern_return_t result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebuffer"), &iterator);
    if (result != KERN_SUCCESS) {
        emit(@{@"result":@"enumeration_failed", @"return":@(result)}); return 3;
    }
    uint64_t registryID = 0; unsigned int matches = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        if (isBuiltinFramebuffer(service)) {
            matches++;
            if (IORegistryEntryGetRegistryEntryID(service, &registryID) != KERN_SUCCESS) registryID = 0;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    if (matches != 1 || !registryID) {
        emit(@{@"result":matches > 1 ? @"ambiguous_builtin" : @"builtin_not_found"}); return 3;
    }
    emit(@{@"result":@"identified", @"registryID":@(registryID)});
    return 0;
}

int main(int argc, const char **argv) { @autoreleasepool {
    // Each helper operation is bounded independently of the app's watchdog.
    alarm(5);
    if (argc == 2 && !strcmp(argv[1], "identify")) return identify();
    BOOL closing = argc == 3 && !strcmp(argv[1], "close");
    BOOL opening = argc == 3 && !strcmp(argv[1], "open");
    if (!closing && !opening) {
        fputs("Usage: clamshell-driver identify | open REGISTRY_ID | close REGISTRY_ID\n", stderr); return 2;
    }
    char *end = NULL;
    errno = 0;
    uint64_t registryID = strtoull(argv[2], &end, 10);
    if (!argv[2][0] || argv[2][0] == '-' || argv[2][0] == '+' || errno || *end || !registryID) {
        emit(@{@"result":@"invalid_registry_id"}); return 2;
    }
    if (closing && (![lidState() isEqual:@NO] || !hasExternalDisplay())) {
        emit(@{@"result":@"refused", @"reason":@"Closing requires confirmed open lid and an active external display"}); return 2;
    }
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID));
    if (!service || !isBuiltinFramebuffer(service)) {
        if (service) IOObjectRelease(service);
        emit(@{@"result":@"pinned_builtin_unavailable", @"registryID":@(registryID)}); return 3;
    }
    void *library = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_NOW);
    OpenFramebuffer openFramebuffer = library ? (OpenFramebuffer)dlsym(library, "IOMobileFramebufferOpen") : NULL;
    SetClamshellState setClamshell = library ? (SetClamshellState)dlsym(library, "IOMobileFramebufferSetClamshellState") : NULL;
    if (!openFramebuffer || !setClamshell) {
        IOObjectRelease(service);
        emit(@{@"result":@"symbol_unavailable"}); return 3;
    }
    IOMobileFramebufferRef framebuffer = NULL;
    kern_return_t opened = openFramebuffer(service, mach_task_self(), 0, &framebuffer);
    IOObjectRelease(service);
    if (opened != KERN_SUCCESS || !framebuffer) {
        if (framebuffer) CFRelease(framebuffer);
        emit(@{@"result":@"framebuffer_open_failed", @"return":@(opened), @"registryID":@(registryID)}); return 3;
    }
    // Recheck after opening the framebuffer, immediately before closing it.
    if (closing && (![lidState() isEqual:@NO] || !hasExternalDisplay())) {
        CFRelease(framebuffer);
        emit(@{@"result":@"refused", @"reason":@"Lid or external display changed"}); return 2;
    }
    uint32_t state = closing ? 2 : 1;
    int result = setClamshell(framebuffer, state);
    CFRelease(framebuffer);
    // In the inspected macOS 15.6.1 DCP driver, the setter stores state and
    // unconditionally returns 1. It does not propagate the DCP RPC outcome.
    // Neither 0 nor 1 verifies that a second external display became active.
    BOOL submitted = result == 0 || result == 1;
    emit(@{@"result":submitted ? @"submitted_not_verified" : @"request_rejected",
           @"requestedState":closing ? @"closed" : @"open", @"requestedValue":@(state),
           @"registryID":@(registryID), @"return":@(result),
           @"returnHex":[NSString stringWithFormat:@"0x%08x", (unsigned int)result]});
    return submitted ? 0 : 3;
}}
