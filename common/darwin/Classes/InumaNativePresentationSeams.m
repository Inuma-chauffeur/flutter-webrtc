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

- (CMSampleBufferRef)copyImmediateSampleBufferFromPixelBuffer:
    (CVPixelBufferRef)pixelBuffer {
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
  CMSampleTimingInfo timing = kCMTimingInfoInvalid;
  status = CMSampleBufferCreateReadyWithImageBuffer(
      kCFAllocatorDefault, pixelBuffer, formatDescription, &timing, &sampleBuffer);
  CFRelease(formatDescription);
  if (status != noErr || sampleBuffer == nil) {
    return nil;
  }

  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
  if (attachments != nil && CFArrayGetCount(attachments) > 0) {
    CFMutableDictionaryRef dictionary =
        (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    if (dictionary != nil) {
      CFDictionarySetValue(dictionary, kCMSampleAttachmentKey_DisplayImmediately,
                           kCFBooleanTrue);
    }
  }
  return sampleBuffer;
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

  const uint64_t startedAtNs = traceSink == nil ? 0 : [clock nowNanoseconds];
  result.accepted = YES;
  if ([backend requiresFlushToResumeDecoding]) {
    [backend flushRemovingDisplayedImage];
    result.flushedBeforeEnqueue = YES;
  }
  result.readyBeforeEnqueue = [backend readyForMoreMediaData];
  [backend enqueueSampleBuffer:sampleBuffer generation:generation];
  result.failedAfterEnqueue = [backend failed];
  if (traceSink != nil) {
    [traceSink recordGeneration:generation
                   startedAtNs:startedAtNs
                 completedAtNs:[clock nowNanoseconds]
                        result:result];
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
