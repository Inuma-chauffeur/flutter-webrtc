// Lock-bounded native presentation event storage and scalar serialization.

#import "InumaNativePresentationTrace.h"

#include <os/lock.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if TARGET_OS_OSX

typedef struct {
  uint64_t event_sequence;
  uint64_t monotonic_offset_ns;
  uint64_t source_identity;
  uint64_t render_ordinal;
  uint64_t native_generation;
  uint64_t rtp_timestamp;
  uint64_t pending_age_ns;
  uint64_t presentation_reserve_ns;
  uint64_t scheduled_presentation_time_ns;
  uint64_t presentation_residence_ns;
  uint64_t presentation_lateness_ns;
  uint64_t presentation_queue_depth;
  uint64_t duration_ns;
  uint64_t value;
  int64_t renderer_error_code;
  uint32_t kind;
  uint32_t timing_policy;
  int32_t renderer_status_before;
  int32_t renderer_status_after;
  int32_t renderer_error_domain_class;
  bool source_identity_valid;
  bool accepted;
  bool ready_before_enqueue;
  bool flushed_before_enqueue;
  bool failed_after_enqueue;
} InumaPresentationEventRecord;

typedef struct {
  uint64_t source_identity;
  InumaPresentationFrameContext context;
} InumaDisplayedFrameIdentityEntry;

enum {
  kInumaProductWatermarkOriginX = 128,
  kInumaProductWatermarkOriginY = 96,
  kInumaProductWatermarkColumns = 16,
  kInumaProductWatermarkRows = 8,
  kInumaProductWatermarkCellWidth = 6,
  kInumaProductWatermarkCellHeight = 12,
  kInumaProductWatermarkBits = 128,
};

static const uint16_t kInumaProductWatermarkSync = 0xDDAB;

static uint16_t InumaProductWatermarkChecksum(const uint8_t* bytes) {
  uint16_t checksum = 0xFFFF;
  for (NSUInteger index = 0; index < 14; index++) {
    checksum ^= (uint16_t)bytes[index] << 8;
    for (NSUInteger bit = 0; bit < 8; bit++) {
      checksum = (checksum & 0x8000) != 0
                     ? (uint16_t)((checksum << 1) ^ 0x1021)
                     : (uint16_t)(checksum << 1);
    }
  }
  return checksum;
}

static uint32_t InumaProductWatermarkUint32(const uint8_t* bytes,
                                            NSUInteger offset) {
  return ((uint32_t)bytes[offset] << 24) |
         ((uint32_t)bytes[offset + 1] << 16) |
         ((uint32_t)bytes[offset + 2] << 8) |
         (uint32_t)bytes[offset + 3];
}

