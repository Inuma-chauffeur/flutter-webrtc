#import "FlutterRTCVideoRenderer.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CGImage.h>
#import <TargetConditionals.h>
#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCYUVHelper.h>
#import <WebRTC/RTCYUVPlanarBuffer.h>
#import <WebRTC/WebRTC.h>

#import <objc/runtime.h>
#include <math.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#import "FlutterWebRTCPlugin.h"
#import <os/lock.h>

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#import <QuartzCore/CADisplayLink.h>

enum {
  // Covers a 30 FPS, 30-minute proof plus 20% startup/teardown headroom.
  kInumaTextureTraceCapacity = 65536,
  kInumaStockBGRAPoolMinimumBufferCount = 4,
  kInumaPendingTextureFrameCapacity = 1,
};

typedef NS_ENUM(NSUInteger, InumaMacOSPixelMode) {
  InumaMacOSPixelModeStockBGRA = 0,
  InumaMacOSPixelModeNativeNV12 = 1,
};

typedef struct {
  CVPixelBufferRef pixel_buffer;
  int64_t frame_timestamp_ns;
  uint64_t ready_monotonic_ns;
} InumaPendingTextureFrame;

typedef struct {
  bool enabled;
  uint64_t render_frames;
  uint64_t accepted_frames;
  uint64_t coalesced_frames;
  uint64_t copy_calls;
  uint64_t copy_hits;
  uint64_t copy_misses;
  uint64_t source_cv_pixel_buffer_frames;
  uint64_t source_i420_frames;
  uint64_t source_nv12_frames;
  uint64_t source_bgra_frames;
  uint64_t source_other_pixel_format_frames;
  uint64_t native_nv12_frames;
  uint64_t native_nv12_fallback_frames;
  uint64_t texture_hold_applied;
  uint64_t stale_texture_notifications;
  uint64_t queued_frames;
  uint64_t queue_promotions;
  uint64_t queue_overflows;
  uint64_t queue_cleared_frames;
  uint64_t queue_max_depth;
  uint64_t rescue_hold_bypasses;
  uint64_t rescue_hold_preservations;
  uint64_t rescue_display_link_schedules;
  uint64_t rescue_display_link_fires;
  uint64_t rescue_display_link_cancellations;
  uint64_t rescue_display_link_fallbacks;
  uint64_t rescue_display_link_stale_fires;
  uint64_t rescue_display_link_callbacks;
  uint64_t rescue_display_link_deferrals;
  uint64_t rescue_display_link_commit_fence_deferrals;
  uint64_t texture_notification_platform_turn_schedules;
  uint64_t texture_notification_platform_turn_fires;
  uint64_t strict_hold_timer_created;
  uint64_t strict_hold_timer_fired;
  uint64_t strict_hold_timer_cancelled;
  uint64_t strict_hold_timer_create_failures;
  uint64_t stock_bgra_pool_create_failures;
  uint64_t stock_bgra_pool_buffer_requests;
  uint64_t stock_bgra_pool_buffer_failures;
  uint64_t sample_capacity_exhaustions;
  uint64_t conversion_samples[kInumaTextureTraceCapacity];
  uint64_t render_lock_wait_samples[kInumaTextureTraceCapacity];
  uint64_t copy_lock_wait_samples[kInumaTextureTraceCapacity];
  uint64_t copy_ready_age_samples[kInumaTextureTraceCapacity];
  uint64_t texture_notify_dispatch_samples[kInumaTextureTraceCapacity];
  uint64_t texture_notify_samples[kInumaTextureTraceCapacity];
  uint64_t texture_hold_delay_samples[kInumaTextureTraceCapacity];
  int64_t texture_hold_frame_timestamp_ns_samples[kInumaTextureTraceCapacity];
  uint64_t texture_notify_event_offset_samples[kInumaTextureTraceCapacity];
  int64_t texture_notify_frame_timestamp_ns_samples[kInumaTextureTraceCapacity];
  uint64_t texture_notify_scheduled_delay_samples[kInumaTextureTraceCapacity];
  uint64_t texture_notify_deadline_lateness_samples[kInumaTextureTraceCapacity];
  uint64_t queue_wait_samples[kInumaTextureTraceCapacity];
  uint64_t queue_enqueue_event_offset_samples[kInumaTextureTraceCapacity];
  int64_t queue_enqueue_frame_timestamp_ns_samples[kInumaTextureTraceCapacity];
  uint64_t queue_promote_event_offset_samples[kInumaTextureTraceCapacity];
  int64_t queue_promote_frame_timestamp_ns_samples[kInumaTextureTraceCapacity];
  int64_t rescue_hold_bypass_frame_timestamp_ns_samples
      [kInumaTextureTraceCapacity];
  int64_t rescue_hold_preservation_frame_timestamp_ns_samples
      [kInumaTextureTraceCapacity];
  uint64_t rescue_display_link_schedule_offset_samples
      [kInumaTextureTraceCapacity];
  uint64_t rescue_display_link_fire_offset_samples[kInumaTextureTraceCapacity];
  uint64_t rescue_display_link_presentation_ack_samples
      [kInumaTextureTraceCapacity];
  uint64_t rescue_display_link_first_presentation_ack_samples
      [kInumaTextureTraceCapacity];
  uint64_t rescue_display_link_callback_count_samples
      [kInumaTextureTraceCapacity];
  int64_t rescue_display_link_frame_timestamp_ns_samples
      [kInumaTextureTraceCapacity];
  uint64_t strict_hold_timer_deadline_offset_samples
      [kInumaTextureTraceCapacity];
  uint64_t strict_hold_timer_fire_offset_samples[kInumaTextureTraceCapacity];
  int64_t strict_hold_timer_frame_timestamp_ns_samples
      [kInumaTextureTraceCapacity];
  uint64_t render_event_offset_samples[kInumaTextureTraceCapacity];
  int64_t render_frame_timestamp_ns_samples[kInumaTextureTraceCapacity];
  uint8_t render_outcome_samples[kInumaTextureTraceCapacity];
  uint64_t coalesced_pending_age_samples[kInumaTextureTraceCapacity];
  uint64_t copy_event_offset_samples[kInumaTextureTraceCapacity];
  int64_t copy_frame_timestamp_ns_samples[kInumaTextureTraceCapacity];
  NSUInteger conversion_count;
  NSUInteger render_lock_wait_count;
  NSUInteger copy_lock_wait_count;
  NSUInteger copy_ready_age_count;
  NSUInteger texture_notify_dispatch_count;
  NSUInteger texture_notify_count;
  NSUInteger texture_hold_delay_count;
  NSUInteger texture_notify_event_count;
  NSUInteger queue_wait_count;
  NSUInteger queue_enqueue_event_count;
  NSUInteger queue_promote_event_count;
  NSUInteger rescue_hold_bypass_count;
  NSUInteger rescue_hold_preservation_count;
  NSUInteger rescue_display_link_event_count;
  NSUInteger strict_hold_timer_event_count;
  NSUInteger render_event_count;
  NSUInteger coalesced_pending_age_count;
  NSUInteger copy_event_count;
} InumaTextureTrace;

static uint64_t InumaMonotonicNanoseconds(void) {
  return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
}

static uint64_t InumaUptimeNanoseconds(void) {
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static uint64_t InumaDisplayLinkTimestampNanoseconds(
    CADisplayLink *displayLink) API_AVAILABLE(macos(14.0)) {
  const CFTimeInterval timestamp = displayLink.timestamp;
  if (!isfinite(timestamp) || timestamp <= 0.0 ||
      timestamp >= ((CFTimeInterval)UINT64_MAX / 1000000000.0)) {
    return 0;
  }
  return (uint64_t)(timestamp * 1000000000.0);
}

static bool InumaAppendTraceSample(uint64_t *samples, NSUInteger *count,
                                   uint64_t value,
                                   uint64_t *capacityExhaustions) {
  if (*count >= kInumaTextureTraceCapacity) {
    *capacityExhaustions += 1;
    return false;
  }
  samples[*count] = value;
  *count += 1;
  return true;
}

static NSUInteger InumaReserveTraceSample(NSUInteger *count,
                                          uint64_t *capacityExhaustions) {
  if (*count >= kInumaTextureTraceCapacity) {
    *capacityExhaustions += 1;
    return NSNotFound;
  }
  const NSUInteger index = *count;
  *count += 1;
  return index;
}

static void InumaCopyTextureTraceLocked(InumaTextureTrace *destination,
                                        const InumaTextureTrace *source) {
  // Copy scalar state once, then only each populated sample prefix. Copying the
  // full capacity-safe structure under the renderer lock would make the
  // observer itself a source of strict-hold timer lateness.
  memcpy(destination, source, offsetof(InumaTextureTrace, conversion_samples));

#define INUMA_COPY_TRACE_ARRAY(field, count_field)                         \
  do {                                                                    \
    destination->count_field = source->count_field;                       \
    memcpy(destination->field, source->field,                             \
           source->count_field * sizeof(source->field[0]));               \
  } while (0)

  INUMA_COPY_TRACE_ARRAY(conversion_samples, conversion_count);
  INUMA_COPY_TRACE_ARRAY(render_lock_wait_samples, render_lock_wait_count);
  INUMA_COPY_TRACE_ARRAY(copy_lock_wait_samples, copy_lock_wait_count);
  INUMA_COPY_TRACE_ARRAY(copy_ready_age_samples, copy_ready_age_count);
  INUMA_COPY_TRACE_ARRAY(texture_notify_dispatch_samples,
                         texture_notify_dispatch_count);
  INUMA_COPY_TRACE_ARRAY(texture_notify_samples, texture_notify_count);
  INUMA_COPY_TRACE_ARRAY(texture_hold_delay_samples, texture_hold_delay_count);
  INUMA_COPY_TRACE_ARRAY(texture_hold_frame_timestamp_ns_samples,
                         texture_hold_delay_count);
  INUMA_COPY_TRACE_ARRAY(texture_notify_event_offset_samples,
                         texture_notify_event_count);
  INUMA_COPY_TRACE_ARRAY(texture_notify_frame_timestamp_ns_samples,
                         texture_notify_event_count);
  INUMA_COPY_TRACE_ARRAY(texture_notify_scheduled_delay_samples,
                         texture_notify_event_count);
  INUMA_COPY_TRACE_ARRAY(texture_notify_deadline_lateness_samples,
                         texture_notify_event_count);
  INUMA_COPY_TRACE_ARRAY(queue_wait_samples, queue_wait_count);
  INUMA_COPY_TRACE_ARRAY(queue_enqueue_event_offset_samples,
                         queue_enqueue_event_count);
  INUMA_COPY_TRACE_ARRAY(queue_enqueue_frame_timestamp_ns_samples,
                         queue_enqueue_event_count);
  INUMA_COPY_TRACE_ARRAY(queue_promote_event_offset_samples,
                         queue_promote_event_count);
  INUMA_COPY_TRACE_ARRAY(queue_promote_frame_timestamp_ns_samples,
                         queue_promote_event_count);
  INUMA_COPY_TRACE_ARRAY(rescue_hold_bypass_frame_timestamp_ns_samples,
                         rescue_hold_bypass_count);
  INUMA_COPY_TRACE_ARRAY(rescue_hold_preservation_frame_timestamp_ns_samples,
                         rescue_hold_preservation_count);
  INUMA_COPY_TRACE_ARRAY(rescue_display_link_schedule_offset_samples,
                         rescue_display_link_event_count);
  INUMA_COPY_TRACE_ARRAY(rescue_display_link_fire_offset_samples,
                         rescue_display_link_event_count);
  INUMA_COPY_TRACE_ARRAY(rescue_display_link_presentation_ack_samples,
                         rescue_display_link_event_count);
  INUMA_COPY_TRACE_ARRAY(
      rescue_display_link_first_presentation_ack_samples,
      rescue_display_link_event_count);
  INUMA_COPY_TRACE_ARRAY(rescue_display_link_callback_count_samples,
                         rescue_display_link_event_count);
  INUMA_COPY_TRACE_ARRAY(rescue_display_link_frame_timestamp_ns_samples,
                         rescue_display_link_event_count);
  INUMA_COPY_TRACE_ARRAY(strict_hold_timer_deadline_offset_samples,
                         strict_hold_timer_event_count);
  INUMA_COPY_TRACE_ARRAY(strict_hold_timer_fire_offset_samples,
                         strict_hold_timer_event_count);
  INUMA_COPY_TRACE_ARRAY(strict_hold_timer_frame_timestamp_ns_samples,
                         strict_hold_timer_event_count);
  INUMA_COPY_TRACE_ARRAY(render_event_offset_samples, render_event_count);
  INUMA_COPY_TRACE_ARRAY(render_frame_timestamp_ns_samples,
                         render_event_count);
  INUMA_COPY_TRACE_ARRAY(render_outcome_samples, render_event_count);
  INUMA_COPY_TRACE_ARRAY(coalesced_pending_age_samples,
                         coalesced_pending_age_count);
  INUMA_COPY_TRACE_ARRAY(copy_event_offset_samples, copy_event_count);
  INUMA_COPY_TRACE_ARRAY(copy_frame_timestamp_ns_samples, copy_event_count);

#undef INUMA_COPY_TRACE_ARRAY
}

static NSArray<NSNumber *> *InumaTraceSampleArray(const uint64_t *samples,
                                                  NSUInteger count) {
  NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithCapacity:count];
  for (NSUInteger index = 0; index < count; index++) {
    [values addObject:@(samples[index])];
  }
  return values;
}

