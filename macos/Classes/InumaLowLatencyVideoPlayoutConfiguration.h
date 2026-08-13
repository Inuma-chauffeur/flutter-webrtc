#import <Foundation/Foundation.h>

#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, InumaLowLatencyVideoPlayoutParseResult) {
  InumaLowLatencyVideoPlayoutParseResultAbsent = 0,
  InumaLowLatencyVideoPlayoutParseResultValid = 1,
  InumaLowLatencyVideoPlayoutParseResultInvalid = 2,
};

FOUNDATION_EXPORT InumaLowLatencyVideoPlayoutParseResult
InumaParseLowLatencyVideoPlayoutConfiguration(
    NSDictionary* _Nullable options,
    BOOL* _Nullable enabled);

/// Fixed, audited M144 receiver policy used only when the product opts in.
FOUNDATION_EXPORT NSString* InumaLowLatencyVideoPlayoutFieldTrials(void);
FOUNDATION_EXPORT NSInteger InumaLowLatencyVideoPlayoutForcedMinimumMs(void);
FOUNDATION_EXPORT NSInteger InumaLowLatencyVideoPlayoutForcedMaximumMs(void);
FOUNDATION_EXPORT NSInteger InumaLowLatencyVideoPlayoutMinimumPacingMs(void);
FOUNDATION_EXPORT NSInteger InumaLowLatencyVideoPlayoutMaximumDecodeQueueSize(void);
FOUNDATION_EXPORT NSInteger InumaLowLatencyVideoPlayoutInitialNackRttMs(void);
FOUNDATION_EXPORT NSInteger
InumaLowLatencyVideoPlayoutNackPeriodicIntervalMs(void);
FOUNDATION_EXPORT BOOL
InumaLowLatencyVideoPlayoutNackTimerHighPrecision(void);

/// Records that the opt-in reached the factory before it was constructed.
FOUNDATION_EXPORT void
InumaRecordLowLatencyVideoPlayoutConfiguration(BOOL enabled);

FOUNDATION_EXPORT uint64_t
InumaLowLatencyVideoPlayoutEnabledConfigurationCount(void);

NS_ASSUME_NONNULL_END