InumaDisplayedFrameIdentityLookupResult InumaDecodeProductWatermark(
    CVPixelBufferRef pixelBuffer, InumaProductWatermarkIdentity* identity) {
  if (pixelBuffer == nil || identity == NULL) {
    return InumaDisplayedFrameIdentityLookupInvalid;
  }
  const OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
  const BOOL bgra = format == kCVPixelFormatType_32BGRA;
  const BOOL nv12 = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                    format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
  if (!bgra && !nv12) {
    return InumaDisplayedFrameIdentityLookupUnsupportedPixelFormat;
  }
  const CVPixelBufferLockFlags flags = kCVPixelBufferLock_ReadOnly;
  if (CVPixelBufferLockBaseAddress(pixelBuffer, flags) != kCVReturnSuccess) {
    return InumaDisplayedFrameIdentityLookupPixelBufferLockFailed;
  }
  const size_t width =
      nv12 ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
           : CVPixelBufferGetWidth(pixelBuffer);
  const size_t height =
      nv12 ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
           : CVPixelBufferGetHeight(pixelBuffer);
  const uint8_t* base =
      nv12 ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
           : CVPixelBufferGetBaseAddress(pixelBuffer);
  const size_t stride =
      nv12 ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
           : CVPixelBufferGetBytesPerRow(pixelBuffer);
  const size_t requiredWidth =
      kInumaProductWatermarkOriginX +
      kInumaProductWatermarkColumns * kInumaProductWatermarkCellWidth;
  const size_t requiredHeight =
      kInumaProductWatermarkOriginY +
      kInumaProductWatermarkRows * kInumaProductWatermarkCellHeight;
  const BOOL geometryValid = base != NULL && width >= requiredWidth &&
                             height >= requiredHeight &&
                             stride >= width * (bgra ? 4 : 1);
  if (!geometryValid) {
    CVPixelBufferUnlockBaseAddress(pixelBuffer, flags);
    return InumaDisplayedFrameIdentityLookupGeometryInvalid;
  }
  uint8_t cells[kInumaProductWatermarkBits] = {0};
  uint8_t low = UINT8_MAX;
  uint8_t high = 0;
  for (NSUInteger bit = 0; bit < kInumaProductWatermarkBits; bit++) {
    const size_t column = bit % kInumaProductWatermarkColumns;
    const size_t row = bit / kInumaProductWatermarkColumns;
    const size_t x = kInumaProductWatermarkOriginX +
                     column * kInumaProductWatermarkCellWidth +
                     kInumaProductWatermarkCellWidth / 2;
    const size_t y = kInumaProductWatermarkOriginY +
                     row * kInumaProductWatermarkCellHeight +
                     kInumaProductWatermarkCellHeight / 2;
    uint8_t value = base[y * stride + x];
    if (bgra) {
      const uint8_t* pixel = base + y * stride + x * 4;
      value = (uint8_t)(((uint32_t)pixel[2] * 54 +
                         (uint32_t)pixel[1] * 183 +
                         (uint32_t)pixel[0] * 19) >>
                        8);
    }
    cells[bit] = value;
    low = MIN(low, value);
    high = MAX(high, value);
  }
  CVPixelBufferUnlockBaseAddress(pixelBuffer, flags);
  if ((uint16_t)high - (uint16_t)low < 48) {
    return InumaDisplayedFrameIdentityLookupInsufficientContrast;
  }
  const uint16_t threshold = ((uint16_t)low + (uint16_t)high) / 2;
  uint8_t bytes[16] = {0};
  for (NSUInteger bit = 0; bit < kInumaProductWatermarkBits; bit++) {
    if ((uint16_t)cells[bit] >= threshold) {
      bytes[bit / 8] |= (uint8_t)(0x80 >> (bit % 8));
    }
  }
  const uint16_t sync = (uint16_t)((uint16_t)bytes[0] << 8) | bytes[1];
  if (sync != kInumaProductWatermarkSync) {
    return InumaDisplayedFrameIdentityLookupSyncMismatch;
  }
  const uint16_t checksum =
      (uint16_t)((uint16_t)bytes[14] << 8) | bytes[15];
  if (checksum != InumaProductWatermarkChecksum(bytes)) {
    return InumaDisplayedFrameIdentityLookupChecksumMismatch;
  }
  *identity = (InumaProductWatermarkIdentity){
      .frameIdentity = InumaProductWatermarkUint32(bytes, 2),
      .sourceSofUsLow = InumaProductWatermarkUint32(bytes, 6),
      .sourceEofUsLow = InumaProductWatermarkUint32(bytes, 10),
  };
  return InumaDisplayedFrameIdentityLookupFound;
}

InumaDisplayedFrameIdentityLookupResult
InumaBindProductWatermarkIdentityToContext(
    CVPixelBufferRef pixelBuffer,
    InumaPresentationFrameContext* _Nullable context) {
  if (context == NULL) return InumaDisplayedFrameIdentityLookupInvalid;
  context->sourceIdentity = 0;
  context->sourceIdentityValid = NO;
  InumaProductWatermarkIdentity identity = {0};
  const InumaDisplayedFrameIdentityLookupResult result =
      InumaDecodeProductWatermark(pixelBuffer, &identity);
  if (result == InumaDisplayedFrameIdentityLookupFound) {
    context->sourceIdentity = identity.frameIdentity;
    context->sourceIdentityValid = YES;
  }
  return result;
}

@implementation InumaDisplayedFrameIdentityLedger {
  os_unfair_lock _lock;
  InumaDisplayedFrameIdentityEntry* _entries;
  NSUInteger _count;
  NSUInteger _nextIndex;
}

- (instancetype)initWithCapacity:(NSUInteger)capacity {
  if (capacity == 0) return nil;
  self = [super init];
  if (self) {
    _entries = calloc(capacity, sizeof(*_entries));
    if (_entries == NULL) return nil;
    _lock = OS_UNFAIR_LOCK_INIT;
    _capacity = capacity;
  }
  return self;
}