static NSArray<NSNumber *> *InumaTraceByteSampleArray(const uint8_t *samples,
                                                      NSUInteger count) {
  NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithCapacity:count];
  for (NSUInteger index = 0; index < count; index++) {
    [values addObject:@(samples[index])];
  }
  return values;
}

static NSArray<NSNumber *> *InumaTraceSignedSampleArray(const int64_t *samples,
                                                       NSUInteger count) {
  NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithCapacity:count];
  for (NSUInteger index = 0; index < count; index++) {
    [values addObject:@(samples[index])];
  }
  return values;
}

static InumaMacOSPixelMode
InumaPixelModeFromEnvironment(NSDictionary<NSString *, NSString *> *env) {
  NSString *value = [env[@"INUMA_FLUTTER_WEBRTC_MACOS_PIXEL_MODE"]
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  if ([value isEqualToString:@"native_nv12"]) {
    return InumaMacOSPixelModeNativeNV12;
  }
  return InumaMacOSPixelModeStockBGRA;
}

static uint64_t InumaTextureMinimumHoldNanosecondsFromEnvironment(
    NSDictionary<NSString *, NSString *> *env) {
  NSString *value =
      [env[@"INUMA_FLUTTER_WEBRTC_MACOS_MIN_TEXTURE_HOLD_MS"]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  const double milliseconds = value.doubleValue;
  if (milliseconds <= 0.0 || milliseconds > 100.0) {
    return 0;
  }
  return (uint64_t)(milliseconds * (double)NSEC_PER_MSEC);
}

static NSUInteger InumaMaxQueuedTextureFramesFromEnvironment(
    NSDictionary<NSString *, NSString *> *env) {
  NSString *value =
      [env[@"INUMA_FLUTTER_WEBRTC_MACOS_MAX_QUEUED_TEXTURE_FRAMES"]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  const NSInteger frames = value.integerValue;
  if (frames <= 0 || frames > kInumaPendingTextureFrameCapacity) {
    return 0;
  }
  return (NSUInteger)frames;
}

@interface FlutterRTCVideoRenderer ()
- (void)inumaRecordSourceBuffer:(id<RTCVideoFrameBuffer>)buffer;
- (CVPixelBufferRef)inumaCreatePixelBufferFromFrame:(RTCVideoFrame *)frame;
- (CVPixelBufferRef)inumaRetainNativeNV12BufferFromFrame:
    (RTCVideoFrame *)frame;
- (CVPixelBufferRef)inumaCreateFreshStockBGRABuffer;
- (void)inumaScheduleTextureNotificationForTextureId:(int64_t)textureId
                                    frameTimestampNs:(int64_t)frameTimestampNs
                                   bypassMinimumHold:(bool)bypassMinimumHold
                                  recordRescueBypass:(bool)recordRescueBypass;
- (void)inumaScheduleDisplayLinkedRescueForTextureId:(int64_t)textureId
                                    frameTimestampNs:
                                        (int64_t)frameTimestampNs
                            predecessorCopyUptimeNs:
                                (uint64_t)predecessorCopyUptimeNs;
- (void)inumaRescueDisplayLinkDidFire:(CADisplayLink *)displayLink
    API_AVAILABLE(macos(14.0));
- (void)inumaCancelTextureHoldTimerLocked;
- (void)inumaCancelRescueDisplayLinkLocked;
- (void)inumaClearPendingTextureFramesLocked;
- (void)inumaResetStockBGRAPixelBufferPoolForSize:(CGSize)size;
- (void)inumaWriteTextureTrace;
@end
#endif

@implementation FlutterRTCVideoRenderer {
  CGSize _frameSize;
  CGSize _renderSize;
  CVPixelBufferRef _pixelBufferRef;
  RTCVideoRotation _rotation;
  FlutterEventChannel *_eventChannel;
  bool _isFirstFrameRendered;
  bool _frameAvailable;
  os_unfair_lock _lock;
#if TARGET_OS_OSX
  NSString *_inumaTracePath;
  InumaMacOSPixelMode _inumaPixelMode;
  InumaTextureTrace _inumaTrace;
  uint64_t _inumaTraceStartedMonotonicNs;
  uint64_t _inumaFrameReadyMonotonicNs;
  uint64_t _inumaLastCopyMonotonicNs;
  uint64_t _inumaMinimumTextureHoldNs;
  NSUInteger _inumaMaxQueuedTextureFrames;
  NSUInteger _inumaPendingTextureFrameHead;
  NSUInteger _inumaPendingTextureFrameCount;
  InumaPendingTextureFrame
      _inumaPendingTextureFrames[kInumaPendingTextureFrameCapacity];
  int64_t _inumaFrameTimestampNs;
  CVPixelBufferPoolRef _inumaStockBGRAPixelBufferPool;
  dispatch_queue_t _inumaTraceQueue;
  dispatch_source_t _inumaTraceTimer;
  dispatch_source_t _inumaTextureHoldTimer;
  CADisplayLink *_inumaRescueDisplayLink;
  uint64_t _inumaTraceSnapshotCount;
  uint64_t _inumaTraceSnapshotLockHoldMaxNs;
  int64_t _inumaRescueDisplayLinkFrameTimestampNs;
  uint64_t _inumaRescuePredecessorCopyUptimeNs;
  uint64_t _inumaRescueFirstPresentationAckUptimeNs;
  NSUInteger _inumaRescueDisplayLinkEventIndex;
#endif
}

@synthesize textureId = _textureId;
@synthesize registry = _registry;
@synthesize eventSink = _eventSink;
@synthesize videoTrack = _videoTrack;

- (instancetype)initWithTextureRegistry:(id<FlutterTextureRegistry>)registry
                              messenger:(NSObject<FlutterBinaryMessenger> *)
                                            messenger {
  self = [super init];
  if (self) {
    _lock = OS_UNFAIR_LOCK_INIT;
    _isFirstFrameRendered = false;
    _frameAvailable = false;
    _frameSize = CGSizeZero;
    _renderSize = CGSizeZero;
    _rotation = -1;
    _registry = registry;
    _pixelBufferRef = nil;
    _eventSink = nil;
    _rotation = -1;
    _textureId = [registry registerTexture:self];
#if TARGET_OS_OSX
    NSDictionary<NSString *, NSString *> *environment =
        NSProcessInfo.processInfo.environment;
    _inumaTracePath =
        [environment[@"INUMA_FLUTTER_WEBRTC_TEXTURE_TRACE_PATH"] copy];
    _inumaTrace.enabled = _inumaTracePath.length > 0;
    _inumaPixelMode = InumaPixelModeFromEnvironment(environment);
    _inumaMinimumTextureHoldNs =
        InumaTextureMinimumHoldNanosecondsFromEnvironment(environment);
    _inumaMaxQueuedTextureFrames =
        InumaMaxQueuedTextureFramesFromEnvironment(environment);
    _inumaPendingTextureFrameHead = 0;
    _inumaPendingTextureFrameCount = 0;
    _inumaTraceStartedMonotonicNs =
        _inumaTrace.enabled ? InumaMonotonicNanoseconds() : 0;
    _inumaFrameReadyMonotonicNs = 0;
    _inumaLastCopyMonotonicNs = 0;
    _inumaFrameTimestampNs = 0;
    _inumaTextureHoldTimer = nil;
    _inumaRescueDisplayLink = nil;
    _inumaTraceSnapshotCount = 0;
    _inumaTraceSnapshotLockHoldMaxNs = 0;
    _inumaRescueDisplayLinkFrameTimestampNs = 0;
    _inumaRescuePredecessorCopyUptimeNs = 0;
    _inumaRescueFirstPresentationAckUptimeNs = 0;
    _inumaRescueDisplayLinkEventIndex = NSNotFound;
    _inumaStockBGRAPixelBufferPool = nil;
    if (_inumaTrace.enabled) {
      _inumaTraceQueue = dispatch_queue_create(
          "dev.inuma.flutter-webrtc.texture-trace", DISPATCH_QUEUE_SERIAL);
      _inumaTraceTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0,
                                                0, _inumaTraceQueue);
      dispatch_source_set_timer(
          _inumaTraceTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
          5 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
      __weak FlutterRTCVideoRenderer *weakSelf = self;
      dispatch_source_set_event_handler(_inumaTraceTimer, ^{
        [weakSelf inumaWriteTextureTrace];
      });
      dispatch_resume(_inumaTraceTimer);
    }
#endif
    /*Create Event Channel.*/
    _eventChannel = [FlutterEventChannel
        eventChannelWithName:[NSString
                                 stringWithFormat:@"FlutterWebRTC/Texture%lld",
                                                  _textureId]
             binaryMessenger:messenger];
    [_eventChannel setStreamHandler:self];
  }
  return self;
}

- (CVPixelBufferRef)copyPixelBuffer {
  CVPixelBufferRef buffer = nil;
#if TARGET_OS_OSX
  const uint64_t started =
      _inumaTrace.enabled ? InumaMonotonicNanoseconds() : 0;
  bool notifyPromotedFrame = false;
  int64_t promotedTextureId = -1;
  int64_t promotedFrameTimestampNs = 0;
  uint64_t promotedPredecessorCopyUptimeNs = 0;
#endif
  os_unfair_lock_lock(&_lock);
#if TARGET_OS_OSX
  const uint64_t locked = _inumaTrace.enabled ? InumaMonotonicNanoseconds() : 0;
  if (_inumaTrace.enabled) {
    _inumaTrace.copy_calls += 1;
    InumaAppendTraceSample(
        _inumaTrace.copy_lock_wait_samples,
        &_inumaTrace.copy_lock_wait_count, locked - started,
        &_inumaTrace.sample_capacity_exhaustions);
  }
#endif
  if (_pixelBufferRef != nil && _frameAvailable) {
    buffer = CVBufferRetain(_pixelBufferRef);
    _frameAvailable = false;
#if TARGET_OS_OSX
    const uint64_t copiedAt = InumaMonotonicNanoseconds();
    const uint64_t copiedAtUptimeNs = InumaUptimeNanoseconds();
    _inumaLastCopyMonotonicNs = copiedAt;
    if (_inumaTrace.enabled) {
      _inumaTrace.copy_hits += 1;
      if (_inumaFrameReadyMonotonicNs > 0 &&
          locked >= _inumaFrameReadyMonotonicNs) {
        InumaAppendTraceSample(
            _inumaTrace.copy_ready_age_samples,
            &_inumaTrace.copy_ready_age_count,
            locked - _inumaFrameReadyMonotonicNs,
            &_inumaTrace.sample_capacity_exhaustions);
      }
      if (_inumaTraceStartedMonotonicNs > 0 &&
          locked >= _inumaTraceStartedMonotonicNs) {
        const NSUInteger copyEventIndex = InumaReserveTraceSample(
            &_inumaTrace.copy_event_count,
            &_inumaTrace.sample_capacity_exhaustions);
        if (copyEventIndex != NSNotFound) {
          _inumaTrace.copy_event_offset_samples[copyEventIndex] =
              locked - _inumaTraceStartedMonotonicNs;
          _inumaTrace.copy_frame_timestamp_ns_samples[copyEventIndex] =
              _inumaFrameTimestampNs;
        }
      }
    }
    if (_inumaPendingTextureFrameCount > 0) {
      InumaPendingTextureFrame promoted =
          _inumaPendingTextureFrames[_inumaPendingTextureFrameHead];
      _inumaPendingTextureFrames[_inumaPendingTextureFrameHead] =
          (InumaPendingTextureFrame){0};
      _inumaPendingTextureFrameHead =
          (_inumaPendingTextureFrameHead + 1) %
          kInumaPendingTextureFrameCapacity;
      _inumaPendingTextureFrameCount -= 1;

      CVPixelBufferRef previousBuffer = _pixelBufferRef;
      _pixelBufferRef = promoted.pixel_buffer;
      _frameAvailable = true;
      _inumaFrameReadyMonotonicNs = promoted.ready_monotonic_ns;
      _inumaFrameTimestampNs = promoted.frame_timestamp_ns;
      if (previousBuffer != nil) {
        CVBufferRelease(previousBuffer);
      }
      notifyPromotedFrame = _textureId != -1;
      promotedTextureId = _textureId;
      promotedFrameTimestampNs = promoted.frame_timestamp_ns;
      promotedPredecessorCopyUptimeNs = copiedAtUptimeNs;
      if (_inumaTrace.enabled) {
        _inumaTrace.queue_promotions += 1;
        _inumaTrace.rescue_hold_preservations += 1;
        const NSUInteger preservationIndex = InumaReserveTraceSample(
            &_inumaTrace.rescue_hold_preservation_count,
            &_inumaTrace.sample_capacity_exhaustions);
        if (preservationIndex != NSNotFound) {
          _inumaTrace
              .rescue_hold_preservation_frame_timestamp_ns_samples
                  [preservationIndex] = promoted.frame_timestamp_ns;
        }
        if (copiedAt >= promoted.ready_monotonic_ns) {
          InumaAppendTraceSample(
              _inumaTrace.queue_wait_samples,
              &_inumaTrace.queue_wait_count,
              copiedAt - promoted.ready_monotonic_ns,
              &_inumaTrace.sample_capacity_exhaustions);
        }
        if (_inumaTraceStartedMonotonicNs > 0 &&
            copiedAt >= _inumaTraceStartedMonotonicNs) {
          const NSUInteger promoteIndex = InumaReserveTraceSample(
              &_inumaTrace.queue_promote_event_count,
              &_inumaTrace.sample_capacity_exhaustions);
          if (promoteIndex != NSNotFound) {
            _inumaTrace.queue_promote_event_offset_samples[promoteIndex] =
                copiedAt - _inumaTraceStartedMonotonicNs;
            _inumaTrace.queue_promote_frame_timestamp_ns_samples
                [promoteIndex] = promoted.frame_timestamp_ns;
          }
        }
      }
    }
#endif
#if TARGET_OS_OSX
  } else if (_inumaTrace.enabled) {
    _inumaTrace.copy_misses += 1;
#endif
  }
  os_unfair_lock_unlock(&_lock);
#if TARGET_OS_OSX
  if (notifyPromotedFrame) {
    [self inumaScheduleDisplayLinkedRescueForTextureId:promotedTextureId
                                      frameTimestampNs:
                                          promotedFrameTimestampNs
                              predecessorCopyUptimeNs:
                                  promotedPredecessorCopyUptimeNs];
  }
#endif
  return buffer;
}

- (void)dispose {
#if TARGET_OS_OSX
  if (_inumaTraceTimer != nil) {
    dispatch_source_cancel(_inumaTraceTimer);
    _inumaTraceTimer = nil;
  }
#endif
  os_unfair_lock_lock(&_lock);
#if TARGET_OS_OSX
  [self inumaCancelTextureHoldTimerLocked];
  [self inumaCancelRescueDisplayLinkLocked];
#endif
  [_registry unregisterTexture:_textureId];
  _textureId = -1;
  if (_pixelBufferRef) {
    CVBufferRelease(_pixelBufferRef);
    _pixelBufferRef = nil;
  }
#if TARGET_OS_OSX
  [self inumaClearPendingTextureFramesLocked];
  if (_inumaStockBGRAPixelBufferPool) {
    CVPixelBufferPoolRelease(_inumaStockBGRAPixelBufferPool);
    _inumaStockBGRAPixelBufferPool = nil;
  }
#endif
  _frameAvailable = false;
  os_unfair_lock_unlock(&_lock);
#if TARGET_OS_OSX
  [self inumaWriteTextureTrace];
#endif
}

- (void)setVideoTrack:(RTCVideoTrack *)videoTrack {
  RTCVideoTrack *oldValue = self.videoTrack;
  if (oldValue != videoTrack) {
    os_unfair_lock_lock(&_lock);
    _videoTrack = videoTrack;
#if TARGET_OS_OSX
    [self inumaCancelTextureHoldTimerLocked];
    [self inumaCancelRescueDisplayLinkLocked];
    [self inumaClearPendingTextureFramesLocked];
    _inumaFrameReadyMonotonicNs = 0;
    _inumaFrameTimestampNs = 0;
#endif
    _frameAvailable = false;
    os_unfair_lock_unlock(&_lock);
    _isFirstFrameRendered = false;
    if (oldValue) {
      [oldValue removeRenderer:self];
    }
    _frameSize = CGSizeZero;
    _renderSize = CGSizeZero;
    _rotation = -1;
    if (videoTrack) {
      [videoTrack addRenderer:self];
    }
  }
}

- (id<RTCI420Buffer>)correctRotation:(const id<RTCI420Buffer>)src
                        withRotation:(RTCVideoRotation)rotation {
  int rotated_width = src.width;
  int rotated_height = src.height;

  if (rotation == RTCVideoRotation_90 || rotation == RTCVideoRotation_270) {
    int temp = rotated_width;
    rotated_width = rotated_height;
    rotated_height = temp;
  }

  id<RTCI420Buffer> buffer =
      [[RTCI420Buffer alloc] initWithWidth:rotated_width height:rotated_height];

  [RTCYUVHelper I420Rotate:src.dataY
                srcStrideY:src.strideY
                      srcU:src.dataU
                srcStrideU:src.strideU
                      srcV:src.dataV
                srcStrideV:src.strideV
                      dstY:(uint8_t *)buffer.dataY
                dstStrideY:buffer.strideY
                      dstU:(uint8_t *)buffer.dataU
                dstStrideU:buffer.strideU
                      dstV:(uint8_t *)buffer.dataV
                dstStrideV:buffer.strideV
                     width:src.width
                    height:src.height
                      mode:rotation];

  return buffer;
}

- (void)copyI420ToCVPixelBuffer:(CVPixelBufferRef)outputPixelBuffer
                      withFrame:(RTCVideoFrame *)frame {
  id<RTCI420Buffer> i420Buffer = [self correctRotation:[frame.buffer toI420]
                                          withRotation:frame.rotation];
  CVPixelBufferLockBaseAddress(outputPixelBuffer, 0);

  const OSType pixelFormat = CVPixelBufferGetPixelFormatType(outputPixelBuffer);
  if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
      pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
    // NV12
    uint8_t *dstY = CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 0);
    const size_t dstYStride =
        CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 0);
    uint8_t *dstUV = CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 1);
    const size_t dstUVStride =
        CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 1);

    [RTCYUVHelper I420ToNV12:i420Buffer.dataY
                  srcStrideY:i420Buffer.strideY
                        srcU:i420Buffer.dataU
                  srcStrideU:i420Buffer.strideU
                        srcV:i420Buffer.dataV
                  srcStrideV:i420Buffer.strideV
                        dstY:dstY
                  dstStrideY:(int)dstYStride
                       dstUV:dstUV
                 dstStrideUV:(int)dstUVStride
                       width:i420Buffer.width
                      height:i420Buffer.height];

  } else {
    uint8_t *dst = CVPixelBufferGetBaseAddress(outputPixelBuffer);
    const size_t bytesPerRow = CVPixelBufferGetBytesPerRow(outputPixelBuffer);

    if (pixelFormat == kCVPixelFormatType_32BGRA) {
      // Corresponds to libyuv::FOURCC_ARGB

      [RTCYUVHelper I420ToARGB:i420Buffer.dataY
                    srcStrideY:i420Buffer.strideY
                          srcU:i420Buffer.dataU
                    srcStrideU:i420Buffer.strideU
                          srcV:i420Buffer.dataV
                    srcStrideV:i420Buffer.strideV
                       dstARGB:dst
                 dstStrideARGB:(int)bytesPerRow
                         width:i420Buffer.width
                        height:i420Buffer.height];

    } else if (pixelFormat == kCVPixelFormatType_32ARGB) {
      // Corresponds to libyuv::FOURCC_BGRA
      [RTCYUVHelper I420ToBGRA:i420Buffer.dataY
                    srcStrideY:i420Buffer.strideY
                          srcU:i420Buffer.dataU
                    srcStrideU:i420Buffer.strideU
                          srcV:i420Buffer.dataV
                    srcStrideV:i420Buffer.strideV
                       dstBGRA:dst
                 dstStrideBGRA:(int)bytesPerRow
                         width:i420Buffer.width
                        height:i420Buffer.height];
    }
  }

  CVPixelBufferUnlockBaseAddress(outputPixelBuffer, 0);
}

