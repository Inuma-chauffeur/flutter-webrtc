#import "InumaNativePresentationSeams.h"

#include <os/lock.h>
#include <stdbool.h>
#include <stdlib.h>
#include <time.h>

#if TARGET_OS_OSX

@implementation InumaMonotonicClock {
  InumaMonotonicClockBlock _nowBlock;
}

- (instancetype)initWithNowBlock:(InumaMonotonicClockBlock)nowBlock {
  self = [super init];
  if (self) {
    _nowBlock = [nowBlock copy];
  }
  return self;
}

- (uint64_t)nowNanoseconds {
  return _nowBlock();
}

+ (instancetype)systemClock {
  return [[self alloc] initWithNowBlock:^{
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  }];
}

@end

@implementation InumaVideoSampleBuilder

static CMSampleBufferRef InumaCopySampleBufferWithTiming(
    CVPixelBufferRef pixelBuffer, CMSampleTimingInfo timing,
    BOOL displayImmediately) {
  if (pixelBuffer == nil) {
    return nil;
  }
  CMVideoFormatDescriptionRef formatDescription = nil;
  OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(
      kCFAllocatorDefault, pixelBuffer, &formatDescription);
  if (status != noErr || formatDescription == nil) {
    return nil;
  }

  CMSampleBufferRef sampleBuffer = nil;
  status = CMSampleBufferCreateReadyWithImageBuffer(
      kCFAllocatorDefault, pixelBuffer, formatDescription, &timing, &sampleBuffer);
  CFRelease(formatDescription);
  if (status != noErr || sampleBuffer == nil) {
    return nil;
  }

  if (displayImmediately) {
    CFArrayRef attachments =
        CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
    if (attachments != nil && CFArrayGetCount(attachments) > 0) {
      CFMutableDictionaryRef dictionary =
          (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
      if (dictionary != nil) {
        CFDictionarySetValue(dictionary,
                             kCMSampleAttachmentKey_DisplayImmediately,
                             kCFBooleanTrue);
      }
    }
  }
  return sampleBuffer;
}

- (CMSampleBufferRef)copyImmediateSampleBufferFromPixelBuffer:
    (CVPixelBufferRef)pixelBuffer {
  CMSampleTimingInfo timing = kCMTimingInfoInvalid;
  return InumaCopySampleBufferWithTiming(pixelBuffer, timing, YES);
}

- (CMSampleBufferRef)copyTimedSampleBufferFromPixelBuffer:
                          (CVPixelBufferRef)pixelBuffer
                            presentationTimeNs:(uint64_t)presentationTimeNs
                                 durationNs:(uint64_t)durationNs {
  if (presentationTimeNs == 0 || presentationTimeNs > INT64_MAX ||
      durationNs == 0 || durationNs > INT64_MAX) {
    return nil;
  }
  CMSampleTimingInfo timing = {
      .duration = CMTimeMake((int64_t)durationNs, 1000000000),
      .presentationTimeStamp =
          CMTimeMake((int64_t)presentationTimeNs, 1000000000),
      .decodeTimeStamp = kCMTimeInvalid,
  };
  return InumaCopySampleBufferWithTiming(pixelBuffer, timing, NO);
}

@end

static uint64_t InumaSystemHostTimeNanoseconds(void) {
  const CMTime hostTime = CMClockGetTime(CMClockGetHostTimeClock());
  const CMTime nanoseconds =
      CMTimeConvertScale(hostTime, 1000000000, kCMTimeRoundingMethod_Default);
  return CMTIME_IS_NUMERIC(nanoseconds) && nanoseconds.value > 0
             ? (uint64_t)nanoseconds.value
             : 0;
}

static const uint64_t kInumaStrictReplayMinimumPresentationIntervalNs =
    25000000;
static const uint64_t kInumaStrictReplayMaximumPresentationIntervalNs =
    66666666;
static const uint64_t kInumaStrictReplayMinimumPresentationLeadNs = 8333333;
static const uint64_t kInumaStrictReplayStableCadenceIntervalMinimumNs =
    25000000;
static const uint64_t kInumaStrictReplayStableCadenceIntervalMaximumNs =
    42000000;
static const NSUInteger kInumaStrictReplayRequiredStableCadenceIntervals = 3;
static const uint64_t kInumaDisplayRefreshPeriodMinimumNs = 8000000;
static const uint64_t kInumaDisplayRefreshPeriodMaximumNs = 25000000;
static const uint64_t kInumaDisplayPhaseMaximumAgeNs = 250000000;

@implementation InumaStrictReplayPacer {
  os_unfair_lock _lock;
  InumaHostTimeClockBlock _hostTimeClock;
  uint64_t* _scheduledPresentationTimesNs;
  NSUInteger _queueHead;
  NSUInteger _queueCount;
  BOOL _timelineStarted;
  BOOL _stopped;
  uint64_t _lastObservedGeneration;
  uint64_t _lastArrivalNs;
  uint64_t _lastScheduledPresentationTimeNs;
  NSUInteger _stableCadenceIntervalCount;
  uint64_t _armedGeneration;
  uint64_t _lastArmedGeneration;
  uint64_t _armCount;
  uint64_t _rearmCount;
  uint64_t _rearmPrearmDiscardCount;
  BOOL _rearmPending;
  uint64_t _acceptedCount;
  uint64_t _prearmDiscardCount;
  uint64_t _latePhaseCorrectionCount;
  uint64_t _earlyPhaseCorrectionCount;
  uint64_t _lateCount;
  uint64_t _overflowCount;
  uint64_t _generationSequenceFailureCount;
  uint64_t _addedLatencyViolationCount;
  uint64_t _displayPhaseTimestampNs;
  uint64_t _displayPhaseTargetTimeNs;
  uint64_t _displayRefreshPeriodNs;
  uint64_t _displayPhaseUpdateCount;
  uint64_t _displayPhaseAlignmentCount;
  uint64_t _displayPhaseFallbackCount;
  uint64_t _lastAlignedDisplayPhaseTimestampNs;
  uint64_t _lastAlignedDisplayPhaseTargetTimeNs;
  uint64_t _lastAlignedDisplayRefreshPeriodNs;
  uint64_t _lastAlignedDisplaySafetyLeadNs;
  NSUInteger _queueDepthHighWater;
}

- (instancetype)initWithPresentationReserveNs:(uint64_t)reserveNs
                                frameIntervalNs:(uint64_t)frameIntervalNs
                                  queueCapacity:(NSUInteger)queueCapacity
                                  hostTimeClock:
                                      (InumaHostTimeClockBlock)hostTimeClock {
  if (reserveNs == 0 || reserveNs > 100000000 || frameIntervalNs == 0 ||
      queueCapacity == 0 || queueCapacity > 16) {
    return nil;
  }
  self = [super init];
  if (self) {
    _lock = OS_UNFAIR_LOCK_INIT;
    _presentationReserveNs = reserveNs;
    _maximumAddedLatencyNs = 100000000;
    _frameIntervalNs = frameIntervalNs;
    _queueCapacity = queueCapacity;
    _hostTimeClock = [hostTimeClock copy];
    if (_hostTimeClock == nil) {
      _hostTimeClock = ^uint64_t {
        return InumaSystemHostTimeNanoseconds();
      };
    }
    _scheduledPresentationTimesNs =
        calloc(queueCapacity, sizeof(*_scheduledPresentationTimesNs));
    if (_scheduledPresentationTimesNs == nil) {
      return nil;
    }
  }
  return self;
}

- (void)dealloc {
  free(_scheduledPresentationTimesNs);
}

- (void)prunePresentedTimesLockedAtNs:(uint64_t)nowNs {
  while (_queueCount > 0 &&
         _scheduledPresentationTimesNs[_queueHead] <= nowNs) {
    _queueHead = (_queueHead + 1) % _queueCapacity;
    _queueCount -= 1;
  }
}

- (BOOL)invalidateStartedTimelineLocked {
  if (!_timelineStarted) {
    _stableCadenceIntervalCount = 0;
    return NO;
  }
  _timelineStarted = NO;
  _queueHead = 0;
  _queueCount = 0;
  _lastScheduledPresentationTimeNs = 0;
  _stableCadenceIntervalCount = 0;
  _rearmPending = YES;
  _rearmCount += 1;
  return YES;
}

- (void)recordPrearmDiscardLockedForDecision:
    (InumaStrictReplayPacingDecision*)decision {
  _prearmDiscardCount += 1;
  decision->prearmDiscarded = YES;
  if (_rearmPending) {
    _rearmPrearmDiscardCount += 1;
    decision->rearmPrearmDiscarded = YES;
  }
}

- (BOOL)updateDisplayPhaseTimestampNs:(uint64_t)timestampNs
                         targetTimeNs:(uint64_t)targetTimeNs
                      refreshPeriodNs:(uint64_t)refreshPeriodNs {
  if (timestampNs == 0 || targetTimeNs <= timestampNs ||
      refreshPeriodNs < kInumaDisplayRefreshPeriodMinimumNs ||
      refreshPeriodNs > kInumaDisplayRefreshPeriodMaximumNs ||
      targetTimeNs - timestampNs > refreshPeriodNs * 2) {
    return NO;
  }
  os_unfair_lock_lock(&_lock);
  if (_stopped || timestampNs <= _displayPhaseTimestampNs ||
      targetTimeNs <= _displayPhaseTargetTimeNs) {
    os_unfair_lock_unlock(&_lock);
    return NO;
  }
  _displayPhaseTimestampNs = timestampNs;
  _displayPhaseTargetTimeNs = targetTimeNs;
  _displayRefreshPeriodNs = refreshPeriodNs;
  _displayPhaseUpdateCount += 1;
  os_unfair_lock_unlock(&_lock);
  return YES;
}

- (BOOL)alignInitialPresentationTimeLockedFromArrivalNs:(uint64_t)arrivedAtNs
                                            idealTimeNs:(uint64_t)idealTimeNs
                                               decision:
                                                   (InumaStrictReplayPacingDecision*)decision
                                         alignedTimeNs:(uint64_t*)alignedTimeNs {
  const uint64_t targetTimeNs = _displayPhaseTargetTimeNs;
  const uint64_t refreshPeriodNs = _displayRefreshPeriodNs;
  if (_displayPhaseTimestampNs == 0 || targetTimeNs == 0 ||
      refreshPeriodNs < kInumaDisplayRefreshPeriodMinimumNs ||
      refreshPeriodNs > kInumaDisplayRefreshPeriodMaximumNs ||
      arrivedAtNs < _displayPhaseTimestampNs ||
      arrivedAtNs - _displayPhaseTimestampNs >
          kInumaDisplayPhaseMaximumAgeNs) {
    return NO;
  }

  const uint64_t safetyLeadNs = refreshPeriodNs / 2;
  if (safetyLeadNs == 0 || targetTimeNs <= safetyLeadNs) {
    return NO;
  }
  uint64_t candidateNs = targetTimeNs - safetyLeadNs;
  if (candidateNs > idealTimeNs) {
    const uint64_t distanceNs = candidateNs - idealTimeNs;
    const uint64_t periods =
        distanceNs / refreshPeriodNs +
        (distanceNs % refreshPeriodNs == 0 ? 0 : 1);
    if (periods > candidateNs / refreshPeriodNs) {
      return NO;
    }
    candidateNs -= periods * refreshPeriodNs;
  } else {
    const uint64_t periods = (idealTimeNs - candidateNs) / refreshPeriodNs;
    if (periods > (UINT64_MAX - candidateNs) / refreshPeriodNs) {
      return NO;
    }
    candidateNs += periods * refreshPeriodNs;
  }

  if (UINT64_MAX - arrivedAtNs < kInumaStrictReplayMinimumPresentationLeadNs ||
      candidateNs < arrivedAtNs + kInumaStrictReplayMinimumPresentationLeadNs ||
      candidateNs > idealTimeNs) {
    return NO;
  }
  if (candidateNs > UINT64_MAX - safetyLeadNs) {
    return NO;
  }
  decision->displayPhaseAligned = YES;
  decision->displayPhaseTimestampNs = _displayPhaseTimestampNs;
  decision->displayPhaseTargetTimeNs = candidateNs + safetyLeadNs;
  decision->displayRefreshPeriodNs = refreshPeriodNs;
  decision->displaySafetyLeadNs = safetyLeadNs;
  *alignedTimeNs = candidateNs;
  return YES;
}

- (InumaStrictReplayPacingDecision)decisionForGeneration:(uint64_t)generation {
  InumaStrictReplayPacingDecision decision = {0};
  const uint64_t arrivedAtNs = _hostTimeClock();
  decision.arrivedAtHostTimeNs = arrivedAtNs;
  if (arrivedAtNs == 0 || generation == 0) {
    return decision;
  }

  os_unfair_lock_lock(&_lock);
  if (_stopped) {
    os_unfair_lock_unlock(&_lock);
    return decision;
  }
  [self prunePresentedTimesLockedAtNs:arrivedAtNs];
  decision.queueDepthBefore = _queueCount;

  if (_lastObservedGeneration == 0) {
    _lastObservedGeneration = generation;
    _lastArrivalNs = arrivedAtNs;
    [self recordPrearmDiscardLockedForDecision:&decision];
    decision.generationSequenceValid = YES;
    os_unfair_lock_unlock(&_lock);
    return decision;
  }
  if (generation != _lastObservedGeneration + 1 ||
      arrivedAtNs <= _lastArrivalNs) {
    _generationSequenceFailureCount += 1;
    decision.generationSequenceValid = NO;
    _lastObservedGeneration = generation;
    _lastArrivalNs = arrivedAtNs;
    decision.rearmTriggered = [self invalidateStartedTimelineLocked];
    os_unfair_lock_unlock(&_lock);
    return decision;
  }
  decision.generationSequenceValid = YES;
  const uint64_t arrivalIntervalNs = arrivedAtNs - _lastArrivalNs;
  _lastObservedGeneration = generation;
  _lastArrivalNs = arrivedAtNs;

  uint64_t scheduledAtNs = 0;
  if (!_timelineStarted) {
    if (arrivalIntervalNs >= kInumaStrictReplayStableCadenceIntervalMinimumNs &&
        arrivalIntervalNs <= kInumaStrictReplayStableCadenceIntervalMaximumNs) {
      _stableCadenceIntervalCount += 1;
    } else {
      _stableCadenceIntervalCount = 0;
    }
    if (_stableCadenceIntervalCount <
        kInumaStrictReplayRequiredStableCadenceIntervals) {
      [self recordPrearmDiscardLockedForDecision:&decision];
      os_unfair_lock_unlock(&_lock);
      return decision;
    }
    if (UINT64_MAX - arrivedAtNs < _presentationReserveNs) {
      os_unfair_lock_unlock(&_lock);
      return decision;
    }
    const uint64_t idealAtNs = arrivedAtNs + _presentationReserveNs;
    scheduledAtNs = idealAtNs;
    if ([self alignInitialPresentationTimeLockedFromArrivalNs:arrivedAtNs
                                                  idealTimeNs:idealAtNs
                                                     decision:&decision
                                               alignedTimeNs:&scheduledAtNs]) {
      _displayPhaseAlignmentCount += 1;
      _lastAlignedDisplayPhaseTimestampNs = decision.displayPhaseTimestampNs;
      _lastAlignedDisplayPhaseTargetTimeNs =
          decision.displayPhaseTargetTimeNs;
      _lastAlignedDisplayRefreshPeriodNs = decision.displayRefreshPeriodNs;
      _lastAlignedDisplaySafetyLeadNs = decision.displaySafetyLeadNs;
    } else {
      _displayPhaseFallbackCount += 1;
    }
    decision.timelineStarted = YES;
  } else {
    if (UINT64_MAX - _lastScheduledPresentationTimeNs < _frameIntervalNs ||
        UINT64_MAX - arrivedAtNs < kInumaStrictReplayMinimumPresentationLeadNs ||
        UINT64_MAX - arrivedAtNs < _maximumAddedLatencyNs ||
        UINT64_MAX - _lastScheduledPresentationTimeNs <
            kInumaStrictReplayMinimumPresentationIntervalNs) {
      os_unfair_lock_unlock(&_lock);
      return decision;
    }
    const uint64_t idealAtNs =
        _lastScheduledPresentationTimeNs + _frameIntervalNs;
    const uint64_t leadFloorNs =
        arrivedAtNs + kInumaStrictReplayMinimumPresentationLeadNs;
    const uint64_t paceFloorNs = _lastScheduledPresentationTimeNs +
                                 kInumaStrictReplayMinimumPresentationIntervalNs;
    const uint64_t lowerBoundNs = MAX(leadFloorNs, paceFloorNs);
    const uint64_t upperBoundNs = arrivedAtNs + _maximumAddedLatencyNs;
    if (lowerBoundNs > upperBoundNs) {
      decision.late = YES;
      decision.latenessNs = lowerBoundNs - upperBoundNs;
      _lateCount += 1;
      decision.rearmTriggered = [self invalidateStartedTimelineLocked];
      os_unfair_lock_unlock(&_lock);
      return decision;
    }
    scheduledAtNs = MAX(idealAtNs, lowerBoundNs);
    if (scheduledAtNs > upperBoundNs) {
      scheduledAtNs = upperBoundNs;
      decision.earlyPhaseCorrected = YES;
    } else if (scheduledAtNs > idealAtNs) {
      decision.latePhaseCorrected = YES;
    }
    const uint64_t presentationIntervalNs =
        scheduledAtNs - _lastScheduledPresentationTimeNs;
    if (presentationIntervalNs >
        kInumaStrictReplayMaximumPresentationIntervalNs) {
      decision.late = YES;
      decision.latenessNs = presentationIntervalNs -
                            kInumaStrictReplayMaximumPresentationIntervalNs;
      _lateCount += 1;
      decision.rearmTriggered = [self invalidateStartedTimelineLocked];
      os_unfair_lock_unlock(&_lock);
      return decision;
    }
  }
  decision.scheduledPresentationTimeNs = scheduledAtNs;
  if (scheduledAtNs <= arrivedAtNs) {
    decision.late = YES;
    decision.latenessNs = arrivedAtNs - scheduledAtNs;
    _lateCount += 1;
    decision.rearmTriggered = [self invalidateStartedTimelineLocked];
    os_unfair_lock_unlock(&_lock);
    return decision;
  }
  decision.presentationResidenceNs = scheduledAtNs - arrivedAtNs;
  if (decision.presentationResidenceNs > _maximumAddedLatencyNs) {
    decision.addedLatencyExceeded = YES;
    _addedLatencyViolationCount += 1;
    decision.rearmTriggered = [self invalidateStartedTimelineLocked];
    os_unfair_lock_unlock(&_lock);
    return decision;
  }
  if (_queueCount >= _queueCapacity) {
    decision.overflowed = YES;
    _overflowCount += 1;
    decision.rearmTriggered = [self invalidateStartedTimelineLocked];
    os_unfair_lock_unlock(&_lock);
    return decision;
  }
  if (!_timelineStarted) {
    _timelineStarted = YES;
    _armCount += 1;
    _lastArmedGeneration = generation;
    if (_armedGeneration == 0) {
      _armedGeneration = generation;
    } else {
      decision.timelineRearmed = YES;
    }
    _rearmPending = NO;
  }
  const NSUInteger tail = (_queueHead + _queueCount) % _queueCapacity;
  _scheduledPresentationTimesNs[tail] = scheduledAtNs;
  _queueCount += 1;
  _lastScheduledPresentationTimeNs = scheduledAtNs;
  _acceptedCount += 1;
  _latePhaseCorrectionCount += decision.latePhaseCorrected ? 1 : 0;
  _earlyPhaseCorrectionCount += decision.earlyPhaseCorrected ? 1 : 0;
  _queueDepthHighWater = MAX(_queueDepthHighWater, _queueCount);
  decision.accepted = YES;
  decision.queueDepthAfter = _queueCount;
  os_unfair_lock_unlock(&_lock);
  return decision;
}

- (BOOL)invalidateTimelineAfterAcceptedGeneration:(uint64_t)generation {
  if (generation == 0) {
    return NO;
  }
  os_unfair_lock_lock(&_lock);
  const BOOL invalidated =
      !_stopped && generation >= _lastArmedGeneration &&
      [self invalidateStartedTimelineLocked];
  os_unfair_lock_unlock(&_lock);
  return invalidated;
}

- (uint64_t)acceptedCount {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _acceptedCount;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (InumaStrictReplayPacerSnapshot)snapshot {
  os_unfair_lock_lock(&_lock);
  const InumaStrictReplayPacerSnapshot value = {
      .acceptedCount = _acceptedCount,
      .prearmDiscardCount = _prearmDiscardCount,
      .latePhaseCorrectionCount = _latePhaseCorrectionCount,
      .earlyPhaseCorrectionCount = _earlyPhaseCorrectionCount,
      .armedGeneration = _armedGeneration,
      .lastArmedGeneration = _lastArmedGeneration,
      .armCount = _armCount,
      .rearmCount = _rearmCount,
      .rearmPrearmDiscardCount = _rearmPrearmDiscardCount,
      .lateCount = _lateCount,
      .overflowCount = _overflowCount,
      .generationSequenceFailureCount = _generationSequenceFailureCount,
      .addedLatencyViolationCount = _addedLatencyViolationCount,
      .displayPhaseUpdateCount = _displayPhaseUpdateCount,
      .displayPhaseAlignmentCount = _displayPhaseAlignmentCount,
      .displayPhaseFallbackCount = _displayPhaseFallbackCount,
      .displayPhaseTimestampNs = _displayPhaseTimestampNs,
      .displayPhaseTargetTimeNs = _displayPhaseTargetTimeNs,
      .displayRefreshPeriodNs = _displayRefreshPeriodNs,
      .lastAlignedDisplayPhaseTimestampNs =
          _lastAlignedDisplayPhaseTimestampNs,
      .lastAlignedDisplayPhaseTargetTimeNs =
          _lastAlignedDisplayPhaseTargetTimeNs,
      .lastAlignedDisplayRefreshPeriodNs =
          _lastAlignedDisplayRefreshPeriodNs,
      .lastAlignedDisplaySafetyLeadNs = _lastAlignedDisplaySafetyLeadNs,
      .queueDepthHighWater = _queueDepthHighWater,
  };
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)prearmDiscardCount {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _prearmDiscardCount;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)latePhaseCorrectionCount {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _latePhaseCorrectionCount;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)earlyPhaseCorrectionCount {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _earlyPhaseCorrectionCount;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)armedGeneration {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _armedGeneration;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)lastArmedGeneration {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _lastArmedGeneration;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)armCount {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _armCount;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)rearmCount {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _rearmCount;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)rearmPrearmDiscardCount {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _rearmPrearmDiscardCount;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)minimumPresentationIntervalNs {
  return kInumaStrictReplayMinimumPresentationIntervalNs;
}

- (uint64_t)maximumPresentationIntervalNs {
  return kInumaStrictReplayMaximumPresentationIntervalNs;
}

- (uint64_t)minimumPresentationLeadNs {
  return kInumaStrictReplayMinimumPresentationLeadNs;
}

- (uint64_t)stableCadenceIntervalMinimumNs {
  return kInumaStrictReplayStableCadenceIntervalMinimumNs;
}

- (uint64_t)stableCadenceIntervalMaximumNs {
  return kInumaStrictReplayStableCadenceIntervalMaximumNs;
}

- (NSUInteger)requiredStableCadenceIntervals {
  return kInumaStrictReplayRequiredStableCadenceIntervals;
}

- (uint64_t)lateCount {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _lateCount;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)overflowCount {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _overflowCount;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)generationSequenceFailureCount {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _generationSequenceFailureCount;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)addedLatencyViolationCount {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _addedLatencyViolationCount;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)displayPhaseUpdateCount {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _displayPhaseUpdateCount;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)displayPhaseAlignmentCount {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _displayPhaseAlignmentCount;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)displayPhaseFallbackCount {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _displayPhaseFallbackCount;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)displayPhaseTimestampNs {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _displayPhaseTimestampNs;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)displayPhaseTargetTimeNs {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _displayPhaseTargetTimeNs;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)displayRefreshPeriodNs {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _displayRefreshPeriodNs;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)lastAlignedDisplayPhaseTimestampNs {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _lastAlignedDisplayPhaseTimestampNs;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)lastAlignedDisplayPhaseTargetTimeNs {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _lastAlignedDisplayPhaseTargetTimeNs;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)lastAlignedDisplayRefreshPeriodNs {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _lastAlignedDisplayRefreshPeriodNs;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)lastAlignedDisplaySafetyLeadNs {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _lastAlignedDisplaySafetyLeadNs;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (NSUInteger)queueDepthHighWater {
  os_unfair_lock_lock(&_lock);
  const NSUInteger value = _queueDepthHighWater;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (void)stop {
  os_unfair_lock_lock(&_lock);
  _stopped = YES;
  _queueHead = 0;
  _queueCount = 0;
  os_unfair_lock_unlock(&_lock);
}

- (void)reset {
  os_unfair_lock_lock(&_lock);
  _stopped = NO;
  _queueHead = 0;
  _queueCount = 0;
  _timelineStarted = NO;
  _lastObservedGeneration = 0;
  _lastArrivalNs = 0;
  _lastScheduledPresentationTimeNs = 0;
  _stableCadenceIntervalCount = 0;
  _armedGeneration = 0;
  _lastArmedGeneration = 0;
  _rearmPending = NO;
  os_unfair_lock_unlock(&_lock);
}

@end

@implementation InumaAVSampleRendererBackend {
  AVSampleBufferVideoRenderer* _renderer;
}

- (instancetype)initWithRenderer:(AVSampleBufferVideoRenderer*)renderer {
  self = [super init];
  if (self) {
    _renderer = renderer;
  }
  return self;
}

- (BOOL)requiresFlushToResumeDecoding {
  return _renderer.requiresFlushToResumeDecoding;
}

- (void)flushRemovingDisplayedImage {
  [_renderer flushWithRemovalOfDisplayedImage:YES completionHandler:nil];
}

- (BOOL)readyForMoreMediaData {
  return _renderer.readyForMoreMediaData;
}

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer
                 generation:(uint64_t)generation {
  (void)generation;
  [_renderer enqueueSampleBuffer:sampleBuffer];
}

- (BOOL)failed {
  return _renderer.status == AVQueuedSampleBufferRenderingStatusFailed;
}

- (int32_t)rendererStatus {
  return (int32_t)_renderer.status;
}

- (int32_t)rendererErrorDomainClass {
  NSError* error = _renderer.error;
  if (error == nil) return InumaRendererErrorDomainNone;
  return [error.domain hasPrefix:@"AVFoundation"]
             ? InumaRendererErrorDomainAVFoundation
             : InumaRendererErrorDomainOther;
}

- (int64_t)rendererErrorCode {
  return (int64_t)_renderer.error.code;
}

@end

typedef struct {
  uint64_t generation;
  uint64_t started_at_ns;
  uint64_t completed_at_ns;
  bool accepted;
  bool flushed_before_enqueue;
  bool ready_before_enqueue;
  bool failed_after_enqueue;
} InumaPresentationTraceRecord;

@implementation InumaBoundedPresentationTraceSink {
  os_unfair_lock _lock;
  InumaPresentationTraceRecord* _records;
  NSUInteger _count;
  NSUInteger _capacityExhaustions;
}

- (instancetype)initWithCapacity:(NSUInteger)capacity {
  self = [super init];
  if (self) {
    _lock = OS_UNFAIR_LOCK_INIT;
    _capacity = capacity;
    _records = capacity == 0 ? nil : calloc(capacity, sizeof(*_records));
    if (capacity > 0 && _records == nil) {
      return nil;
    }
  }
  return self;
}

- (void)dealloc {
  free(_records);
}

- (NSUInteger)count {
  os_unfair_lock_lock(&_lock);
  const NSUInteger value = _count;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (NSUInteger)capacityExhaustions {
  os_unfair_lock_lock(&_lock);
  const NSUInteger value = _capacityExhaustions;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (void)recordGeneration:(uint64_t)generation
             startedAtNs:(uint64_t)startedAtNs
           completedAtNs:(uint64_t)completedAtNs
                  result:(InumaRendererSubmissionResult)result {
  os_unfair_lock_lock(&_lock);
  if (_count >= _capacity) {
    _capacityExhaustions += 1;
    os_unfair_lock_unlock(&_lock);
    return;
  }
  InumaPresentationTraceRecord* record = &_records[_count++];
  record->generation = generation;
  record->started_at_ns = startedAtNs;
  record->completed_at_ns = completedAtNs;
  record->accepted = result.accepted;
  record->flushed_before_enqueue = result.flushedBeforeEnqueue;
  record->ready_before_enqueue = result.readyBeforeEnqueue;
  record->failed_after_enqueue = result.failedAfterEnqueue;
  os_unfair_lock_unlock(&_lock);
}

- (NSArray<NSDictionary<NSString*, NSNumber*>*>*)snapshot {
  os_unfair_lock_lock(&_lock);
  NSMutableArray<NSDictionary<NSString*, NSNumber*>*>* rows =
      [NSMutableArray arrayWithCapacity:_count];
  for (NSUInteger index = 0; index < _count; index++) {
    const InumaPresentationTraceRecord record = _records[index];
    [rows addObject:@{
      @"generation" : @(record.generation),
      @"started_at_ns" : @(record.started_at_ns),
      @"completed_at_ns" : @(record.completed_at_ns),
      @"accepted" : @(record.accepted),
      @"flushed_before_enqueue" : @(record.flushed_before_enqueue),
      @"ready_before_enqueue" : @(record.ready_before_enqueue),
      @"failed_after_enqueue" : @(record.failed_after_enqueue),
    }];
  }
  os_unfair_lock_unlock(&_lock);
  return rows;
}

@end

@implementation InumaSampleRendererAdapter {
  os_unfair_lock _lock;
  id<InumaSampleRendererBackend> _backend;
  InumaMonotonicClock* _clock;
  id<InumaPresentationTraceSink> _traceSink;
  BOOL _stopped;
}

- (instancetype)initWithBackend:(id<InumaSampleRendererBackend>)backend
                           clock:(InumaMonotonicClock*)clock
                       traceSink:(id<InumaPresentationTraceSink>)traceSink {
  self = [super init];
  if (self) {
    _lock = OS_UNFAIR_LOCK_INIT;
    _backend = backend;
    _clock = clock;
    _traceSink = traceSink;
  }
  return self;
}

- (InumaRendererSubmissionResult)submitSampleBuffer:(CMSampleBufferRef)sampleBuffer
                                         generation:(uint64_t)generation {
  InumaPresentationFrameContext context = {0};
  context.renderOrdinal = generation == 0 ? 0 : generation - 1;
  context.nativeGeneration = generation;
  return [self submitSampleBuffer:sampleBuffer context:context];
}

- (InumaRendererSubmissionResult)submitSampleBuffer:(CMSampleBufferRef)sampleBuffer
                                            context:(InumaPresentationFrameContext)context {
  InumaRendererSubmissionResult result = {0};
  os_unfair_lock_lock(&_lock);
  if (_stopped) {
    os_unfair_lock_unlock(&_lock);
    return result;
  }
  id<InumaSampleRendererBackend> backend = _backend;
  id<InumaPresentationTraceSink> traceSink = _traceSink;
  InumaMonotonicClock* clock = _clock;
  os_unfair_lock_unlock(&_lock);

  const BOOL recordsRealtimeTrace =
      traceSink != nil &&
      [traceSink respondsToSelector:
          @selector(recordSubmissionBeginContext:atNs:)] &&
      [traceSink respondsToSelector:
          @selector(recordRendererFlushContext:atNs:result:)] &&
      [traceSink respondsToSelector:
          @selector(recordReadinessContext:atNs:result:)] &&
      [traceSink respondsToSelector:
          @selector(recordSubmissionEndContext:startedAtNs:completedAtNs:result:)];
  const uint64_t startedAtNs = traceSink == nil ? 0 : [clock nowNanoseconds];
  result.accepted = YES;
  if (recordsRealtimeTrace) {
    [traceSink recordSubmissionBeginContext:context atNs:startedAtNs];
  }
  if ([backend respondsToSelector:@selector(rendererStatus)]) {
    result.rendererStatusBeforeEnqueue = [backend rendererStatus];
  }
  if ([backend requiresFlushToResumeDecoding]) {
    [backend flushRemovingDisplayedImage];
    result.flushedBeforeEnqueue = YES;
    if (recordsRealtimeTrace) {
      [traceSink recordRendererFlushContext:context
                                      atNs:[clock nowNanoseconds]
                                     result:result];
    }
  }
  result.readyBeforeEnqueue = [backend readyForMoreMediaData];
  if (recordsRealtimeTrace) {
    [traceSink recordReadinessContext:context
                                 atNs:[clock nowNanoseconds]
                                result:result];
  }
  [backend enqueueSampleBuffer:sampleBuffer generation:context.nativeGeneration];
  result.failedAfterEnqueue = [backend failed];
  if ([backend respondsToSelector:@selector(rendererStatus)]) {
    result.rendererStatusAfterEnqueue = [backend rendererStatus];
  }
  if ([backend respondsToSelector:@selector(rendererErrorDomainClass)]) {
    result.rendererErrorDomainClass = [backend rendererErrorDomainClass];
  }
  if ([backend respondsToSelector:@selector(rendererErrorCode)]) {
    result.rendererErrorCode = [backend rendererErrorCode];
  }
  if (traceSink != nil) {
    const uint64_t completedAtNs = [clock nowNanoseconds];
    if (recordsRealtimeTrace) {
      [traceSink recordSubmissionEndContext:context
                                   startedAtNs:startedAtNs
                                 completedAtNs:completedAtNs
                                        result:result];
    } else if ([traceSink respondsToSelector:
            @selector(recordContext:startedAtNs:completedAtNs:result:)]) {
      [traceSink recordContext:context
                   startedAtNs:startedAtNs
                 completedAtNs:completedAtNs
                        result:result];
    } else {
      [traceSink recordGeneration:context.nativeGeneration
                     startedAtNs:startedAtNs
                   completedAtNs:completedAtNs
                          result:result];
    }
  }
  return result;
}

- (void)stop {
  os_unfair_lock_lock(&_lock);
  _stopped = YES;
  os_unfair_lock_unlock(&_lock);
}

- (void)reconnectWithBackend:(id<InumaSampleRendererBackend>)backend {
  os_unfair_lock_lock(&_lock);
  _backend = backend;
  _stopped = NO;
  os_unfair_lock_unlock(&_lock);
}

@end

#endif