- (void)dealloc {
  free(_entries);
}

- (BOOL)registerContext:(InumaPresentationFrameContext)context {
  if (!context.sourceIdentityValid || context.sourceIdentity > UINT32_MAX ||
      context.nativeGeneration == 0 ||
      context.renderOrdinal != context.nativeGeneration - 1 ||
      context.timingPolicy == InumaPresentationTimingUnknown) {
    return NO;
  }
  os_unfair_lock_lock(&_lock);
  _entries[_nextIndex] = (InumaDisplayedFrameIdentityEntry){
      .source_identity = context.sourceIdentity,
      .context = context,
  };
  _nextIndex = (_nextIndex + 1) % _capacity;
  _count = MIN(_count + 1, _capacity);
  os_unfair_lock_unlock(&_lock);
  return YES;
}

- (InumaDisplayedFrameIdentityLookupResult)
    lookupContextForDisplayedPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                  context:(InumaPresentationFrameContext*)context {
  if (pixelBuffer == nil || context == NULL) {
    return InumaDisplayedFrameIdentityLookupInvalid;
  }
  InumaProductWatermarkIdentity identity = {0};
  const InumaDisplayedFrameIdentityLookupResult decoded =
      InumaDecodeProductWatermark(pixelBuffer, &identity);
  if (decoded != InumaDisplayedFrameIdentityLookupFound) return decoded;
  BOOL found = NO;
  InumaPresentationFrameContext matched = {0};
  os_unfair_lock_lock(&_lock);
  for (NSUInteger distance = 0; distance < _count; distance++) {
    const NSUInteger index =
        (_nextIndex + _capacity - 1 - distance) % _capacity;
    if (_entries[index].source_identity == identity.frameIdentity) {
      matched = _entries[index].context;
      found = YES;
      break;
    }
  }
  os_unfair_lock_unlock(&_lock);
  if (!found) return InumaDisplayedFrameIdentityLookupContextMissing;
  *context = matched;
  return InumaDisplayedFrameIdentityLookupFound;
}

@end

static NSString* InumaPresentationEventName(uint32_t kind) {
  switch ((InumaPresentationEventKind)kind) {
    case InumaPresentationEventSessionStart: return @"session_start";
    case InumaPresentationEventRenderReceived: return @"render_received";
    case InumaPresentationEventSampleBuildBegin: return @"sample_build_begin";
    case InumaPresentationEventSampleBuildEnd: return @"sample_build_end";
    case InumaPresentationEventSampleBuildFailed: return @"sample_build_failed";
    case InumaPresentationEventPendingSet: return @"pending_set";
    case InumaPresentationEventPendingReplaced: return @"pending_replaced";
    case InumaPresentationEventPendingRejectedAfterShutdown:
      return @"pending_rejected_after_shutdown";
    case InumaPresentationEventPendingDeferred: return @"pending_deferred";
    case InumaPresentationEventPendingResumed: return @"pending_resumed";
    case InumaPresentationEventEnqueueBegin: return @"enqueue_begin";
    case InumaPresentationEventRendererFlush: return @"renderer_flush";
    case InumaPresentationEventReadinessFalse: return @"readiness_false";
    case InumaPresentationEventReadinessTrue: return @"readiness_true";
    case InumaPresentationEventReadinessClosedAtShutdown:
      return @"readiness_closed_at_shutdown";
    case InumaPresentationEventEnqueueEnd: return @"enqueue_end";
    case InumaPresentationEventRendererFailed: return @"renderer_failed";
    case InumaPresentationEventDisplayedObserved: return @"displayed_observed";
    case InumaPresentationEventDisplayedLookupMiss:
      return @"displayed_lookup_miss";
    case InumaPresentationEventSurfaceResize: return @"surface_resize";
    case InumaPresentationEventReconnect: return @"reconnect";
    case InumaPresentationEventShutdownBegin: return @"shutdown_begin";
    case InumaPresentationEventPendingCancelledAtShutdown:
      return @"pending_cancelled_at_shutdown";
    case InumaPresentationEventCallbackAfterStopRejected:
      return @"callback_after_stop_rejected";
    case InumaPresentationEventShutdownEnd: return @"shutdown_end";
    case InumaPresentationEventPacingAccepted: return @"pacing_accepted";
    case InumaPresentationEventPacingLateRejected:
      return @"pacing_late_rejected";
    case InumaPresentationEventPacingOverflowRejected:
      return @"pacing_overflow_rejected";
    case InumaPresentationEventPacingSequenceRejected:
      return @"pacing_sequence_rejected";
    case InumaPresentationEventPacingAddedLatencyRejected:
      return @"pacing_added_latency_rejected";
    case InumaPresentationEventPacingPrearmDiscarded:
      return @"pacing_prearm_discarded";
    case InumaPresentationEventPacingLatePhaseCorrected:
      return @"pacing_late_phase_corrected";
    case InumaPresentationEventPacingEarlyPhaseCorrected:
      return @"pacing_early_phase_corrected";
    case InumaPresentationEventKindCount: break;
  }
  return @"invalid";
}