#pragma mark - RTCVideoRenderer methods
- (void)renderFrame:(RTCVideoFrame *)frame {

#if TARGET_OS_OSX
  const uint64_t started =
      _inumaTrace.enabled ? InumaMonotonicNanoseconds() : 0;
  NSUInteger inumaRenderEventIndex = NSNotFound;
  bool inumaShouldNotifyTexture = false;
  int64_t inumaTextureIdToNotify = -1;
  int64_t inumaFrameTimestampToNotify = 0;
#endif
  os_unfair_lock_lock(&_lock);
#if TARGET_OS_OSX
  const uint64_t locked = _inumaTrace.enabled ? InumaMonotonicNanoseconds() : 0;
  if (_inumaTrace.enabled) {
    _inumaTrace.render_frames += 1;
    if (_inumaTraceStartedMonotonicNs > 0 &&
        locked >= _inumaTraceStartedMonotonicNs) {
      inumaRenderEventIndex = InumaReserveTraceSample(
          &_inumaTrace.render_event_count,
          &_inumaTrace.sample_capacity_exhaustions);
      if (inumaRenderEventIndex != NSNotFound) {
        _inumaTrace.render_event_offset_samples[inumaRenderEventIndex] =
            locked - _inumaTraceStartedMonotonicNs;
        _inumaTrace.render_frame_timestamp_ns_samples[inumaRenderEventIndex] =
            frame.timeStampNs;
        _inumaTrace.render_outcome_samples[inumaRenderEventIndex] = 0;
      }
    }
    InumaAppendTraceSample(
        _inumaTrace.render_lock_wait_samples,
        &_inumaTrace.render_lock_wait_count, locked - started,
        &_inumaTrace.sample_capacity_exhaustions);
    [self inumaRecordSourceBuffer:frame.buffer];
  }
#endif
  if (_videoTrack == nil) {
    os_unfair_lock_unlock(&_lock);
    return;
  }
#if TARGET_OS_OSX
  const bool canPrepareFrame =
      _inumaPixelMode == InumaMacOSPixelModeNativeNV12 ||
      _inumaStockBGRAPixelBufferPool != nil;
  const bool queueHasCapacity =
      _inumaMaxQueuedTextureFrames > 0 &&
      _inumaLastCopyMonotonicNs > 0 &&
      _inumaPendingTextureFrameCount < _inumaMaxQueuedTextureFrames;
  const bool canAcceptFrame =
      canPrepareFrame && (!_frameAvailable || queueHasCapacity);
#else
  const bool canAcceptFrame = !_frameAvailable && _pixelBufferRef != nil;
#endif
  if (canAcceptFrame) {
#if TARGET_OS_OSX
    CVPixelBufferRef preparedBuffer =
        [self inumaCreatePixelBufferFromFrame:frame];
    const bool framePrepared = preparedBuffer != nil;
    const uint64_t frameReadyNs =
        framePrepared ? InumaMonotonicNanoseconds() : 0;
    if (framePrepared && !_frameAvailable) {
      CVPixelBufferRef previousBuffer = _pixelBufferRef;
      _pixelBufferRef = preparedBuffer;
      _frameAvailable = true;
      _inumaFrameReadyMonotonicNs = frameReadyNs;
      _inumaFrameTimestampNs = frame.timeStampNs;
      if (previousBuffer != nil) {
        CVBufferRelease(previousBuffer);
      }
      if (_textureId != -1) {
        inumaShouldNotifyTexture = true;
        inumaTextureIdToNotify = _textureId;
        inumaFrameTimestampToNotify = frame.timeStampNs;
      }
    } else if (framePrepared) {
      const NSUInteger queueIndex =
          (_inumaPendingTextureFrameHead +
           _inumaPendingTextureFrameCount) %
          kInumaPendingTextureFrameCapacity;
      _inumaPendingTextureFrames[queueIndex] =
          (InumaPendingTextureFrame){
              .pixel_buffer = preparedBuffer,
              .frame_timestamp_ns = frame.timeStampNs,
              .ready_monotonic_ns = frameReadyNs,
          };
      _inumaPendingTextureFrameCount += 1;
      if (_inumaTrace.enabled) {
        _inumaTrace.queued_frames += 1;
        _inumaTrace.queue_max_depth =
            MAX(_inumaTrace.queue_max_depth,
                (uint64_t)_inumaPendingTextureFrameCount);
        if (_inumaTraceStartedMonotonicNs > 0 &&
            frameReadyNs >= _inumaTraceStartedMonotonicNs) {
          const NSUInteger enqueueIndex = InumaReserveTraceSample(
              &_inumaTrace.queue_enqueue_event_count,
              &_inumaTrace.sample_capacity_exhaustions);
          if (enqueueIndex != NSNotFound) {
            _inumaTrace.queue_enqueue_event_offset_samples[enqueueIndex] =
                frameReadyNs - _inumaTraceStartedMonotonicNs;
            _inumaTrace.queue_enqueue_frame_timestamp_ns_samples[enqueueIndex] =
                frame.timeStampNs;
          }
        }
      }
    }
    if (_inumaTrace.enabled && framePrepared) {
      _inumaTrace.accepted_frames += 1;
      if (inumaRenderEventIndex != NSNotFound) {
        _inumaTrace.render_outcome_samples[inumaRenderEventIndex] = 1;
      }
    }
#else
    [self copyI420ToCVPixelBuffer:_pixelBufferRef withFrame:frame];
    if (_textureId != -1) {
      [_registry textureFrameAvailable:_textureId];
    }
    _frameAvailable = true;
#endif
#if TARGET_OS_OSX
  } else if (_inumaTrace.enabled) {
    _inumaTrace.coalesced_frames += 1;
    if (_frameAvailable && _inumaMaxQueuedTextureFrames > 0 &&
        _inumaPendingTextureFrameCount >=
            _inumaMaxQueuedTextureFrames) {
      _inumaTrace.queue_overflows += 1;
    }
    if (inumaRenderEventIndex != NSNotFound) {
      _inumaTrace.render_outcome_samples[inumaRenderEventIndex] = 2;
    }
    if (_inumaFrameReadyMonotonicNs > 0 &&
        locked >= _inumaFrameReadyMonotonicNs) {
      InumaAppendTraceSample(
          _inumaTrace.coalesced_pending_age_samples,
          &_inumaTrace.coalesced_pending_age_count,
          locked - _inumaFrameReadyMonotonicNs,
          &_inumaTrace.sample_capacity_exhaustions);
    }
#endif
  }
  os_unfair_lock_unlock(&_lock);

  __weak FlutterRTCVideoRenderer *weakSelf = self;
#if TARGET_OS_OSX
  if (inumaShouldNotifyTexture) {
    [self inumaScheduleTextureNotificationForTextureId:
              inumaTextureIdToNotify
                                          frameTimestampNs:
                                              inumaFrameTimestampToNotify
                                         bypassMinimumHold:false
                                        recordRescueBypass:false];
  }
#endif
  if (_renderSize.width != frame.width || _renderSize.height != frame.height) {
    dispatch_async(dispatch_get_main_queue(), ^{
      FlutterRTCVideoRenderer *strongSelf = weakSelf;
      if (strongSelf.eventSink) {
        strongSelf.eventSink(@{
          @"event" : @"didTextureChangeVideoSize",
          @"id" : @(strongSelf.textureId),
          @"width" : @(frame.width),
          @"height" : @(frame.height),
        });
      }
    });
    _renderSize = CGSizeMake(frame.width, frame.height);
  }

  if (frame.rotation != _rotation) {
    dispatch_async(dispatch_get_main_queue(), ^{
      FlutterRTCVideoRenderer *strongSelf = weakSelf;
      if (strongSelf.eventSink) {
        strongSelf.eventSink(@{
          @"event" : @"didTextureChangeRotation",
          @"id" : @(strongSelf.textureId),
          @"rotation" : @(frame.rotation),
        });
      }
    });

    _rotation = frame.rotation;
  }

  // Notify the Flutter new pixelBufferRef to be ready.
  dispatch_async(dispatch_get_main_queue(), ^{
    FlutterRTCVideoRenderer *strongSelf = weakSelf;
    if (!strongSelf->_isFirstFrameRendered) {
      if (strongSelf.eventSink) {
        strongSelf.eventSink(@{@"event" : @"didFirstFrameRendered"});
        strongSelf->_isFirstFrameRendered = true;
      }
    }
  });
}

