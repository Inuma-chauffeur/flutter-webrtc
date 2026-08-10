#import "InumaReceiverSchedulerTraceConfiguration.h"

#import <CoreFoundation/CoreFoundation.h>

InumaReceiverSchedulerTraceParseResult
InumaParseReceiverSchedulerTraceConfiguration(NSDictionary* options,
                                               BOOL* enabled) {
  if (enabled == NULL) {
    return InumaReceiverSchedulerTraceParseResultInvalid;
  }

  id value = options[@"receiverSchedulerTrace"];
  if (value == nil) {
    return InumaReceiverSchedulerTraceParseResultAbsent;
  }
  if (![value isKindOfClass:[NSNumber class]] ||
      CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) {
    return InumaReceiverSchedulerTraceParseResultInvalid;
  }

  *enabled = [value boolValue];
  return InumaReceiverSchedulerTraceParseResultValid;
}
