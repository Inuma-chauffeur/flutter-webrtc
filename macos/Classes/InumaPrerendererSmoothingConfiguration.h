#import <Foundation/Foundation.h>

#include <stdint.h>

typedef NS_ENUM(NSUInteger, InumaPrerendererSmoothingParseResult) {
  InumaPrerendererSmoothingParseResultAbsent = 0,
  InumaPrerendererSmoothingParseResultValid = 1,
  InumaPrerendererSmoothingParseResultInvalid = 2,
};

FOUNDATION_EXPORT InumaPrerendererSmoothingParseResult
InumaParsePrerendererSmoothingConfiguration(
    NSDictionary* _Nullable configuration,
    BOOL* _Nullable enabled);

/// Records that an explicitly parsed value reached RTCConfiguration.
///
/// The cumulative disabled count is intentionally process-global so the
/// renderer's retained scalar trace can prove the media peer applied the
/// custom SDK bridge without retaining endpoints, credentials, or payloads.
FOUNDATION_EXPORT void
InumaRecordPrerendererSmoothingConfiguration(BOOL enabled);

FOUNDATION_EXPORT uint64_t
InumaPrerendererSmoothingDisabledConfigurationCount(void);