#if TARGET_OS_OSX
- (void)inumaRecordSourceBuffer:(id<RTCVideoFrameBuffer>)buffer {
  if ([buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
    _inumaTrace.source_cv_pixel_buffer_frames += 1;
    const OSType format = CVPixelBufferGetPixelFormatType(
        ((RTCCVPixelBuffer *)buffer).pixelBuffer);
    if (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
      _inumaTrace.source_nv12_frames += 1;
    } else if (format == kCVPixelFormatType_32BGRA) {
      _inumaTrace.source_bgra_frames += 1;
    } else {
      _inumaTrace.source_other_pixel_format_frames += 1;
    }
  } else {
    _inumaTrace.source_i420_frames += 1;
  }
}

- (CVPixelBufferRef)inumaCreatePixelBufferFromFrame:(RTCVideoFrame *)frame {
  CVPixelBufferRef preparedBuffer = nil;
  if (_inumaPixelMode == InumaMacOSPixelModeNativeNV12) {
    preparedBuffer = [self inumaRetainNativeNV12BufferFromFrame:frame];
    if (_inumaTrace.enabled && preparedBuffer == nil) {
      _inumaTrace.native_nv12_fallback_frames += 1;
    }
  }
  if (preparedBuffer == nil) {
    preparedBuffer = [self inumaCreateFreshStockBGRABuffer];
    if (preparedBuffer != nil) {
      const uint64_t conversionStarted =
          _inumaTrace.enabled ? InumaMonotonicNanoseconds() : 0;
      [self copyI420ToCVPixelBuffer:preparedBuffer withFrame:frame];
      if (_inumaTrace.enabled) {
        InumaAppendTraceSample(
            _inumaTrace.conversion_samples,
            &_inumaTrace.conversion_count,
            InumaMonotonicNanoseconds() - conversionStarted,
            &_inumaTrace.sample_capacity_exhaustions);
      }
    }
  }
  return preparedBuffer;
}

- (CVPixelBufferRef)inumaRetainNativeNV12BufferFromFrame:
    (RTCVideoFrame *)frame {
  if (frame.rotation != RTCVideoRotation_0 ||
      ![frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
    return nil;
  }
  RTCCVPixelBuffer *source = (RTCCVPixelBuffer *)frame.buffer;
  CVPixelBufferRef pixelBuffer = source.pixelBuffer;
  const OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
  if ((format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
       format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ||
      [source requiresCropping] ||
      [source requiresScalingToWidth:frame.width height:frame.height] ||
      CVPixelBufferGetIOSurface(pixelBuffer) == nil) {
    return nil;
  }
  CVBufferRetain(pixelBuffer);
  if (_inumaTrace.enabled) {
    _inumaTrace.native_nv12_frames += 1;
  }
  return pixelBuffer;
}

- (CVPixelBufferRef)inumaCreateFreshStockBGRABuffer {
  // Flutter retains the returned CVPixelBuffer while Metal presents it
  // asynchronously. Never overwrite that same backing for the next frame;
  // the pool recycles it only after downstream owners release it.
  _inumaTrace.stock_bgra_pool_buffer_requests += 1;
  CVPixelBufferRef freshBuffer = nil;
  CVReturn result = kCVReturnInvalidArgument;
  if (_inumaStockBGRAPixelBufferPool != nil) {
    result = CVPixelBufferPoolCreatePixelBuffer(
        kCFAllocatorDefault, _inumaStockBGRAPixelBufferPool, &freshBuffer);
  }
  if (result != kCVReturnSuccess || freshBuffer == nil) {
    _inumaTrace.stock_bgra_pool_buffer_failures += 1;
    return nil;
  }
  return freshBuffer;
}

- (void)inumaScheduleTextureNotificationForTextureId:(int64_t)textureId
                                    frameTimestampNs:
                                        (int64_t)frameTimestampNs
                                   bypassMinimumHold:(bool)bypassMinimumHold
                                  recordRescueBypass:(bool)recordRescueBypass {
  const uint64_t enqueuedAt = InumaMonotonicNanoseconds();
  __block uint64_t scheduledDelayNs = 0;
  os_unfair_lock_lock(&_lock);
  const bool notificationCanBeScheduled =
      _textureId == textureId && _frameAvailable &&
      _inumaFrameTimestampNs == frameTimestampNs;
  if (notificationCanBeScheduled && bypassMinimumHold && recordRescueBypass &&
      _inumaTrace.enabled) {
    _inumaTrace.rescue_hold_bypasses += 1;
    const NSUInteger bypassIndex = InumaReserveTraceSample(
        &_inumaTrace.rescue_hold_bypass_count,
        &_inumaTrace.sample_capacity_exhaustions);
    if (bypassIndex != NSNotFound) {
      _inumaTrace
          .rescue_hold_bypass_frame_timestamp_ns_samples[bypassIndex] =
          frameTimestampNs;
    }
  }
  if (notificationCanBeScheduled && !bypassMinimumHold &&
      _inumaMinimumTextureHoldNs > 0 &&
      _inumaLastCopyMonotonicNs > 0 &&
      enqueuedAt >= _inumaLastCopyMonotonicNs) {
    const uint64_t currentTenureNs =
        enqueuedAt - _inumaLastCopyMonotonicNs;
    if (currentTenureNs < _inumaMinimumTextureHoldNs) {
      scheduledDelayNs = _inumaMinimumTextureHoldNs - currentTenureNs;
      if (_inumaTrace.enabled) {
        _inumaTrace.texture_hold_applied += 1;
        const NSUInteger holdIndex = _inumaTrace.texture_hold_delay_count;
        const bool holdRetained = InumaAppendTraceSample(
            _inumaTrace.texture_hold_delay_samples,
            &_inumaTrace.texture_hold_delay_count,
            scheduledDelayNs,
            &_inumaTrace.sample_capacity_exhaustions);
        if (holdRetained) {
          _inumaTrace
              .texture_hold_frame_timestamp_ns_samples[holdIndex] =
              frameTimestampNs;
        }
      }
    }
  }
  os_unfair_lock_unlock(&_lock);
  if (!notificationCanBeScheduled) {
    return;
  }

  __weak FlutterRTCVideoRenderer *weakSelf = self;
  void (^notifyTextureFrameAvailable)(void) = ^{
    FlutterRTCVideoRenderer *strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    const uint64_t notifyStarted = InumaMonotonicNanoseconds();
    os_unfair_lock_lock(&strongSelf->_lock);
    const bool notificationIsCurrent =
        strongSelf->_textureId == textureId &&
        strongSelf->_frameAvailable &&
        strongSelf->_inumaFrameTimestampNs == frameTimestampNs;
    const bool traceEnabled = strongSelf->_inumaTrace.enabled;
    id<FlutterTextureRegistry> registry = strongSelf->_registry;
    if (traceEnabled && !notificationIsCurrent) {
      strongSelf->_inumaTrace.stale_texture_notifications += 1;
    }
    if (traceEnabled && notificationIsCurrent && registry != nil &&
        strongSelf->_inumaTraceStartedMonotonicNs > 0 &&
        notifyStarted >= strongSelf->_inumaTraceStartedMonotonicNs) {
      const NSUInteger notifyEventIndex = InumaReserveTraceSample(
          &strongSelf->_inumaTrace.texture_notify_event_count,
          &strongSelf->_inumaTrace.sample_capacity_exhaustions);
      if (notifyEventIndex != NSNotFound) {
        strongSelf->_inumaTrace
            .texture_notify_event_offset_samples[notifyEventIndex] =
            notifyStarted - strongSelf->_inumaTraceStartedMonotonicNs;
        strongSelf->_inumaTrace
            .texture_notify_frame_timestamp_ns_samples[notifyEventIndex] =
            frameTimestampNs;
        strongSelf->_inumaTrace
            .texture_notify_scheduled_delay_samples[notifyEventIndex] =
            scheduledDelayNs;
        const uint64_t plannedDeadlineNs = enqueuedAt + scheduledDelayNs;
        strongSelf->_inumaTrace
            .texture_notify_deadline_lateness_samples[notifyEventIndex] =
            notifyStarted >= plannedDeadlineNs
                ? notifyStarted - plannedDeadlineNs
                : 0;
      }
    }
    os_unfair_lock_unlock(&strongSelf->_lock);
    if (!notificationIsCurrent || registry == nil) {
      return;
    }
    [registry textureFrameAvailable:textureId];
    if (traceEnabled) {
      const uint64_t notifyEnded = InumaMonotonicNanoseconds();
      os_unfair_lock_lock(&strongSelf->_lock);
      if (notifyStarted >= enqueuedAt) {
        InumaAppendTraceSample(
            strongSelf->_inumaTrace.texture_notify_dispatch_samples,
            &strongSelf->_inumaTrace.texture_notify_dispatch_count,
            notifyStarted - enqueuedAt,
            &strongSelf->_inumaTrace.sample_capacity_exhaustions);
      }
      InumaAppendTraceSample(
          strongSelf->_inumaTrace.texture_notify_samples,
          &strongSelf->_inumaTrace.texture_notify_count,
          notifyEnded - notifyStarted,
          &strongSelf->_inumaTrace.sample_capacity_exhaustions);
      os_unfair_lock_unlock(&strongSelf->_lock);
    }
  };
  void (^notifyOnNextPlatformTurn)(void) = ^{
    FlutterRTCVideoRenderer *strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    os_unfair_lock_lock(&strongSelf->_lock);
    if (strongSelf->_inumaTrace.enabled) {
      strongSelf->_inumaTrace.texture_notification_platform_turn_schedules +=
          1;
    }
    os_unfair_lock_unlock(&strongSelf->_lock);
    dispatch_async(dispatch_get_main_queue(), ^{
      FlutterRTCVideoRenderer *innerSelf = weakSelf;
      if (innerSelf == nil) {
        return;
      }
      os_unfair_lock_lock(&innerSelf->_lock);
      if (innerSelf->_inumaTrace.enabled) {
        innerSelf->_inumaTrace.texture_notification_platform_turn_fires += 1;
      }
      os_unfair_lock_unlock(&innerSelf->_lock);
      notifyTextureFrameAvailable();
    });
  };
  if (scheduledDelayNs == 0) {
    notifyOnNextPlatformTurn();
  } else {
    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT,
        dispatch_get_main_queue());
    if (timer == nil) {
      os_unfair_lock_lock(&_lock);
      if (_inumaTrace.enabled) {
        _inumaTrace.strict_hold_timer_create_failures += 1;
      }
      os_unfair_lock_unlock(&_lock);
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)scheduledDelayNs),
          dispatch_get_main_queue(), notifyOnNextPlatformTurn);
      return;
    }

    __block NSUInteger timerEventIndex = NSNotFound;
    const uint64_t deadlineNs = enqueuedAt + scheduledDelayNs;
    os_unfair_lock_lock(&_lock);
    const bool timerIsCurrent =
        _textureId == textureId && _frameAvailable &&
        _inumaFrameTimestampNs == frameTimestampNs &&
        _inumaTextureHoldTimer == nil;
    if (timerIsCurrent) {
      _inumaTextureHoldTimer = timer;
      if (_inumaTrace.enabled) {
        _inumaTrace.strict_hold_timer_created += 1;
        if (_inumaTraceStartedMonotonicNs > 0 &&
            deadlineNs >= _inumaTraceStartedMonotonicNs) {
          timerEventIndex = InumaReserveTraceSample(
              &_inumaTrace.strict_hold_timer_event_count,
              &_inumaTrace.sample_capacity_exhaustions);
          if (timerEventIndex != NSNotFound) {
            _inumaTrace.strict_hold_timer_deadline_offset_samples
                [timerEventIndex] =
                deadlineNs - _inumaTraceStartedMonotonicNs;
            _inumaTrace.strict_hold_timer_frame_timestamp_ns_samples
                [timerEventIndex] = frameTimestampNs;
          }
        }
      }
    }
    os_unfair_lock_unlock(&_lock);
    if (!timerIsCurrent) {
      dispatch_source_cancel(timer);
      dispatch_resume(timer);
      return;
    }

    __weak dispatch_source_t weakTimer = timer;
    dispatch_source_set_event_handler(timer, ^{
      dispatch_source_t strongTimer = weakTimer;
      FlutterRTCVideoRenderer *strongSelf = weakSelf;
      if (strongTimer == nil) {
        return;
      }
      if (strongSelf == nil) {
        dispatch_source_cancel(strongTimer);
        return;
      }
      const uint64_t firedAt = InumaMonotonicNanoseconds();
      os_unfair_lock_lock(&strongSelf->_lock);
      const bool ownsTimer =
          strongSelf->_inumaTextureHoldTimer == strongTimer;
      if (ownsTimer) {
        strongSelf->_inumaTextureHoldTimer = nil;
      }
      if (strongSelf->_inumaTrace.enabled) {
        strongSelf->_inumaTrace.strict_hold_timer_fired += 1;
        if (timerEventIndex != NSNotFound &&
            timerEventIndex <
                strongSelf->_inumaTrace.strict_hold_timer_event_count &&
            strongSelf->_inumaTraceStartedMonotonicNs > 0 &&
            firedAt >= strongSelf->_inumaTraceStartedMonotonicNs) {
          strongSelf->_inumaTrace.strict_hold_timer_fire_offset_samples
              [timerEventIndex] =
              firedAt - strongSelf->_inumaTraceStartedMonotonicNs;
        }
      }
      os_unfair_lock_unlock(&strongSelf->_lock);
      dispatch_source_cancel(strongTimer);
      if (ownsTimer) {
        notifyOnNextPlatformTurn();
      }
    });
    dispatch_source_set_timer(
        timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)scheduledDelayNs),
        DISPATCH_TIME_FOREVER, 0);
    dispatch_resume(timer);
  }
}