static NSString* InumaPresentationTimingPolicyName(uint32_t policy) {
  switch ((InumaPresentationTimingPolicy)policy) {
    case InumaPresentationTimingImmediateInvalid: return @"immediate_invalid";
    case InumaPresentationTimingValidHostPTS: return @"valid_host_pts";
    case InumaPresentationTimingUnknown: return @"unknown";
  }
  return @"invalid";
}

static InumaPresentationEventRecord InumaPresentationRecord(
    InumaPresentationEventKind kind, uint64_t sequence, uint64_t startedAtNs,
    uint64_t atNs, InumaPresentationFrameContext context, uint64_t durationNs,
    uint64_t value, InumaRendererSubmissionResult result) {
  InumaPresentationEventRecord record = {0};
  record.event_sequence = sequence;
  record.monotonic_offset_ns = atNs >= startedAtNs ? atNs - startedAtNs : 0;
  record.source_identity = context.sourceIdentity;
  record.render_ordinal = context.renderOrdinal;
  record.native_generation = context.nativeGeneration;
  record.rtp_timestamp = context.rtpTimestamp;
  record.pending_age_ns = context.pendingAgeNs;
  record.presentation_reserve_ns = context.presentationReserveNs;
  record.scheduled_presentation_time_ns = context.scheduledPresentationTimeNs;
  record.presentation_residence_ns = context.presentationResidenceNs;
  record.presentation_lateness_ns = context.presentationLatenessNs;
  record.presentation_queue_depth = context.presentationQueueDepth;
  record.duration_ns = durationNs;
  record.value = value;
  record.renderer_error_code = result.rendererErrorCode;
  record.kind = (uint32_t)kind;
  record.timing_policy = (uint32_t)context.timingPolicy;
  record.renderer_status_before = result.rendererStatusBeforeEnqueue;
  record.renderer_status_after = result.rendererStatusAfterEnqueue;
  record.renderer_error_domain_class = result.rendererErrorDomainClass;
  record.source_identity_valid = context.sourceIdentityValid;
  record.accepted = result.accepted;
  record.ready_before_enqueue = result.readyBeforeEnqueue;
  record.flushed_before_enqueue = result.flushedBeforeEnqueue;
  record.failed_after_enqueue = result.failedAfterEnqueue;
  return record;
}

@implementation InumaNativePresentationTrace {
  os_unfair_lock _lock;
  InumaPresentationEventRecord* _records;
  NSUInteger _count;
  NSUInteger _nextIndex;
  uint64_t _sessionSequence;
  uint64_t _startedAtNs;
  uint64_t _totalEventCount;
  uint64_t _overwrittenEventCount;
  uint64_t _capacityExhaustions;
  uint64_t _eventCounts[InumaPresentationEventKindCount];
  BOOL _readinessIntervalOpen;
  uint64_t _readinessIntervalStartedAtNs;
  uint64_t _readinessIntervalsOpened;
  uint64_t _readinessIntervalsClosedReady;
  uint64_t _readinessIntervalsClosedShutdown;
  uint64_t _readinessTotalDurationNs;
}

- (instancetype)initWithCapacity:(NSUInteger)capacity
                  sessionSequence:(uint64_t)sessionSequence
                      startedAtNs:(uint64_t)startedAtNs {
  if (capacity == 0 || sessionSequence == 0 || startedAtNs == 0) return nil;
  self = [super init];
  if (self) {
    _records = calloc(capacity, sizeof(*_records));
    if (_records == nil) return nil;
    _lock = OS_UNFAIR_LOCK_INIT;
    _capacity = capacity;
    _sessionSequence = sessionSequence;
    _startedAtNs = startedAtNs;
    InumaPresentationFrameContext context = {0};
    os_unfair_lock_lock(&_lock);
    [self appendLocked:InumaPresentationEventSessionStart
                  atNs:startedAtNs
               context:context
             durationNs:0
                   value:sessionSequence
                  result:(InumaRendererSubmissionResult){0}];
    os_unfair_lock_unlock(&_lock);
  }
  return self;
}

