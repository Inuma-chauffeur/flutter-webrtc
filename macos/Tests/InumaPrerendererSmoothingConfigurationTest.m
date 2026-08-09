#import <Foundation/Foundation.h>

#include <stdlib.h>

#import "../Classes/InumaPrerendererSmoothingConfiguration.h"

static void Require(BOOL condition, NSString* message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    abort();
  }
}

int main(void) {
  @autoreleasepool {
    Require(InumaPrerendererSmoothingDisabledConfigurationCount() == 0,
            @"the process starts without a disabled configuration");

    BOOL enabled = NO;
    Require(InumaParsePrerendererSmoothingConfiguration(@{}, &enabled) ==
                InumaPrerendererSmoothingParseResultAbsent,
            @"missing option must preserve the SDK default");
    Require(enabled == NO, @"absent option must not mutate output");

    Require(InumaParsePrerendererSmoothingConfiguration(
                @{@"prerendererSmoothing" : @YES}, &enabled) ==
                InumaPrerendererSmoothingParseResultValid,
            @"Boolean true must parse");
    Require(enabled == YES, @"Boolean true must remain true");

    Require(InumaParsePrerendererSmoothingConfiguration(
                @{@"prerendererSmoothing" : @NO}, &enabled) ==
                InumaPrerendererSmoothingParseResultValid,
            @"Boolean false must parse");
    Require(enabled == NO, @"Boolean false must remain false");

    NSArray* invalidValues = @[
      @0,
      @1,
      @"false",
      @[],
      @{},
      [NSNull null],
    ];
    for (id value in invalidValues) {
      Require(InumaParsePrerendererSmoothingConfiguration(
                  @{@"prerendererSmoothing" : value}, &enabled) ==
                  InumaPrerendererSmoothingParseResultInvalid,
              @"non-Boolean values must fail closed");
    }

    Require(InumaParsePrerendererSmoothingConfiguration(
                @{@"prerendererSmoothing" : @NO}, NULL) ==
                InumaPrerendererSmoothingParseResultInvalid,
            @"a missing output pointer must fail closed");

    InumaRecordPrerendererSmoothingConfiguration(YES);
    Require(InumaPrerendererSmoothingDisabledConfigurationCount() == 0,
            @"preserving smoothing must not record a disabled peer");
    InumaRecordPrerendererSmoothingConfiguration(NO);
    Require(InumaPrerendererSmoothingDisabledConfigurationCount() == 1,
            @"an applied disabled configuration must be counted once");
  }
  return 0;
}