- (void)inumaScheduleDisplayLinkedRescueForTextureId:(int64_t)textureId
                                    frameTimestampNs:
                                        (int64_t)frameTimestampNs
                            predecessorCopyUptimeNs:
                                (uint64_t)predecessorCopyUptimeNs {
  const uint64_t scheduledAt = InumaMonotonicNanoseconds();
  __weak FlutterRTCVideoRenderer *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    FlutterRTCVideoRenderer *strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    if (@available(macOS 14.0, *)) {
      NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
      CADisplayLink *displayLink =
          [screen displayLinkWithTarget:strongSelf
                              selector:@selector(inumaRescueDisplayLinkDidFire:)];
      os_unfair_lock_lock(&strongSelf->_lock);
      const bool rescueIsCurrent =
          screen != nil && displayLink != nil &&
          strongSelf->_textureId == textureId &&
          strongSelf->_frameAvailable &&
          strongSelf->_inumaFrameTimestampNs == frameTimestampNs &&
          strongSelf->_inumaRescueDisplayLink == nil;
      if (rescueIsCurrent) {
        strongSelf->_inumaRescueDisplayLink = displayLink;
        strongSelf->_inumaRescueDisplayLinkFrameTimestampNs =
            frameTimestampNs;
        strongSelf->_inumaRescuePredecessorCopyUptimeNs =
            predecessorCopyUptimeNs;
        strongSelf->_inumaRescueFirstPresentationAckUptimeNs = 0;
        strongSelf->_inumaRescueDisplayLinkEventIndex = NSNotFound;
        if (strongSelf->_inumaTrace.enabled) {
          strongSelf->_inumaTrace.rescue_display_link_schedules += 1;
          if (strongSelf->_inumaTraceStartedMonotonicNs > 0 &&
              scheduledAt >= strongSelf->_inumaTraceStartedMonotonicNs) {
            const NSUInteger eventIndex = InumaReserveTraceSample(
                &strongSelf->_inumaTrace.rescue_display_link_event_count,
                &strongSelf->_inumaTrace.sample_capacity_exhaustions);
            if (eventIndex != NSNotFound) {
              strongSelf->_inumaTrace
                  .rescue_display_link_schedule_offset_samples[eventIndex] =
                  scheduledAt - strongSelf->_inumaTraceStartedMonotonicNs;
              strongSelf->_inumaTrace
                  .rescue_display_link_frame_timestamp_ns_samples[eventIndex] =
                  frameTimestampNs;
              strongSelf->_inumaRescueDisplayLinkEventIndex = eventIndex;
            }
          }
        }
      }
      os_unfair_lock_unlock(&strongSelf->_lock);
      if (rescueIsCurrent) {
        [displayLink addToRunLoop:NSRunLoop.mainRunLoop
                         forMode:NSRunLoopCommonModes];
        return;
      }
      [displayLink invalidate];
      if (screen == nil || displayLink == nil) {
        os_unfair_lock_lock(&strongSelf->_lock);
        const bool fallbackIsCurrent =
            strongSelf->_textureId == textureId &&
            strongSelf->_frameAvailable &&
            strongSelf->_inumaFrameTimestampNs == frameTimestampNs;
        if (fallbackIsCurrent && strongSelf->_inumaTrace.enabled) {
          strongSelf->_inumaTrace.rescue_display_link_fallbacks += 1;
        }
        os_unfair_lock_unlock(&strongSelf->_lock);
        if (fallbackIsCurrent) {
          [strongSelf
              inumaScheduleTextureNotificationForTextureId:textureId
                                          frameTimestampNs:frameTimestampNs
                                         bypassMinimumHold:false
                                        recordRescueBypass:false];
        }
      }
      return;
    }

    os_unfair_lock_lock(&strongSelf->_lock);
    const bool fallbackIsCurrent =
        strongSelf->_textureId == textureId &&
        strongSelf->_frameAvailable &&
        strongSelf->_inumaFrameTimestampNs == frameTimestampNs;
    if (fallbackIsCurrent && strongSelf->_inumaTrace.enabled) {
      strongSelf->_inumaTrace.rescue_display_link_fallbacks += 1;
    }
    os_unfair_lock_unlock(&strongSelf->_lock);
    if (fallbackIsCurrent) {
      [strongSelf inumaScheduleTextureNotificationForTextureId:textureId
                                             frameTimestampNs:
                                                 frameTimestampNs
                                            bypassMinimumHold:false
                                           recordRescueBypass:false];
    }
  });
}