- (void)dealloc {
  free(_records);
}

- (void)appendLocked:(InumaPresentationEventKind)kind
                 atNs:(uint64_t)atNs
              context:(InumaPresentationFrameContext)context
            durationNs:(uint64_t)durationNs
                  value:(uint64_t)value
                 result:(InumaRendererSubmissionResult)result {
  if (kind <= 0 || kind >= InumaPresentationEventKindCount) return;
  _totalEventCount += 1;
  const InumaPresentationEventRecord record = InumaPresentationRecord(
      kind, _totalEventCount, _startedAtNs, atNs, context, durationNs, value,
      result);
  _records[_nextIndex] = record;
  _nextIndex = (_nextIndex + 1) % _capacity;
  if (_count < _capacity) {
    _count += 1;
  } else {
    _overwrittenEventCount += 1;
  }
  _eventCounts[kind] += 1;
}

- (void)recordEventKind:(InumaPresentationEventKind)kind
                    atNs:(uint64_t)atNs
                 context:(InumaPresentationFrameContext)context
               durationNs:(uint64_t)durationNs
                     value:(uint64_t)value {
  os_unfair_lock_lock(&_lock);
  [self appendLocked:kind
                atNs:atNs
             context:context
           durationNs:durationNs
                 value:value
                result:(InumaRendererSubmissionResult){0}];
  os_unfair_lock_unlock(&_lock);
}

- (void)recordGeneration:(uint64_t)generation
             startedAtNs:(uint64_t)startedAtNs
           completedAtNs:(uint64_t)completedAtNs
                  result:(InumaRendererSubmissionResult)result {
  InumaPresentationFrameContext context = {0};
  context.nativeGeneration = generation;
  context.renderOrdinal = generation == 0 ? 0 : generation - 1;
  [self recordContext:context
          startedAtNs:startedAtNs
        completedAtNs:completedAtNs
               result:result];
}

- (void)recordContext:(InumaPresentationFrameContext)context
           startedAtNs:(uint64_t)startedAtNs
         completedAtNs:(uint64_t)completedAtNs
                result:(InumaRendererSubmissionResult)result {
  [self recordSubmissionBeginContext:context atNs:startedAtNs];
  if (result.flushedBeforeEnqueue) {
    [self recordRendererFlushContext:context atNs:startedAtNs result:result];
  }
  [self recordReadinessContext:context atNs:startedAtNs result:result];
  [self recordSubmissionEndContext:context
                       startedAtNs:startedAtNs
                     completedAtNs:completedAtNs
                            result:result];
}

- (void)recordSubmissionBeginContext:(InumaPresentationFrameContext)context
                                atNs:(uint64_t)atNs {
  os_unfair_lock_lock(&_lock);
  [self appendLocked:InumaPresentationEventEnqueueBegin
                atNs:atNs
             context:context
           durationNs:0
                 value:0
                result:(InumaRendererSubmissionResult){.accepted = YES}];
  os_unfair_lock_unlock(&_lock);
}

- (void)recordRendererFlushContext:(InumaPresentationFrameContext)context
                              atNs:(uint64_t)atNs
                             result:(InumaRendererSubmissionResult)result {
  os_unfair_lock_lock(&_lock);
  [self appendLocked:InumaPresentationEventRendererFlush
                atNs:atNs
             context:context
           durationNs:0
                 value:0
                result:result];
  os_unfair_lock_unlock(&_lock);
}

