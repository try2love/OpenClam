// Current display metadata and driver link readback. A healthy link is useful
// evidence, but it cannot attest that a monitor is displaying correct pixels.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <math.h>
#import <stdint.h>
#import <time.h>
#import <unistd.h>

typedef CFTypeRef IOMobileFramebufferRef;
typedef kern_return_t (*OpenFramebuffer)(io_service_t, task_port_t, uint32_t, IOMobileFramebufferRef *);
typedef int32_t (*GetLinkQuality)(IOMobileFramebufferRef);
typedef kern_return_t (*GetDigitalOutMode)(IOMobileFramebufferRef, uint32_t *, uint32_t *);
typedef CFDictionaryRef (*CopyDisplayInfo)(CGDirectDisplayID);
typedef CGError (*AllDisplayList)(uint32_t, CGDirectDisplayID *, uint32_t *);

static id property(io_service_t service, NSString *key) {
    return CFBridgingRelease(IORegistryEntryCreateCFProperty(service, (__bridge CFStringRef)key, NULL, 0));
}

static id numberOrUnknown(id value) {
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) ? value : NSNull.null;
}

static NSDictionary *selectedNumbers(id dictionary, NSArray<NSString *> *keys) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in keys) result[key] = numberOrUnknown([dictionary isKindOfClass:NSDictionary.class] ? dictionary[key] : nil);
    return result;
}

static NSDictionary *selectedProperties(io_service_t service, NSArray<NSString *> *keys) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in keys) result[key] = service ? numberOrUnknown(property(service, key)) : NSNull.null;
    return result;
}

static NSDictionary *powerEvidence(io_service_t service) {
    id value = service ? property(service, @"IOPowerManagement") : nil;
    return @{@"available":@([value isKindOfClass:NSDictionary.class]),
        @"fields":selectedNumbers(value, @[@"CurrentPowerState", @"MaxPowerState", @"CapabilityFlags", @"DevicePowerState", @"ChildrenPowerState"])};
}

