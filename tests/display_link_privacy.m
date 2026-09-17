// Exercise the same allowlists used for live collection with hostile/non-scalar
// fixture values. No IOKit or display queries are performed by these tests.
#define OPENCLAM_LINK_TEST
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
#include "../Sources/display-link.m"
#pragma clang diagnostic pop

int main(void) { @autoreleasepool {
    NSDictionary *numbers = selectedNumbers(@{@"Valid":@YES, @"MaxW":@2560,
        @"MaxH":@"PRIVATE_SERIAL", @"MaxBpc":@[@10], @"EDID UUID":@"PRIVATE_UUID", @"ProductName":@"PRIVATE_PRODUCT"},
        @[@"Valid", @"MaxW", @"MaxH", @"MaxBpc", @"Missing"]);
    NSCAssert([numbers[@"Valid"] isEqual:@YES] && [numbers[@"MaxW"] isEqual:@2560], @"preserve scalar evidence");
    NSCAssert(numbers[@"MaxH"] == NSNull.null && numbers[@"MaxBpc"] == NSNull.null && numbers[@"Missing"] == NSNull.null, @"missing and wrong-type values stay unknown");
    NSCAssert(!numbers[@"EDID UUID"] && !numbers[@"ProductName"], @"only requested fields survive");
    NSCAssert(numberOrUnknown(@(NAN)) == NSNull.null && numberOrUnknown(@(INFINITY)) == NSNull.null, @"invalid numeric values stay JSON-safe");

    NSDictionary *entry = @{@"EventTime":@123456789, @"EventRaw":[@"PRIVATE_RAW" dataUsingEncoding:NSUTF8StringEncoding],
        @"EventClass":@"PRIVATE_CLASS", @"EventPayload":@{@"State":@"LaneCount", @"Value":@2,
            @"Action":@"IRQ", @"MaxW":@2560, @"MaxBpc":@10, @"Tiled":@NO,
            @"EDID UUID":@"PRIVATE_UUID", @"ProductName":@"PRIVATE_PRODUCT", @"Path":@"PRIVATE_PATH"}};
    NSDictionary *extended = selectedEvent(entry, 42, YES), *legacy = selectedEvent(entry, 42, NO);
    NSCAssert([extended[@"eventTime"] isEqual:@123456789] && [extended[@"eventIndex"] isEqual:@42], @"preserve raw time and snapshot ordering");
    NSCAssert([extended[@"State"] isEqual:@"LaneCount"] && [extended[@"Value"] isEqual:@2] && [extended[@"Action"] isEqual:@"IRQ"], @"known electrical events survive");
    NSCAssert([extended[@"MaxBpc"] isEqual:@10] && [extended[@"Tiled"] isEqual:@NO], @"numeric link requirements survive");
    NSCAssert(!legacy[@"eventTime"] && !legacy[@"eventIndex"] && !legacy[@"MaxBpc"] && !legacy[@"Action"], @"default event schema stays unchanged");
    NSDictionary *unknownTime = selectedEvent(@{@"EventTime":@"PRIVATE_TIME", @"EventPayload":@{@"State":@"SinkActive", @"Value":@1}}, 0, YES);
    NSCAssert(unknownTime[@"eventTime"] == NSNull.null, @"non-numeric time never copied");
    NSCAssert(!selectedEvent(@{@"EventPayload":@{@"State":@"PRIVATE_IDENTITY", @"Value":@1}}, 0, YES), @"unknown state strings excluded");
    NSCAssert(!selectedEvent(@{@"EventPayload":@[@"PRIVATE_PAYLOAD"]}, 0, YES), @"malformed payload excluded");
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[numbers, extended, legacy, unknownTime] options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSCAssert(data && [json rangeOfString:@"PRIVATE_"].location == NSNotFound, @"no fixture identity or raw bytes escape allowlists");
    puts("12 extended display-link schema/privacy checks passed; no live queries");
    return 0;
}}