- (void)inumaRescueDisplayLinkDidFire:(CADisplayLink *)displayLink
    API_AVAILABLE(macos(14.0)) {
  const uint64_t firedAt = InumaMonotonicNanoseconds();
  const uint64_t displayedAtUptimeNs =
      InumaDisplayLinkTimestampNanoseconds(displayLink);
  int64_t textureId = -1;
  int64_t frameTimestampNs = 0;
  bool rescueIsCurrent = false;
  bool predecessorWasPresented = false;
  bool commitFenceSatisfied = false;
  bool deferUntilPresentation = false;
  os_unfair_lock_lock(&_lock);
  const bool ownsDisplayLink = _inumaRescueDisplayLink == displayLink;
  if (ownsDisplayLink) {
    textureId = _textureId;
    frameTimestampNs = _inumaRescueDisplayLinkFrameTimestampNs;
    rescueIsCurrent =
        textureId != -1 && _frameAvailable &&
        _inumaFrameTimestampNs == frameTimestampNs;
    predecessorWasPresented =
        _inumaRescuePredecessorCopyUptimeNs > 0 &&
        displayedAtUptimeNs >= _inumaRescuePredecessorCopyUptimeNs;
    const bool firstPresentationAcknowledged =
        rescueIsCurrent && predecessorWasPresented &&
        _inumaRescueFirstPresentationAckUptimeNs == 0;
    if (firstPresentationAcknowledged) {
      // The first timestamp proves that a refresh followed the raster copy,
      // but that refresh can still precede the Core Animation transaction
      // containing the copied texture. Keep the rescue link alive through one
      // strictly newer refresh before allowing the successor notification.
      _inumaRescueFirstPresentationAckUptimeNs = displayedAtUptimeNs;
    }
    commitFenceSatisfied =
        _inumaRescueFirstPresentationAckUptimeNs > 0 &&
        displayedAtUptimeNs >
            _inumaRescueFirstPresentationAckUptimeNs;
    deferUntilPresentation =
        rescueIsCurrent &&
        (!predecessorWasPresented || !commitFenceSatisfied);
    if (_inumaTrace.enabled) {
      _inumaTrace.rescue_display_link_callbacks += 1;
      const NSUInteger eventIndex = _inumaRescueDisplayLinkEventIndex;
      if (eventIndex != NSNotFound &&
          eventIndex < _inumaTrace.rescue_display_link_event_count) {
        _inumaTrace.rescue_display_link_callback_count_samples[eventIndex] +=
            1;
      }
      if (deferUntilPresentation) {
        _inumaTrace.rescue_display_link_deferrals += 1;
        if (firstPresentationAcknowledged) {
          _inumaTrace.rescue_display_link_commit_fence_deferrals += 1;
          if (eventIndex != NSNotFound &&
              eventIndex <
                  _inumaTrace.rescue_display_link_event_count) {
            _inumaTrace
                .rescue_display_link_first_presentation_ack_samples
                    [eventIndex] =
                displayedAtUptimeNs -
                _inumaRescuePredecessorCopyUptimeNs;
          }
        }
      } else if (rescueIsCurrent && predecessorWasPresented &&
                 commitFenceSatisfied) {
        _inumaTrace.rescue_display_link_fires += 1;
        if (eventIndex != NSNotFound &&
            eventIndex < _inumaTrace.rescue_display_link_event_count &&
            _inumaTraceStartedMonotonicNs > 0 &&
            firedAt >= _inumaTraceStartedMonotonicNs) {
          _inumaTrace.rescue_display_link_fire_offset_samples[eventIndex] =
              firedAt - _inumaTraceStartedMonotonicNs;
          _inumaTrace.rescue_display_link_presentation_ack_samples[eventIndex] =
              displayedAtUptimeNs - _inumaRescuePredecessorCopyUptimeNs;
        }
      }
      if (!rescueIsCurrent) {
        _inumaTrace.rescue_display_link_stale_fires += 1;
      }
    }
    if (!deferUntilPresentation) {
      _inumaRescueDisplayLink = nil;
      _inumaRescueDisplayLinkFrameTimestampNs = 0;
      _inumaRescuePredecessorCopyUptimeNs = 0;
      _inumaRescueFirstPresentationAckUptimeNs = 0;
      _inumaRescueDisplayLinkEventIndex = NSNotFound;
    }
  }
  os_unfair_lock_unlock(&_lock);
  if (deferUntilPresentation) {
    return;
  }
  [displayLink invalidate];
  if (rescueIsCurrent && predecessorWasPresented &&
      commitFenceSatisfied) {
    [self inumaScheduleTextureNotificationForTextureId:textureId
                                      frameTimestampNs:frameTimestampNs
                                     bypassMinimumHold:true
                                    recordRescueBypass:false];
  }
}