- (void)recordReadinessContext:(InumaPresentationFrameContext)context
                           atNs:(uint64_t)atNs
                          result:(InumaRendererSubmissionResult)result {
  os_unfair_lock_lock(&_lock);
  if (!result.readyBeforeEnqueue && !_readinessIntervalOpen) {
    _readinessIntervalOpen = YES;
    _readinessIntervalStartedAtNs = atNs;
    _readinessIntervalsOpened += 1;
    [self appendLocked:InumaPresentationEventReadinessFalse
                  atNs:atNs
               context:context
             durationNs:0
                   value:0
                  result:result];
  } else if (result.readyBeforeEnqueue && _readinessIntervalOpen) {
    const uint64_t duration = atNs - _readinessIntervalStartedAtNs;
    _readinessIntervalOpen = NO;
    _readinessIntervalsClosedReady += 1;
    _readinessTotalDurationNs += duration;
    [self appendLocked:InumaPresentationEventReadinessTrue
                  atNs:atNs
               context:context
             durationNs:duration
                   value:0
                  result:result];
  }
  os_unfair_lock_unlock(&_lock);
}

- (void)recordSubmissionEndContext:(InumaPresentationFrameContext)context
                         startedAtNs:(uint64_t)startedAtNs
                       completedAtNs:(uint64_t)completedAtNs
                              result:(InumaRendererSubmissionResult)result {
  os_unfair_lock_lock(&_lock);
  [self appendLocked:InumaPresentationEventEnqueueEnd
                atNs:completedAtNs
             context:context
           durationNs:completedAtNs - startedAtNs
                 value:0
                result:result];
  if (result.failedAfterEnqueue) {
    [self appendLocked:InumaPresentationEventRendererFailed
                  atNs:completedAtNs
               context:context
             durationNs:0
                   value:0
                  result:result];
  }
  os_unfair_lock_unlock(&_lock);
}

- (void)closeOpenIntervalsAtNs:(uint64_t)atNs
                       context:(InumaPresentationFrameContext)context {
  os_unfair_lock_lock(&_lock);
  if (_readinessIntervalOpen) {
    const uint64_t duration = atNs - _readinessIntervalStartedAtNs;
    _readinessIntervalOpen = NO;
    _readinessIntervalsClosedShutdown += 1;
    _readinessTotalDurationNs += duration;
    [self appendLocked:InumaPresentationEventReadinessClosedAtShutdown
                  atNs:atNs
               context:context
             durationNs:duration
                   value:0
                  result:(InumaRendererSubmissionResult){0}];
  }
  os_unfair_lock_unlock(&_lock);
}