static NSDictionary *rootEvidence(io_service_t service) {
    return @{@"available":@(service != 0), @"fields":selectedProperties(service,
        @[@"AppleClamshellState", @"AppleClamshellCausesSleep", @"IOPMSystemSleepType", @"IOPMUserIsActive",
          @"IOPMUserTriggeredFullWake", @"SleepDisabled", @"IOSleepSupported", @"System Capabilities",
          @"DriverPMAssertions", @"Standby Enabled", @"IOServiceState", @"IOServiceBusyState"]),
        @"power":powerEvidence(service)};
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

// EventTime is a raw driver value: preserve it for same-port comparisons but
// do not invent units or treat an old event as the current electrical state.
static NSDictionary *selectedEvent(id entry, NSUInteger index, BOOL extended) {
    if (![entry isKindOfClass:NSDictionary.class]) return nil;
    id payload = entry[@"EventPayload"];
    if (![payload isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *event = [NSMutableDictionary dictionary];
    NSArray *states = extended ? @[@"Activate", @"SinkActive", @"LaneCount", @"LinkRate", @"Registered", @"HintsReserved", @"Downspread", @"ActionEnabled", @"Message"] :
        @[@"Activate", @"SinkActive", @"LaneCount", @"LinkRate", @"Registered", @"HintsReserved", @"Downspread"];
    if ([states containsObject:payload[@"State"] ?: NSNull.null]) {
        event[@"State"] = payload[@"State"];
        if ([payload[@"Value"] isKindOfClass:NSNumber.class]) event[@"Value"] = numberOrUnknown(payload[@"Value"]);
    }
    NSArray *actions = extended ? @[@"DisplayRequest", @"DisplayRelease", @"Plug", @"Unplug", @"IRQ"] : @[@"DisplayRequest", @"DisplayRelease", @"Plug", @"Unplug"];
    if ([actions containsObject:payload[@"Action"] ?: NSNull.null]) event[@"Action"] = payload[@"Action"];
    NSArray *fields = extended ? @[@"Valid", @"MaxW", @"MaxH", @"MaxBpc", @"MaxActivePixelRate", @"MaxTotalPixelRate", @"Tiled"] : @[@"Valid", @"MaxW", @"MaxH"];
    for (NSString *key in fields) if ([payload[key] isKindOfClass:NSNumber.class]) event[key] = numberOrUnknown(payload[key]);
    if (!event.count) return nil;
    if (extended) {
        event[@"eventIndex"] = @(index);
        event[@"eventTime"] = numberOrUnknown(entry[@"EventTime"]);
    }
    return event;
}

// Port events are historical. Keep only link-control fields, never sink identity.
static NSArray *portEvidence(BOOL extended, NSMutableDictionary *queryReturns) {
    NSMutableArray *ports = [NSMutableArray array];
    NSArray<NSString *> *classes = extended ? @[@"AppleDCPDPTXRemotePortUFP", @"AppleATCDPAltModePort"] : @[@"AppleDCPDPTXRemotePortUFP"];
    for (NSString *className in classes) {
    io_iterator_t iterator = 0;
    kern_return_t queryResult = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className.UTF8String), &iterator);
    if (queryReturns) queryReturns[className] = @(queryResult);
    if (queryResult != KERN_SUCCESS) continue;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        uint64_t registryID = 0; IORegistryEntryGetRegistryEntryID(service, &registryID);
        io_name_t name = {0}; IORegistryEntryGetName(service, name);
        NSMutableDictionary *port = [@{@"registryID":@(registryID), @"name":@(name),
            @"eventsAreHistorical":@YES} mutableCopy];
        id hints = property(service, @"DisplayHints");
        NSMutableDictionary *selected = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"Valid", @"MaxW", @"MaxH", @"MaxBpc", @"MaxActivePixelRate", @"MaxTotalPixelRate"]) {
            if ([hints isKindOfClass:NSDictionary.class] && [hints[key] isKindOfClass:NSNumber.class]) selected[key] = hints[key];
        }
        port[@"currentHints"] = selected;
        if (extended) {
            port[@"serviceClass"] = className;
            port[@"hintsAvailable"] = @([hints isKindOfClass:NSDictionary.class]);
            port[@"currentHints"] = selectedNumbers(hints, @[@"Valid", @"MaxW", @"MaxH", @"MaxBpc", @"MaxActivePixelRate", @"MaxTotalPixelRate", @"Tiled"]);
            port[@"registryState"] = selectedProperties(service, @[@"IOServiceState", @"IOServiceBusyState"]);
        }
        id log = property(service, @"EventLog");
        NSMutableArray *events = [NSMutableArray array];
        if ([log isKindOfClass:NSArray.class]) for (NSUInteger index = 0; index < [log count]; index++) {
            NSDictionary *event = selectedEvent(log[index], index, extended);
            if (event) [events addObject:event];
        }
        NSUInteger limit = extended ? 64 : 16;
        port[@"recentEvents"] = events.count > limit ? [events subarrayWithRange:NSMakeRange(events.count-limit,limit)] : events;
        if (extended) {
            port[@"eventLogAvailable"] = @([log isKindOfClass:NSArray.class]);
            port[@"eventsTotalCount"] = [log isKindOfClass:NSArray.class] ? (id)@([log count]) : NSNull.null;
            port[@"eventsSelectedCount"] = @(events.count);
            port[@"eventsTruncated"] = @(events.count > limit);
            port[@"eventTimeUnits"] = @"driver_raw_unknown";
            port[@"eventIndexMeaning"] = @"position_in_this_snapshot_log_not_global_sequence";
        }
        [ports addObject:port]; IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    }
    return ports;
}