- (void)inumaCancelTextureHoldTimerLocked {
  dispatch_source_t timer = _inumaTextureHoldTimer;
  if (timer == nil) {
    return;
  }
  _inumaTextureHoldTimer = nil;
  dispatch_source_cancel(timer);
  if (_inumaTrace.enabled) {
    _inumaTrace.strict_hold_timer_cancelled += 1;
  }
}

- (void)inumaCancelRescueDisplayLinkLocked {
  CADisplayLink *displayLink = _inumaRescueDisplayLink;
  if (displayLink == nil) {
    return;
  }
  _inumaRescueDisplayLink = nil;
  _inumaRescueDisplayLinkFrameTimestampNs = 0;
  _inumaRescuePredecessorCopyUptimeNs = 0;
  _inumaRescueFirstPresentationAckUptimeNs = 0;
  _inumaRescueDisplayLinkEventIndex = NSNotFound;
  [displayLink invalidate];
  if (_inumaTrace.enabled) {
    _inumaTrace.rescue_display_link_cancellations += 1;
  }
}

- (void)inumaClearPendingTextureFramesLocked {
  while (_inumaPendingTextureFrameCount > 0) {
    InumaPendingTextureFrame pending =
        _inumaPendingTextureFrames[_inumaPendingTextureFrameHead];
    _inumaPendingTextureFrames[_inumaPendingTextureFrameHead] =
        (InumaPendingTextureFrame){0};
    _inumaPendingTextureFrameHead =
        (_inumaPendingTextureFrameHead + 1) %
        kInumaPendingTextureFrameCapacity;
    _inumaPendingTextureFrameCount -= 1;
    if (pending.pixel_buffer != nil) {
      CVBufferRelease(pending.pixel_buffer);
    }
    if (_inumaTrace.enabled) {
      _inumaTrace.queue_cleared_frames += 1;
    }
  }
  _inumaPendingTextureFrameHead = 0;
}

- (void)inumaResetStockBGRAPixelBufferPoolForSize:(CGSize)size {
  if (_inumaStockBGRAPixelBufferPool != nil) {
    CVPixelBufferPoolRelease(_inumaStockBGRAPixelBufferPool);
    _inumaStockBGRAPixelBufferPool = nil;
  }
  NSDictionary *pixelAttributes = @{
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    (id)kCVPixelBufferWidthKey : @(size.width),
    (id)kCVPixelBufferHeightKey : @(size.height),
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
  };
  NSDictionary *poolAttributes = @{
    (id)kCVPixelBufferPoolMinimumBufferCountKey :
        @(kInumaStockBGRAPoolMinimumBufferCount),
  };
  CVReturn result = CVPixelBufferPoolCreate(
      kCFAllocatorDefault, (__bridge CFDictionaryRef)poolAttributes,
      (__bridge CFDictionaryRef)pixelAttributes,
      &_inumaStockBGRAPixelBufferPool);
  if (result != kCVReturnSuccess ||
      _inumaStockBGRAPixelBufferPool == nil) {
    _inumaTrace.stock_bgra_pool_create_failures += 1;
    _inumaStockBGRAPixelBufferPool = nil;
  }
}

