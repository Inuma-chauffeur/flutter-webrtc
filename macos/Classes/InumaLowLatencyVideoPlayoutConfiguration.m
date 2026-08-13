#import "InumaLowLatencyVideoPlayoutConfiguration.h"

#import <CoreFoundation/CoreFoundation.h>

#include <stdatomic.h>

static atomic_uint_fast64_t
    gInumaLowLatencyVideoPlayoutEnabledConfigurationCount = 0;

InumaLowLatencyVideoPlayoutParseResult
InumaParseLowLatencyVideoPlayoutConfiguration(NSDictionary* options,
                                               BOOL* enabled) {
  if (enabled == NULL) {
    return InumaLowLatencyVideoPlayoutParseResultInvalid;
  }

  id value = options[@"lowLatencyVideoPlayout"];
  if (value == nil) {
    return InumaLowLatencyVideoPlayoutParseResultAbsent;
  }
  if (![value isKindOfClass:[NSNumber class]] ||
      CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) {
    return InumaLowLatencyVideoPlayoutParseResultInvalid;
  }

  *enabled = [value boolValue];
  return InumaLowLatencyVideoPlayoutParseResultValid;
}

NSString* InumaLowLatencyVideoPlayoutFieldTrials(void) {
  return @"WebRTC-Network-UseNWPathMonitor/Enabled/"
          "WebRTC-ForcePlayoutDelay/min_ms:0,max_ms:10/"
          "WebRTC-ZeroPlayoutDelay/min_pacing:16ms,max_decode_queue_size:5/"
          "WebRTC-NackInitialRttMs/20/";
}

NSInteger InumaLowLatencyVideoPlayoutForcedMinimumMs(void) {
  return 0;
}

NSInteger InumaLowLatencyVideoPlayoutForcedMaximumMs(void) {
  return 10;
}

NSInteger InumaLowLatencyVideoPlayoutMinimumPacingMs(void) {
  return 16;
}

NSInteger InumaLowLatencyVideoPlayoutMaximumDecodeQueueSize(void) {
  return 5;
}

NSInteger InumaLowLatencyVideoPlayoutInitialNackRttMs(void) {
  return 20;
}

void InumaRecordLowLatencyVideoPlayoutConfiguration(BOOL enabled) {
  if (enabled) {
    atomic_fetch_add_explicit(
        &gInumaLowLatencyVideoPlayoutEnabledConfigurationCount,
        1,
        memory_order_relaxed);
  }
}

uint64_t InumaLowLatencyVideoPlayoutEnabledConfigurationCount(void) {
  return atomic_load_explicit(
      &gInumaLowLatencyVideoPlayoutEnabledConfigurationCount,
      memory_order_relaxed);
}
