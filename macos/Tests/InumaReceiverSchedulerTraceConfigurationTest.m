#import <Foundation/Foundation.h>

#include <stdlib.h>

#import "../Classes/InumaReceiverSchedulerTraceConfiguration.h"

static void Require(BOOL condition, NSString* message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    abort();
  }
}

int main(void) {
  @autoreleasepool {
    BOOL enabled = NO;
    Require(InumaParseReceiverSchedulerTraceConfiguration(@{}, &enabled) ==
                InumaReceiverSchedulerTraceParseResultAbsent,
            @"missing option must preserve the disabled SDK default");
    Require(enabled == NO, @"an absent option must not mutate output");

    Require(InumaParseReceiverSchedulerTraceConfiguration(
                @{@"receiverSchedulerTrace" : @YES}, &enabled) ==
                InumaReceiverSchedulerTraceParseResultValid,
            @"Boolean true must parse");
    Require(enabled == YES, @"Boolean true must remain true");

    Require(InumaParseReceiverSchedulerTraceConfiguration(
                @{@"receiverSchedulerTrace" : @NO}, &enabled) ==
                InumaReceiverSchedulerTraceParseResultValid,
            @"Boolean false must parse");
    Require(enabled == NO, @"Boolean false must remain false");

    NSArray* invalidValues = @[@0, @1, @"true", @[], @{}, [NSNull null]];
    for (id value in invalidValues) {
      Require(InumaParseReceiverSchedulerTraceConfiguration(
                  @{@"receiverSchedulerTrace" : value}, &enabled) ==
                  InumaReceiverSchedulerTraceParseResultInvalid,
              @"non-Boolean values must fail closed");
    }
    Require(InumaParseReceiverSchedulerTraceConfiguration(
                @{@"receiverSchedulerTrace" : @YES}, NULL) ==
                InumaReceiverSchedulerTraceParseResultInvalid,
            @"a missing output pointer must fail closed");
  }
  return 0;
}
