#import <Foundation/Foundation.h>

#include <stdlib.h>

#import "../Classes/InumaLowLatencyVideoPlayoutConfiguration.h"

static void Require(BOOL condition, NSString* message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    abort();
  }
}

int main(void) {
  @autoreleasepool {
    Require(InumaLowLatencyVideoPlayoutEnabledConfigurationCount() == 0,
            @"the process starts without an enabled configuration");

    BOOL enabled = NO;
    Require(InumaParseLowLatencyVideoPlayoutConfiguration(@{}, &enabled) ==
                InumaLowLatencyVideoPlayoutParseResultAbsent,
            @"missing option must preserve the SDK default");
    Require(enabled == NO, @"an absent option must not mutate output");

    Require(InumaParseLowLatencyVideoPlayoutConfiguration(
                @{@"lowLatencyVideoPlayout" : @YES}, &enabled) ==
                InumaLowLatencyVideoPlayoutParseResultValid,
            @"Boolean true must parse");
    Require(enabled == YES, @"Boolean true must remain true");

    Require(InumaParseLowLatencyVideoPlayoutConfiguration(
                @{@"lowLatencyVideoPlayout" : @NO}, &enabled) ==
                InumaLowLatencyVideoPlayoutParseResultValid,
            @"Boolean false must parse");
    Require(enabled == NO, @"Boolean false must remain false");

    NSArray* invalidValues = @[@0, @1, @"true", @[], @{}, [NSNull null]];
    for (id value in invalidValues) {
      Require(InumaParseLowLatencyVideoPlayoutConfiguration(
                  @{@"lowLatencyVideoPlayout" : value}, &enabled) ==
                  InumaLowLatencyVideoPlayoutParseResultInvalid,
              @"non-Boolean values must fail closed");
    }
    Require(InumaParseLowLatencyVideoPlayoutConfiguration(
                @{@"lowLatencyVideoPlayout" : @YES}, NULL) ==
                InumaLowLatencyVideoPlayoutParseResultInvalid,
            @"a missing output pointer must fail closed");

    Require([InumaLowLatencyVideoPlayoutFieldTrials() isEqualToString:
                 @"WebRTC-Network-UseNWPathMonitor/Enabled/"
                  "WebRTC-ForcePlayoutDelay/min_ms:0,max_ms:10/"
                  "WebRTC-ZeroPlayoutDelay/min_pacing:16ms,"
                  "max_decode_queue_size:5/"
                  "WebRTC-NackInitialRttMs/20/"],
            @"the field-trial policy must remain exact");
    Require(InumaLowLatencyVideoPlayoutForcedMinimumMs() == 0,
            @"forced minimum must remain zero milliseconds");
    Require(InumaLowLatencyVideoPlayoutForcedMaximumMs() == 10,
            @"forced maximum must remain ten milliseconds");
    Require(InumaLowLatencyVideoPlayoutMinimumPacingMs() == 16,
            @"minimum pacing must remain sixteen milliseconds");
    Require(InumaLowLatencyVideoPlayoutMaximumDecodeQueueSize() == 5,
            @"decode queue cap must remain five frames");
    Require(InumaLowLatencyVideoPlayoutInitialNackRttMs() == 20,
            @"initial NACK RTT must remain twenty milliseconds");

    InumaRecordLowLatencyVideoPlayoutConfiguration(NO);
    Require(InumaLowLatencyVideoPlayoutEnabledConfigurationCount() == 0,
            @"disabled configuration must not increment enabled proof");
    InumaRecordLowLatencyVideoPlayoutConfiguration(YES);
    Require(InumaLowLatencyVideoPlayoutEnabledConfigurationCount() == 1,
            @"the enabled configuration must be counted once");
  }
  return 0;
}
