#import "InumaPrerendererSmoothingConfiguration.h"

#import <CoreFoundation/CoreFoundation.h>

#include <stdatomic.h>

static atomic_uint_fast64_t
    gInumaPrerendererSmoothingDisabledConfigurationCount = 0;

InumaPrerendererSmoothingParseResult
InumaParsePrerendererSmoothingConfiguration(NSDictionary* configuration,
                                             BOOL* enabled) {
  if (enabled == NULL) {
    return InumaPrerendererSmoothingParseResultInvalid;
  }

  id value = configuration[@"prerendererSmoothing"];
  if (value == nil) {
    return InumaPrerendererSmoothingParseResultAbsent;
  }
  if (![value isKindOfClass:[NSNumber class]] ||
      CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) {
    return InumaPrerendererSmoothingParseResultInvalid;
  }

  *enabled = [value boolValue];
  return InumaPrerendererSmoothingParseResultValid;
}

void InumaRecordPrerendererSmoothingConfiguration(BOOL enabled) {
  if (!enabled) {
    atomic_fetch_add_explicit(
        &gInumaPrerendererSmoothingDisabledConfigurationCount,
        1,
        memory_order_relaxed);
  }
}

uint64_t InumaPrerendererSmoothingDisabledConfigurationCount(void) {
  return atomic_load_explicit(
      &gInumaPrerendererSmoothingDisabledConfigurationCount,
      memory_order_relaxed);
}