#ifndef OPENCLAM_LINK_TEST
int main(int argc, const char **argv) { @autoreleasepool {
    BOOL extended = argc == 2 && !strcmp(argv[1], "--extended");
    if (argc != 1 && !extended) { fputs("Usage: display-link [--extended]\n", stderr); return 2; }
    alarm(5);
    struct timespec started; clock_gettime(CLOCK_MONOTONIC, &started);
    void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
    CopyDisplayInfo copyInfo = sky ? (CopyDisplayInfo)dlsym(sky, "SLSCopyDisplayInfoDictionary") : NULL;
    AllDisplayList allDisplayList = extended && sky ? (AllDisplayList)dlsym(sky, "SLSGetDisplayList") : NULL;
    void *iomfb = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_NOW);
    OpenFramebuffer openFramebuffer = iomfb ? (OpenFramebuffer)dlsym(iomfb, "IOMobileFramebufferOpen") : NULL;
    GetLinkQuality getQuality = iomfb ? (GetLinkQuality)dlsym(iomfb, "IOMobileFramebufferGetLinkQuality") : NULL;
    GetDigitalOutMode getMode = iomfb ? (GetDigitalOutMode)dlsym(iomfb, "IOMobileFramebufferGetDigitalOutMode") : NULL;

    CGDirectDisplayID ids[128]; uint32_t count = 0;
    CGError displayResult = CGGetOnlineDisplayList(32, ids, &count);
    id allDisplayResult = NSNull.null; BOOL allDisplaysAvailable = NO;
    if (extended && allDisplayList) {
        uint32_t allCount = 0; CGDirectDisplayID allIDs[128];
        CGError result = allDisplayList(128, allIDs, &allCount);
        allDisplayResult = @(result);
        if (result == kCGErrorSuccess && allCount <= 128) {
            memcpy(ids, allIDs, allCount * sizeof(CGDirectDisplayID)); count = allCount; allDisplaysAvailable = YES;
        }
    }
    NSMutableArray *displays = [NSMutableArray array];
    // The WindowServer UUID and IOMFBUUID are different namespaces on current
    // systems. Resolve the exact registry path supplied for each CG display.
    // Display metadata and registry paths are never included in the output.
    NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *displayIDsByRegistryID = [NSMutableDictionary dictionary];
    if (displayResult == kCGErrorSuccess || allDisplaysAvailable) for (uint32_t i = 0; i < count; i++) {
        NSMutableDictionary *display = [@{@"id":@(ids[i]), @"builtin":@(CGDisplayIsBuiltin(ids[i]) != 0),
            @"active":@(CGDisplayIsActive(ids[i]) != 0), @"asleep":@(CGDisplayIsAsleep(ids[i]) != 0),
            @"mode":modeInfo(ids[i]) ?: (id)NSNull.null} mutableCopy];
        NSNumber *registryID = registryIDForDisplay(ids[i], copyInfo);
        if (extended) {
            CGRect bounds = CGDisplayBounds(ids[i]);
            display[@"online"] = @(CGDisplayIsOnline(ids[i]) != 0);
            display[@"main"] = @(CGDisplayIsMain(ids[i]) != 0);
            display[@"mirrored"] = @(CGDisplayIsInMirrorSet(ids[i]) != 0);
            display[@"mirrorsDisplayID"] = @(CGDisplayMirrorsDisplay(ids[i]));
            display[@"rotation"] = numberOrUnknown(@(CGDisplayRotation(ids[i])));
            display[@"bounds"] = @{@"x":numberOrUnknown(@(bounds.origin.x)), @"y":numberOrUnknown(@(bounds.origin.y)),
                @"width":numberOrUnknown(@(bounds.size.width)), @"height":numberOrUnknown(@(bounds.size.height))};
            display[@"registryID"] = registryID ?: (id)NSNull.null;
            display[@"registryMapping"] = registryID ? @"resolved" : @"unavailable";
        }
        [displays addObject:display];
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
            io_name_t serviceName = {0}; IORegistryEntryGetName(service, serviceName);
            record[@"serviceName"] = @(serviceName);
            for (NSString *key in @[@"DPTimingModeId", @"DisplayWidth", @"DisplayHeight", @"DisplayClock", @"PixelClock"]) {
                id value = property(service, key);
                if ([value isKindOfClass:NSNumber.class]) record[key] = value;
            }
            if (extended) {
                record[@"registryState"] = selectedProperties(service, @[@"IdleState", @"NormalModeActive", @"DispPerfState", @"IOServiceState", @"IOServiceBusyState",
                    @"DPTimingModeId", @"DisplayWidth", @"DisplayHeight", @"DisplayClock", @"PixelClock", @"APTEnableEvents", @"APTEventsMask",
                    @"BLMPowergateEnable", @"SupportsAOTPowerSaving", @"IdleCachingMethod"]);
                record[@"power"] = powerEvidence(service);
                id attributes = property(service, @"DisplayAttributes");
                id allocation = [attributes isKindOfClass:NSDictionary.class] ? attributes[@"DisplayAllocation"] : nil;
                record[@"displayAllocation"] = selectedNumbers(allocation, @[@"MainUFP", @"PeerUFP", @"ExtraPipes", @"UseSingleTile"]);
                record[@"displayAllocationAvailable"] = @([allocation isKindOfClass:NSDictionary.class]);
                record[@"modeReadbackAvailable"] = @(getMode != NULL);
                record[@"linkReadbackAvailable"] = @(getQuality != NULL);
                record[@"openResult"] = NSNull.null;
                record[@"digitalModeResult"] = NSNull.null;
                record[@"digitalMode"] = NSNull.null;
                record[@"digitalEncoding"] = NSNull.null;
            }
            if (idResult == KERN_SUCCESS && registryID != 0) {
                NSNumber *key = @(registryID);
                if (!framebuffersByRegistryID[key]) framebuffersByRegistryID[key] = [NSMutableArray array];
                [framebuffersByRegistryID[key] addObject:record];
            }
            if (openFramebuffer) {
                IOMobileFramebufferRef fb = NULL;
                kern_return_t result = openFramebuffer(service, mach_task_self(), 0, &fb);
                record[@"openResult"] = @(result);
                if (result == KERN_SUCCESS && fb) {
                    if (getQuality) {
                        int32_t quality = getQuality(fb);
                        // INT32_MIN is the framework's failed-query sentinel.
                        if (quality != INT32_MIN) record[@"linkQuality"] = @(quality);
                    }
                    if (getMode) {
                        // This is the read-only mode query, NOT GetDigitalOutState.
                        // Driver mode indices are not CoreGraphics display-mode IDs.
                        uint32_t mode = 0, encoding = 0;
                        kern_return_t modeResult = getMode(fb, &mode, &encoding);
                        record[@"digitalModeResult"] = @(modeResult);
                        if (modeResult == KERN_SUCCESS) {
                            record[@"digitalMode"] = @(mode); record[@"digitalEncoding"] = @(encoding);
                        }
                    }
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
        if (extended) for (NSMutableDictionary *record in records) record[@"mappedDisplayIDs"] = matches ?: @[];
    }
    io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    id lid = root ? property(root, @"AppleClamshellState") : nil;
    NSDictionary *rootState = extended ? rootEvidence(root) : nil;
    if (root) IOObjectRelease(root);
    NSMutableDictionary *portQueryReturns = extended ? [NSMutableDictionary dictionary] : nil;
    NSMutableDictionary *output = [@{@"displayQueryReturn":@(displayResult), @"framebufferQueryReturn":@(framebufferResult),
        @"physicalLidClosed":lid ?: NSNull.null, @"displays":displays, @"framebuffers":framebuffers,
        @"ports":portEvidence(extended, portQueryReturns)} mutableCopy];
    if (extended) {
        struct timespec finished; clock_gettime(CLOCK_MONOTONIC, &finished);
        output[@"extendedSchemaVersion"] = @1;
        output[@"allDisplayListAvailable"] = @(allDisplaysAvailable);
        output[@"allDisplayQueryReturn"] = allDisplayResult;
        output[@"displayScope"] = allDisplaysAvailable ? @"all_including_disabled" : @"online_fallback";
        output[@"rootPowerState"] = rootState;
        output[@"portQueryReturns"] = portQueryReturns;
        output[@"sampleMonotonicStart"] = @(started.tv_sec + started.tv_nsec / 1e9);
        output[@"sampleDuration"] = @(finished.tv_sec-started.tv_sec + (finished.tv_nsec-started.tv_nsec) / 1e9);
        output[@"missingValuesMean"] = @"unknown_not_zero_or_false";
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingSortedKeys error:nil];
    if (!json) return 3;
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    return displayResult == kCGErrorSuccess && framebufferResult == KERN_SUCCESS ? 0 : 3;
}}
#endif