- (NSDictionary<NSString*, id>*)snapshotAtNs:(uint64_t)snapshotAtNs
                                        drain:(BOOL)drain {
  os_unfair_lock_lock(&_lock);
  const NSUInteger count = _count;
  InumaPresentationEventRecord* copy = calloc(count, sizeof(*copy));
  if (copy == nil && count > 0) {
    _capacityExhaustions += 1;
    os_unfair_lock_unlock(&_lock);
    return @{
      @"schema" : @"inuma.flutter_webrtc.macos_native_presentation_trace.v2",
      @"status" : @"fail",
      @"finding" : @"presentation_trace_snapshot_allocation_failed",
    };
  }
  const NSUInteger oldest = count == _capacity ? _nextIndex : 0;
  for (NSUInteger index = 0; index < count; index++) {
    copy[index] = _records[(oldest + index) % _capacity];
  }
  const uint64_t total = _totalEventCount;
  const uint64_t overwritten = _overwrittenEventCount;
  const uint64_t capacityExhaustions = _capacityExhaustions;
  const BOOL readinessOpen = _readinessIntervalOpen;
  const uint64_t readinessOpened = _readinessIntervalsOpened;
  const uint64_t readinessClosedReady = _readinessIntervalsClosedReady;
  const uint64_t readinessClosedShutdown = _readinessIntervalsClosedShutdown;
  const uint64_t readinessDuration = _readinessTotalDurationNs;
  uint64_t eventCounts[InumaPresentationEventKindCount] = {0};
  memcpy(eventCounts, _eventCounts, sizeof(eventCounts));
  if (drain) {
    _count = 0;
    _nextIndex = 0;
  }
  os_unfair_lock_unlock(&_lock);

  NSMutableArray<NSDictionary<NSString*, id>*>* events =
      [NSMutableArray arrayWithCapacity:count];
  for (NSUInteger index = 0; index < count; index++) {
    const InumaPresentationEventRecord record = copy[index];
    [events addObject:@{
      @"event_sequence" : @(record.event_sequence),
      @"session_sequence" : @(_sessionSequence),
      @"event_kind" : InumaPresentationEventName(record.kind),
      @"monotonic_ns" : @(_startedAtNs + record.monotonic_offset_ns),
      @"monotonic_offset_ns" : @(record.monotonic_offset_ns),
      @"source_identity" : @(record.source_identity),
      @"source_identity_valid" : @(record.source_identity_valid),
      @"render_ordinal" : @(record.render_ordinal),
      @"native_generation" : @(record.native_generation),
      @"rtp_timestamp" : @(record.rtp_timestamp),
      @"pending_age_ns" : @(record.pending_age_ns),
      @"presentation_reserve_ns" : @(record.presentation_reserve_ns),
      @"scheduled_presentation_time_ns" :
          @(record.scheduled_presentation_time_ns),
      @"presentation_residence_ns" : @(record.presentation_residence_ns),
      @"presentation_lateness_ns" : @(record.presentation_lateness_ns),
      @"presentation_queue_depth" : @(record.presentation_queue_depth),
      @"timing_policy" : InumaPresentationTimingPolicyName(record.timing_policy),
      @"duration_ns" : @(record.duration_ns),
      @"value" : @(record.value),
      @"accepted" : @(record.accepted),
      @"ready_before_enqueue" : @(record.ready_before_enqueue),
      @"flushed_before_enqueue" : @(record.flushed_before_enqueue),
      @"failed_after_enqueue" : @(record.failed_after_enqueue),
      @"renderer_status_before" : @(record.renderer_status_before),
      @"renderer_status_after" : @(record.renderer_status_after),
      @"renderer_error_domain_class" : @(record.renderer_error_domain_class),
      @"renderer_error_code" : @(record.renderer_error_code),
    }];
  }
  free(copy);

  NSMutableDictionary<NSString*, NSNumber*>* counts = [NSMutableDictionary dictionary];
  for (uint32_t kind = 1; kind < InumaPresentationEventKindCount; kind++) {
    counts[InumaPresentationEventName(kind)] = @(eventCounts[kind]);
  }
  const uint64_t firstSequence = count == 0 ? 0 : [events[0][@"event_sequence"] unsignedLongLongValue];
  const uint64_t lastSequence = count == 0 ? 0 : [events.lastObject[@"event_sequence"] unsignedLongLongValue];
  return @{
    @"schema" : @"inuma.flutter_webrtc.macos_native_presentation_trace.v2",
    @"status" : @"pass",
    @"finding" : @"bounded_scalar_native_presentation_trace_snapshot",
    @"session_sequence" : @(_sessionSequence),
    @"trace_started_monotonic_ns" : @(_startedAtNs),
    @"trace_snapshot_monotonic_ns" : @(snapshotAtNs),
    @"event_capacity" : @(_capacity),
    @"retained_event_count" : @(count),
    @"total_event_count" : @(total),
    @"first_retained_event_sequence" : @(firstSequence),
    @"last_retained_event_sequence" : @(lastSequence),
    @"overwritten_event_count" : @(overwritten),
    @"capacity_exhaustions" : @(capacityExhaustions),
    @"event_counts" : counts,
    @"readiness_intervals_opened" : @(readinessOpened),
    @"readiness_intervals_closed_ready" : @(readinessClosedReady),
    @"readiness_intervals_closed_shutdown" : @(readinessClosedShutdown),
    @"readiness_interval_open" : @(readinessOpen),
    @"readiness_total_duration_ns" : @(readinessDuration),
    @"serialized_pixel_payload_bytes" : @0,
    @"pointer_values_retained" : @NO,
    @"hot_path_filesystem_writes" : @0,
    @"events" : events,
  };
}

- (NSDictionary<NSString*, id>*)snapshotAtNs:(uint64_t)snapshotAtNs {
  return [self snapshotAtNs:snapshotAtNs drain:NO];
}

- (NSDictionary<NSString*, id>*)drainSnapshotAtNs:(uint64_t)snapshotAtNs {
  return [self snapshotAtNs:snapshotAtNs drain:YES];
}

- (NSUInteger)count {
  os_unfair_lock_lock(&_lock);
  const NSUInteger value = _count;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)totalEventCount {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _totalEventCount;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)overwrittenEventCount {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _overwrittenEventCount;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)capacityExhaustions {
  os_unfair_lock_lock(&_lock);
  const uint64_t value = _capacityExhaustions;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (uint64_t)serializedPixelPayloadBytes {
  return 0;
}

@end

#endif
