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
    return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
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

@implementation InumaStrictReplayPacer {
  os_unfair_lock _lock;
  InumaHostTimeClockBlock _hostTimeClock;
  uint64_t* _scheduledPresentationTimesNs;
  NSUInteger _queueHead;
  NSUInteger _queueCount;
  BOOL _timelineStarted;
  BOOL _stopped;
  uint64_t _firstGeneration;
  uint64_t _lastAcceptedGeneration;
  uint64_t _anchorPresentationTimeNs;
  uint64_t _acceptedCount;
  uint64_t _lateCount;
  uint64_t _overflowCount;
  uint64_t _generationSequenceFailureCount;
  uint64_t _addedLatencyViolationCount;
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

  uint64_t scheduledAtNs = 0;
  if (!_timelineStarted) {
    if (UINT64_MAX - arrivedAtNs < _presentationReserveNs) {
      os_unfair_lock_unlock(&_lock);
      return decision;
    }
    scheduledAtNs = arrivedAtNs + _presentationReserveNs;
    decision.timelineStarted = YES;
    decision.generationSequenceValid = YES;
  } else {
    if (generation != _lastAcceptedGeneration + 1 ||
        generation < _firstGeneration) {
      _generationSequenceFailureCount += 1;
      decision.generationSequenceValid = NO;
      os_unfair_lock_unlock(&_lock);
      return decision;
    }
    decision.generationSequenceValid = YES;
    const uint64_t index = generation - _firstGeneration;
    if (index > UINT64_MAX / _frameIntervalNs) {
      os_unfair_lock_unlock(&_lock);
      return decision;
    }
    const uint64_t offset = index * _frameIntervalNs;
    if (UINT64_MAX - _anchorPresentationTimeNs < offset) {
      os_unfair_lock_unlock(&_lock);
      return decision;
    }
    scheduledAtNs = _anchorPresentationTimeNs + offset;
  }
  decision.scheduledPresentationTimeNs = scheduledAtNs;
  if (scheduledAtNs <= arrivedAtNs) {
    decision.late = YES;
    decision.latenessNs = arrivedAtNs - scheduledAtNs;
    _lateCount += 1;
    os_unfair_lock_unlock(&_lock);
    return decision;
  }
  decision.presentationResidenceNs = scheduledAtNs - arrivedAtNs;
  if (decision.presentationResidenceNs > _maximumAddedLatencyNs) {
    decision.addedLatencyExceeded = YES;
    _addedLatencyViolationCount += 1;
    os_unfair_lock_unlock(&_lock);
    return decision;
  }
  if (_queueCount >= _queueCapacity) {
    decision.overflowed = YES;
    _overflowCount += 1;
    os_unfair_lock_unlock(&_lock);
    return decision;
  }
  if (!_timelineStarted) {
    _timelineStarted = YES;
    _firstGeneration = generation;
    _anchorPresentationTimeNs = scheduledAtNs;
  }
  const NSUInteger tail = (_queueHead + _queueCount) % _queueCapacity;
  _scheduledPresentationTimesNs[tail] = scheduledAtNs;
  _queueCount += 1;
  _lastAcceptedGeneration = generation;
  _acceptedCount += 1;
  _queueDepthHighWater = MAX(_queueDepthHighWater, _queueCount);
  decision.accepted = YES;
  decision.queueDepthAfter = _queueCount;
  os_unfair_lock_unlock(&_lock);
  return decision;
}

- (uint64_t)acceptedCount {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _acceptedCount;
  os_unfair_lock_unlock(&_lock);
  return value;
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
  _firstGeneration = 0;
  _lastAcceptedGeneration = 0;
  _anchorPresentationTimeNs = 0;
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
