// Current display metadata and driver link readback. A healthy link is useful
// evidence, but it cannot attest that a monitor is displaying correct pixels.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <stdint.h>
#import <unistd.h>

typedef CFTypeRef IOMobileFramebufferRef;
typedef kern_return_t (*OpenFramebuffer)(io_service_t, task_port_t, uint32_t, IOMobileFramebufferRef *);
typedef int32_t (*GetLinkQuality)(IOMobileFramebufferRef);
typedef CFDictionaryRef (*CopyDisplayInfo)(CGDirectDisplayID);

static id property(io_service_t service, NSString *key) {
    return CFBridgingRelease(IORegistryEntryCreateCFProperty(service, (__bridge CFStringRef)key, NULL, 0));
}

static NSNumber *registryIDForDisplay(CGDirectDisplayID display, CopyDisplayInfo copyInfo) {
    if (!copyInfo) return nil;
    id info = CFBridgingRelease(copyInfo(display));
    if (![info isKindOfClass:NSDictionary.class]) return nil;
    id path = info[@"IODisplayLocation"];
    if (![path isKindOfClass:NSString.class]) return nil;
    io_service_t service = IORegistryEntryFromPath(kIOMainPortDefault, [path UTF8String]);
    if (!service) return nil;
    uint64_t registryID = 0;
    BOOL found = IOObjectConformsTo(service, "IOMobileFramebuffer") &&
        IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS && registryID != 0;
    IOObjectRelease(service);
    return found ? @(registryID) : nil;
}

static NSDictionary *modeInfo(CGDirectDisplayID display) {
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
    if (!mode) return nil;
    NSMutableDictionary *info = [@{
        @"width":@(CGDisplayModeGetWidth(mode)), @"height":@(CGDisplayModeGetHeight(mode)),
        @"pixelWidth":@(CGDisplayModeGetPixelWidth(mode)), @"pixelHeight":@(CGDisplayModeGetPixelHeight(mode)),
        @"refresh":@(CGDisplayModeGetRefreshRate(mode)),
        @"ioModeID":@(CGDisplayModeGetIODisplayModeID(mode)), @"ioFlags":@(CGDisplayModeGetIOFlags(mode))
    } mutableCopy];
    // This legacy field is diagnostic only; its presence does not prove that
    // the physical output uses this encoding or that colors are correct.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    id encoding = CFBridgingRelease(CGDisplayModeCopyPixelEncoding(mode));
#pragma clang diagnostic pop
    info[@"pixelEncoding"] = encoding ?: NSNull.null;
    CGDisplayModeRelease(mode);
    return info;
}

int main(int argc, const char **argv) { @autoreleasepool {
    (void)argv;
    if (argc != 1) { fputs("Usage: display-link\n", stderr); return 2; }
    alarm(5);
    void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
    CopyDisplayInfo copyInfo = sky ? (CopyDisplayInfo)dlsym(sky, "SLSCopyDisplayInfoDictionary") : NULL;
    void *iomfb = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_NOW);
    OpenFramebuffer openFramebuffer = iomfb ? (OpenFramebuffer)dlsym(iomfb, "IOMobileFramebufferOpen") : NULL;
    GetLinkQuality getQuality = iomfb ? (GetLinkQuality)dlsym(iomfb, "IOMobileFramebufferGetLinkQuality") : NULL;

    CGDirectDisplayID ids[32]; uint32_t count = 0;
    CGError displayResult = CGGetOnlineDisplayList(32, ids, &count);
    NSMutableArray *displays = [NSMutableArray array];
    // The WindowServer UUID and IOMFBUUID are different namespaces on current
    // systems. Resolve the exact registry path supplied for each CG display.
    // Display metadata and registry paths are never included in the output.
    NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *displayIDsByRegistryID = [NSMutableDictionary dictionary];
    if (displayResult == kCGErrorSuccess) for (uint32_t i = 0; i < count; i++) {
        [displays addObject:@{@"id":@(ids[i]), @"builtin":@(CGDisplayIsBuiltin(ids[i]) != 0),
            @"active":@(CGDisplayIsActive(ids[i]) != 0), @"asleep":@(CGDisplayIsAsleep(ids[i]) != 0),
            @"mode":modeInfo(ids[i]) ?: (id)NSNull.null}];
        NSNumber *registryID = registryIDForDisplay(ids[i], copyInfo);
        if (registryID) {
            if (!displayIDsByRegistryID[registryID]) displayIDsByRegistryID[registryID] = [NSMutableArray array];
            [displayIDsByRegistryID[registryID] addObject:@(ids[i])];
        }
    }

    NSMutableArray<NSMutableDictionary *> *framebuffers = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, NSMutableArray<NSMutableDictionary *> *> *framebuffersByRegistryID = [NSMutableDictionary dictionary];
    io_iterator_t iterator = 0;
    kern_return_t framebufferResult = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching("IOMobileFramebuffer"), &iterator);
    if (framebufferResult == KERN_SUCCESS) {
        io_service_t service;
        while ((service = IOIteratorNext(iterator))) {
            uint64_t registryID = 0;
            kern_return_t idResult = IORegistryEntryGetRegistryEntryID(service, &registryID);
            id name = property(service, @"IONameMatched");
            NSMutableDictionary *record = [@{
                @"registryID":idResult == KERN_SUCCESS ? (id)@(registryID) : NSNull.null,
                @"internalChannel":@([name isKindOfClass:NSString.class] && [name hasPrefix:@"disp0,"]),
                @"matchedDisplayID":NSNull.null, @"linkQuality":NSNull.null
            } mutableCopy];
            if (idResult == KERN_SUCCESS && registryID != 0) {
                NSNumber *key = @(registryID);
                if (!framebuffersByRegistryID[key]) framebuffersByRegistryID[key] = [NSMutableArray array];
                [framebuffersByRegistryID[key] addObject:record];
            }
            if (openFramebuffer && getQuality) {
                IOMobileFramebufferRef fb = NULL;
                kern_return_t result = openFramebuffer(service, mach_task_self(), 0, &fb);
                if (result == KERN_SUCCESS && fb) {
                    int32_t quality = getQuality(fb);
                    // INT32_MIN is the framework's failed-query sentinel.
                    if (quality != INT32_MIN) record[@"linkQuality"] = @(quality);
                }
                if (fb) CFRelease(fb);
            }
            // Do not add GetDigitalOutState: despite its name, its user-client
            // path rereads the physical lid and overwrites the clamshell cache.
            [framebuffers addObject:record];
            IOObjectRelease(service);
        }
        IOObjectRelease(iterator);
    }
    // Both sides must resolve uniquely. Do not guess from framebuffer index,
    // resolution, enumeration order, or identities shared by identical monitors.
    for (NSNumber *key in framebuffersByRegistryID) {
        NSArray *records = framebuffersByRegistryID[key], *matches = displayIDsByRegistryID[key];
        if (records.count == 1 && matches.count == 1) records[0][@"matchedDisplayID"] = matches[0];
    }
    NSDictionary *output = @{@"displayQueryReturn":@(displayResult), @"framebufferQueryReturn":@(framebufferResult),
        @"displays":displays, @"framebuffers":framebuffers};
    NSData *json = [NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingSortedKeys error:nil];
    if (!json) return 3;
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    return displayResult == kCGErrorSuccess && framebufferResult == KERN_SUCCESS ? 0 : 3;
}}