- (void)inumaWriteTextureTrace {
  if (!_inumaTrace.enabled || _inumaTracePath.length == 0) {
    return;
  }
  InumaTextureTrace *snapshot = malloc(sizeof(InumaTextureTrace));
  if (snapshot == NULL) {
    return;
  }
  NSUInteger pendingTextureFrameCount = 0;
  bool textureHoldTimerActive = false;
  bool rescueDisplayLinkActive = false;
  os_unfair_lock_lock(&_lock);
  const uint64_t traceSnapshotMonotonicNs = InumaMonotonicNanoseconds();
  InumaCopyTextureTraceLocked(snapshot, &_inumaTrace);
  pendingTextureFrameCount = _inumaPendingTextureFrameCount;
  textureHoldTimerActive = _inumaTextureHoldTimer != nil;
  rescueDisplayLinkActive = _inumaRescueDisplayLink != nil;
  os_unfair_lock_unlock(&_lock);
  const uint64_t traceSnapshotLockHoldNs =
      InumaMonotonicNanoseconds() - traceSnapshotMonotonicNs;
  _inumaTraceSnapshotCount += 1;
  _inumaTraceSnapshotLockHoldMaxNs =
      MAX(_inumaTraceSnapshotLockHoldMaxNs, traceSnapshotLockHoldNs);
  NSString *mode = _inumaPixelMode == InumaMacOSPixelModeNativeNV12
                       ? @"native_nv12"
                       : @"stock_bgra";
  NSDictionary *report = @{
    @"schema" : @"inuma.flutter_webrtc.macos_texture_trace.v1",
    @"status" : @"pass",
    @"pixel_mode" : mode,
    @"payload_policy" : @"scalar_timing_and_counts_only_no_pixel_payloads",
    @"sample_capacity" : @(kInumaTextureTraceCapacity),
    @"sample_capacity_exhaustions" :
        @(snapshot->sample_capacity_exhaustions),
    @"tail_diagnostics_version" : @19,
    @"trace_clock_domain" :
        @"macos_clock_monotonic_raw_shared_mach_host_time",
    @"texture_notification_contract" :
        @"frame_state_before_platform_thread_notification",
    @"trace_snapshot_monotonic_ns" : @(traceSnapshotMonotonicNs),
    @"trace_snapshot_count" : @(_inumaTraceSnapshotCount),
    @"trace_snapshot_lock_hold_ns" : @(traceSnapshotLockHoldNs),
    @"trace_snapshot_lock_hold_max_ns" :
        @(_inumaTraceSnapshotLockHoldMaxNs),
    @"trace_snapshot_wall_time_ns" :
        @((uint64_t)(NSDate.date.timeIntervalSince1970 * 1000000000.0)),
    @"render_frames" : @(snapshot->render_frames),
    @"accepted_frames" : @(snapshot->accepted_frames),
    @"coalesced_frames" : @(snapshot->coalesced_frames),
    @"copy_calls" : @(snapshot->copy_calls),
    @"copy_hits" : @(snapshot->copy_hits),
    @"copy_misses" : @(snapshot->copy_misses),
    @"source_cv_pixel_buffer_frames" :
        @(snapshot->source_cv_pixel_buffer_frames),
    @"source_i420_frames" : @(snapshot->source_i420_frames),
    @"source_nv12_frames" : @(snapshot->source_nv12_frames),
    @"source_bgra_frames" : @(snapshot->source_bgra_frames),
    @"source_other_pixel_format_frames" :
        @(snapshot->source_other_pixel_format_frames),
    @"native_nv12_frames" : @(snapshot->native_nv12_frames),
    @"native_nv12_fallback_frames" : @(snapshot->native_nv12_fallback_frames),
    @"minimum_texture_hold_ns" : @(_inumaMinimumTextureHoldNs),
    @"texture_hold_applied" : @(snapshot->texture_hold_applied),
    @"stale_texture_notifications" :
        @(snapshot->stale_texture_notifications),
    @"max_queued_texture_frames" : @(_inumaMaxQueuedTextureFrames),
    @"queued_frames" : @(snapshot->queued_frames),
    @"queue_promotions" : @(snapshot->queue_promotions),
    @"queue_overflows" : @(snapshot->queue_overflows),
    @"queue_cleared_frames" : @(snapshot->queue_cleared_frames),
    @"queue_max_depth" : @(snapshot->queue_max_depth),
    @"queue_pending_at_snapshot" : @(pendingTextureFrameCount),
    @"rescue_hold_bypasses" : @(snapshot->rescue_hold_bypasses),
    @"rescue_hold_preservations" :
        @(snapshot->rescue_hold_preservations),
    @"rescue_display_link_schedules" :
        @(snapshot->rescue_display_link_schedules),
    @"rescue_display_link_fires" :
        @(snapshot->rescue_display_link_fires),
    @"rescue_display_link_cancellations" :
        @(snapshot->rescue_display_link_cancellations),
    @"rescue_display_link_fallbacks" :
        @(snapshot->rescue_display_link_fallbacks),
    @"rescue_display_link_stale_fires" :
        @(snapshot->rescue_display_link_stale_fires),
    @"rescue_display_link_callbacks" :
        @(snapshot->rescue_display_link_callbacks),
    @"rescue_display_link_deferrals" :
        @(snapshot->rescue_display_link_deferrals),
    @"rescue_display_link_commit_fence_deferrals" :
        @(snapshot->rescue_display_link_commit_fence_deferrals),
    @"texture_notification_platform_turn_schedules" :
        @(snapshot->texture_notification_platform_turn_schedules),
    @"texture_notification_platform_turn_fires" :
        @(snapshot->texture_notification_platform_turn_fires),
    @"rescue_display_link_active_at_snapshot" :
        @(rescueDisplayLinkActive),
    @"strict_hold_timer_created" :
        @(snapshot->strict_hold_timer_created),
    @"strict_hold_timer_fired" : @(snapshot->strict_hold_timer_fired),
    @"strict_hold_timer_cancelled" :
        @(snapshot->strict_hold_timer_cancelled),
    @"strict_hold_timer_create_failures" :
        @(snapshot->strict_hold_timer_create_failures),
    @"strict_hold_timer_active_at_snapshot" :
        @(textureHoldTimerActive),
    @"stock_bgra_pool_minimum_buffer_count" :
        @(kInumaStockBGRAPoolMinimumBufferCount),
    @"stock_bgra_pool_create_failures" :
        @(snapshot->stock_bgra_pool_create_failures),
    @"stock_bgra_pool_buffer_requests" :
        @(snapshot->stock_bgra_pool_buffer_requests),
    @"stock_bgra_pool_buffer_failures" :
        @(snapshot->stock_bgra_pool_buffer_failures),
    @"mutable_single_bgra_buffer_reuse_enabled" : @NO,
    @"conversion_ns" : InumaTraceSampleArray(snapshot->conversion_samples,
                                             snapshot->conversion_count),
    @"render_lock_wait_ns" : InumaTraceSampleArray(
        snapshot->render_lock_wait_samples, snapshot->render_lock_wait_count),
    @"copy_lock_wait_ns" : InumaTraceSampleArray(
        snapshot->copy_lock_wait_samples, snapshot->copy_lock_wait_count),
    @"copy_ready_age_ns" : InumaTraceSampleArray(
        snapshot->copy_ready_age_samples, snapshot->copy_ready_age_count),
    @"texture_notify_dispatch_ns" : InumaTraceSampleArray(
        snapshot->texture_notify_dispatch_samples,
        snapshot->texture_notify_dispatch_count),
    @"texture_notify_ns" : InumaTraceSampleArray(
        snapshot->texture_notify_samples, snapshot->texture_notify_count),
    @"texture_hold_delay_ns" : InumaTraceSampleArray(
        snapshot->texture_hold_delay_samples,
        snapshot->texture_hold_delay_count),
    @"texture_hold_frame_timestamp_ns" : InumaTraceSignedSampleArray(
        snapshot->texture_hold_frame_timestamp_ns_samples,
        snapshot->texture_hold_delay_count),
    @"texture_notify_event_offset_ns" : InumaTraceSampleArray(
        snapshot->texture_notify_event_offset_samples,
        snapshot->texture_notify_event_count),
    @"texture_notify_frame_timestamp_ns" : InumaTraceSignedSampleArray(
        snapshot->texture_notify_frame_timestamp_ns_samples,
        snapshot->texture_notify_event_count),
    @"texture_notify_scheduled_delay_ns" : InumaTraceSampleArray(
        snapshot->texture_notify_scheduled_delay_samples,
        snapshot->texture_notify_event_count),
    @"texture_notify_deadline_lateness_ns" : InumaTraceSampleArray(
        snapshot->texture_notify_deadline_lateness_samples,
        snapshot->texture_notify_event_count),
    @"queue_wait_ns" : InumaTraceSampleArray(
        snapshot->queue_wait_samples, snapshot->queue_wait_count),
    @"queue_enqueue_event_offset_ns" : InumaTraceSampleArray(
        snapshot->queue_enqueue_event_offset_samples,
        snapshot->queue_enqueue_event_count),
    @"queue_enqueue_frame_timestamp_ns" : InumaTraceSignedSampleArray(
        snapshot->queue_enqueue_frame_timestamp_ns_samples,
        snapshot->queue_enqueue_event_count),
    @"queue_promote_event_offset_ns" : InumaTraceSampleArray(
        snapshot->queue_promote_event_offset_samples,
        snapshot->queue_promote_event_count),
    @"queue_promote_frame_timestamp_ns" : InumaTraceSignedSampleArray(
        snapshot->queue_promote_frame_timestamp_ns_samples,
        snapshot->queue_promote_event_count),
    @"rescue_hold_bypass_frame_timestamp_ns" : InumaTraceSignedSampleArray(
        snapshot->rescue_hold_bypass_frame_timestamp_ns_samples,
        snapshot->rescue_hold_bypass_count),
    @"rescue_hold_preservation_frame_timestamp_ns" :
        InumaTraceSignedSampleArray(
            snapshot->rescue_hold_preservation_frame_timestamp_ns_samples,
            snapshot->rescue_hold_preservation_count),
    @"rescue_display_link_schedule_offset_ns" : InumaTraceSampleArray(
        snapshot->rescue_display_link_schedule_offset_samples,
        snapshot->rescue_display_link_event_count),
    @"rescue_display_link_fire_offset_ns" : InumaTraceSampleArray(
        snapshot->rescue_display_link_fire_offset_samples,
        snapshot->rescue_display_link_event_count),
    @"rescue_display_link_presentation_ack_ns" : InumaTraceSampleArray(
        snapshot->rescue_display_link_presentation_ack_samples,
        snapshot->rescue_display_link_event_count),
    @"rescue_display_link_first_presentation_ack_ns" :
        InumaTraceSampleArray(
            snapshot->rescue_display_link_first_presentation_ack_samples,
            snapshot->rescue_display_link_event_count),
    @"rescue_display_link_callback_count" : InumaTraceSampleArray(
        snapshot->rescue_display_link_callback_count_samples,
        snapshot->rescue_display_link_event_count),
    @"rescue_display_link_frame_timestamp_ns" : InumaTraceSignedSampleArray(
        snapshot->rescue_display_link_frame_timestamp_ns_samples,
        snapshot->rescue_display_link_event_count),
    @"strict_hold_timer_deadline_offset_ns" : InumaTraceSampleArray(
        snapshot->strict_hold_timer_deadline_offset_samples,
        snapshot->strict_hold_timer_event_count),
    @"strict_hold_timer_fire_offset_ns" : InumaTraceSampleArray(
        snapshot->strict_hold_timer_fire_offset_samples,
        snapshot->strict_hold_timer_event_count),
    @"strict_hold_timer_frame_timestamp_ns" : InumaTraceSignedSampleArray(
        snapshot->strict_hold_timer_frame_timestamp_ns_samples,
        snapshot->strict_hold_timer_event_count),
    @"trace_started_monotonic_ns" : @(_inumaTraceStartedMonotonicNs),
    @"render_event_offset_ns" : InumaTraceSampleArray(
        snapshot->render_event_offset_samples, snapshot->render_event_count),
    @"render_frame_timestamp_ns" : InumaTraceSignedSampleArray(
        snapshot->render_frame_timestamp_ns_samples,
        snapshot->render_event_count),
    @"render_outcome" : InumaTraceByteSampleArray(
        snapshot->render_outcome_samples, snapshot->render_event_count),
    @"render_outcome_codes" : @{
      @"0" : @"ignored",
      @"1" : @"accepted",
      @"2" : @"coalesced",
    },
    @"coalesced_pending_age_ns" : InumaTraceSampleArray(
        snapshot->coalesced_pending_age_samples,
        snapshot->coalesced_pending_age_count),
    @"copy_event_offset_ns" : InumaTraceSampleArray(
        snapshot->copy_event_offset_samples, snapshot->copy_event_count),
    @"copy_frame_timestamp_ns" : InumaTraceSignedSampleArray(
        snapshot->copy_frame_timestamp_ns_samples,
        snapshot->copy_event_count),
  };
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:report
                                                 options:0
                                                   error:&error];
  if (data == nil || error != nil) {
    free(snapshot);
    return;
  }
  [data writeToFile:_inumaTracePath options:NSDataWritingAtomic error:&error];
  free(snapshot);
}
#endif

/**
 * Sets the size of the video frame to render.
 *
 * @param size The size of the video frame to render.
 */
- (void)setSize:(CGSize)size {
  os_unfair_lock_lock(&_lock);
  if (size.width != _frameSize.width || size.height != _frameSize.height) {
#if TARGET_OS_OSX
    [self inumaCancelTextureHoldTimerLocked];
    [self inumaCancelRescueDisplayLinkLocked];
    [self inumaClearPendingTextureFramesLocked];
#endif
    if (_pixelBufferRef) {
      CVBufferRelease(_pixelBufferRef);
      _pixelBufferRef = nil;
    }
#if TARGET_OS_OSX
    [self inumaResetStockBGRAPixelBufferPoolForSize:size];
#else
    NSDictionary *pixelAttributes =
        @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
    CVPixelBufferCreate(
        kCFAllocatorDefault, size.width, size.height, kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)(pixelAttributes), &_pixelBufferRef);
#endif
    _frameAvailable = false;
    _frameSize = size;
  }
  os_unfair_lock_unlock(&_lock);
}

#pragma mark - FlutterStreamHandler methods

- (FlutterError *_Nullable)onCancelWithArguments:(id _Nullable)arguments {
  _eventSink = nil;
  return nil;
}

- (FlutterError *_Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:
                                           (nonnull FlutterEventSink)sink {
  _eventSink = sink;
  return nil;
}
@end

@implementation FlutterWebRTCPlugin (FlutterVideoRendererManager)

- (FlutterRTCVideoRenderer *)
    createWithTextureRegistry:(id<FlutterTextureRegistry>)registry
                    messenger:(NSObject<FlutterBinaryMessenger> *)messenger {
  return [[FlutterRTCVideoRenderer alloc] initWithTextureRegistry:registry
                                                        messenger:messenger];
}

- (void)rendererSetSrcObject:(FlutterRTCVideoRenderer *)renderer
                      stream:(RTCVideoTrack *)videoTrack {
  renderer.videoTrack = videoTrack;
}
@end
