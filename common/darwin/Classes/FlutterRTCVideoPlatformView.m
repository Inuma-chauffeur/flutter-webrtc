#import "FlutterRTCVideoPlatformView.h"

#import <QuartzCore/QuartzCore.h>
#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCI420Buffer.h>
#import <WebRTC/RTCYUVHelper.h>
#import <os/lock.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#if TARGET_OS_OSX
#include "InumaDecoderBoundaryTrace.h"
#include "InumaLowLatencyVideoPlayoutConfiguration.h"
#include "InumaNativePresentationSeams.h"
#include "InumaPrerendererSmoothingConfiguration.h"
#include "InumaSegmentedScalarEvidenceWriter.h"

enum {
  kInumaNativeVideoSurfaceTraceCapacity = 65536,
  kInumaNativePresentationTraceV2Capacity = 65536,
  kInumaDisplayedContextCapacity = 256,
};
static const uint64_t kInumaStrictReplayFrameIntervalNs = 33333333;
static const uint64_t kInumaTraceCoherentSnapshotRetryNs = 10000000;
static const NSUInteger kInumaTraceMaximumCoherentSnapshotRetries = 3;
static const void* kInumaNativeVideoSurfaceQueueKey =
    &kInumaNativeVideoSurfaceQueueKey;
static os_unfair_lock gInumaNativeVideoSurfaceLifecycleLock =
    OS_UNFAIR_LOCK_INIT;
static uint64_t gInumaNativeVideoSurfaceCreatedCount = 0;
static uint64_t gInumaNativeVideoSurfaceLiveCount = 0;
static uint64_t gInumaNativeVideoSurfaceMaximumLiveCount = 0;

typedef struct {
  bool enabled;
  uint64_t render_frames;
  uint64_t direct_pixel_buffer_frames;
  uint64_t converted_pixel_buffer_frames;
  uint64_t pixel_buffer_failures;
  uint64_t sample_buffer_failures;
  uint64_t enqueue_attempts;
  uint64_t enqueue_completions;
  uint64_t renderer_not_ready_observations;
  uint64_t renderer_flushes;
  uint64_t renderer_failures;
  uint64_t modern_renderer_enqueues;
  uint64_t legacy_layer_enqueues;
  uint64_t latest_sample_submissions;
  uint64_t latest_sample_replacements;
  uint64_t latest_sample_rejections_after_shutdown;
  uint64_t latest_sample_releases_on_shutdown;
  uint64_t drain_callbacks_scheduled;
  uint64_t drain_dequeues;
  uint64_t queue_depth_high_water;
  uint64_t strict_replay_pacing_accepted;
  uint64_t strict_replay_pacing_late_rejections;
  uint64_t strict_replay_pacing_pacer_late_rejections;
  uint64_t strict_replay_pacing_overflow_rejections;
  uint64_t strict_replay_pacing_sequence_rejections;
  uint64_t strict_replay_pacing_added_latency_rejections;
  uint64_t strict_replay_pacing_prearm_discards;
  uint64_t strict_replay_pacing_rearm_count;
  uint64_t strict_replay_pacing_rearm_prearm_discards;
  uint64_t strict_replay_pacing_arm_count;
  uint64_t strict_replay_pacing_late_phase_corrections;
  uint64_t strict_replay_pacing_early_phase_corrections;
  uint64_t strict_replay_dispatch_submissions;
  uint64_t strict_replay_dispatch_late_rejections;
  uint64_t strict_replay_dispatch_overflow_rejections;
  uint64_t strict_replay_dispatch_depth_high_water;
  uint64_t strict_replay_display_link_callbacks;
  uint64_t strict_replay_display_phase_updates;
  uint64_t strict_replay_display_phase_rejections;
  uint64_t strict_replay_last_display_timestamp_ns;
  uint64_t strict_replay_last_display_target_time_ns;
  uint64_t strict_replay_last_display_refresh_period_ns;
  uint64_t renderer_performance_metric_request_count;
  uint64_t renderer_performance_metric_callback_count;
  uint64_t renderer_performance_metric_snapshot_count;
  uint64_t renderer_performance_metric_nil_count;
  uint64_t renderer_performance_metric_invalid_count;
  uint64_t renderer_performance_metric_total_frames;
  uint64_t renderer_performance_metric_dropped_frames;
  uint64_t renderer_performance_metric_corrupted_frames;
  uint64_t renderer_performance_metric_optimized_compositing_frames;
  uint64_t renderer_performance_metric_total_accumulated_delay_ns;
  uint64_t renderer_performance_metric_last_snapshot_monotonic_ns;
  uint64_t shutdown_count;
  uint64_t display_identity_context_binding_attempts;
  uint64_t display_identity_context_binding_successes;
  uint64_t display_identity_context_binding_failures;
  uint64_t display_identity_context_binding_total_duration_ns;
  uint64_t display_identity_context_binding_maximum_duration_ns;
  uint64_t display_identity_context_binding_durations_over_250us;
  uint64_t display_identity_context_binding_durations_over_1ms;
  uint64_t display_identity_context_registrations;
  uint64_t display_identity_context_registration_failures;
  uint64_t display_identity_watermark_reads;
  uint64_t display_identity_watermark_decode_successes;
  uint64_t display_identity_watermark_decode_total_duration_ns;
  uint64_t display_identity_watermark_decode_maximum_duration_ns;
  uint64_t display_identity_watermark_decode_durations_over_250us;
  uint64_t display_identity_watermark_decode_durations_over_1ms;
  uint64_t display_identity_unsupported_pixel_format_failures;
  uint64_t display_identity_pixel_buffer_lock_failures;
  uint64_t display_identity_geometry_failures;
  uint64_t display_identity_contrast_failures;
  uint64_t display_identity_sync_failures;
  uint64_t display_identity_checksum_failures;
  uint64_t display_identity_context_misses;
  uint64_t display_identity_invalid_lookups;
  uint64_t display_identity_pointer_comparisons;
  uint64_t capacity_exhaustions;
  NSUInteger render_event_count;
  NSUInteger enqueue_event_count;
  uint64_t render_event_offset_ns[kInumaNativeVideoSurfaceTraceCapacity];
  uint64_t render_frame_generation[kInumaNativeVideoSurfaceTraceCapacity];
  uint64_t enqueue_event_offset_ns[kInumaNativeVideoSurfaceTraceCapacity];
  uint64_t enqueue_frame_generation[kInumaNativeVideoSurfaceTraceCapacity];
  uint64_t enqueue_call_duration_ns[kInumaNativeVideoSurfaceTraceCapacity];
} InumaNativeVideoSurfaceTrace;

static uint64_t InumaNativeSurfaceMonotonicNanoseconds(void) {
  return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
}

static uint64_t InumaNativeSurfaceHostTimeNanoseconds(void) {
  const CMTime hostTime = CMClockGetTime(CMClockGetHostTimeClock());
  const CMTime nanoseconds =
      CMTimeConvertScale(hostTime, 1000000000, kCMTimeRoundingMethod_Default);
  return CMTIME_IS_NUMERIC(nanoseconds) && nanoseconds.value > 0
             ? (uint64_t)nanoseconds.value
             : 0;
}

static uint64_t InumaFiniteSecondsToNanoseconds(CFTimeInterval value) {
  if (!isfinite(value) || value <= 0.0 ||
      value >= ((CFTimeInterval)UINT64_MAX / 1000000000.0)) {
    return 0;
  }
  return (uint64_t)(value * 1000000000.0 + 0.5);
}

static uint64_t InumaStrictReplayReserveNanoseconds(
    NSDictionary<NSString*, NSString*>* environment) {
  NSString* raw = environment[
      @"INUMA_FLUTTER_WEBRTC_MACOS_STRICT_REPLAY_RESERVE_NS"];
  const long long signedValue = raw.longLongValue;
  if (raw.length == 0 ||
      signedValue <= 0 ||
      ![raw isEqualToString:[NSString stringWithFormat:@"%lld", signedValue]]) {
    return 0;
  }
  const uint64_t value = (uint64_t)signedValue;
  switch (value) {
    case 33333333:
    case 50000000:
    case 66666667:
    case 83333333:
    case 95000000:
    case 100000000:
      return value;
    default:
      return 0;
  }
}

static NSArray<NSNumber*>* InumaNativeSurfaceSamples(const uint64_t* values,
                                                     NSUInteger count) {
  NSMutableArray<NSNumber*>* result = [NSMutableArray arrayWithCapacity:count];
  for (NSUInteger index = 0; index < count; index++) {
    [result addObject:@(values[index])];
  }
  return result;
}
#endif

#if TARGET_OS_OSX
typedef void (^InumaPresentationDisplayLinkHandler)(id displayLink);

@interface InumaPresentationDisplayLinkTarget : NSObject

- (instancetype)initWithHandler:(InumaPresentationDisplayLinkHandler)handler;
- (void)displayLinkDidFire:(id)displayLink;

@end


@implementation InumaPresentationDisplayLinkTarget {
  InumaPresentationDisplayLinkHandler _handler;
}

- (instancetype)initWithHandler:(InumaPresentationDisplayLinkHandler)handler {
  self = [super init];
  if (self) {
    _handler = [handler copy];
  }
  return self;
}

- (void)displayLinkDidFire:(id)displayLink {
  _handler(displayLink);
}

@end
#endif

@implementation FlutterRTCVideoPlatformView {
  AVSampleBufferDisplayLayer* _videoLayer;
  dispatch_queue_t _sampleBufferQueue;
  RTCVideoRotation _lastVideoRotation;
  CVPixelBufferPoolRef _cropAndScalePixelBufferPool;
  int _cropAndScalePixelBufferPoolWidth;
  int _cropAndScalePixelBufferPoolHeight;
  OSType _cropAndScalePixelBufferPoolPixelFormat;
#if TARGET_OS_OSX
  os_unfair_lock _inumaTraceLock;
  InumaNativeVideoSurfaceTrace _inumaTrace;
  NSString* _inumaTracePath;
  uint64_t _inumaTraceStartedMonotonicNs;
  uint64_t _inumaFrameGeneration;
  uint64_t _inumaTraceSnapshotCount;
  uint64_t _inumaCoherentSnapshotRetryCount;
  dispatch_source_t _inumaTraceTimer;
  dispatch_queue_t _inumaTraceWriterQueue;
  dispatch_source_t _inumaPresentationObserverTimer;
  dispatch_queue_t _inumaPresentationObserverQueue;
  id _inumaPresentationDisplayLink;
  InumaPresentationDisplayLinkTarget* _inumaPresentationDisplayLinkTarget;
  InumaDisplayedFrameIdentityLedger* _inumaDisplayedIdentityLedger;
  uint64_t _inumaLastObservedNativeGeneration;
  BOOL _inumaHasLastObservedNativeGeneration;
  BOOL _inumaHasObservedPresentationState;
  BOOL _inumaLastObservationResolved;
  BOOL _inumaNativeSurfaceSelected;
  BOOL _inumaStrictReplayPaced;
  uint64_t _inumaStrictReplayReserveNs;
  BOOL _inumaRendererPerformanceMetricRequestPending;
  BOOL _inumaSurfaceRegistered;
  BOOL _inumaDrainScheduled;
  NSUInteger _inumaStrictReplayDispatchPending;
  BOOL _inumaStopRequested;
  BOOL _inumaShuttingDown;
  CMSampleBufferRef _inumaPendingSampleBuffer;
  RTCVideoRotation _inumaPendingRotation;
  uint64_t _inumaPendingSetAtNs;
  InumaPresentationFrameContext _inumaPendingContext;
  InumaVideoSampleBuilder* _inumaSampleBuilder;
  InumaStrictReplayPacer* _inumaStrictReplayPacer;
  InumaSampleRendererAdapter* _inumaRendererAdapter;
  InumaNativePresentationTrace* _inumaPresentationTrace;
  InumaSegmentedScalarEvidenceWriter* _inumaSegmentedEvidenceWriter;
  uint64_t _inumaSegmentStartedMonotonicNs;
  BOOL _inumaSegmentedEvidenceEnabled;
  uint64_t _inumaSurfaceSessionSequence;
#endif
}

- (instancetype)initWithFrame:(FlutterRTCVideoPlatformFrame)frame {
  if (self = [super initWithFrame:frame]) {
#if TARGET_OS_OSX
    self.wantsLayer = YES;
#endif
    _videoLayer = [[AVSampleBufferDisplayLayer alloc] init];
    _videoLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    _videoLayer.frame = CGRectZero;
    _sampleBufferQueue =
        dispatch_queue_create("com.cloudwebrtc.flutterwebrtc.video-platform-view.sample-buffer",
                              DISPATCH_QUEUE_SERIAL);
#if TARGET_OS_OSX
    dispatch_queue_set_specific(_sampleBufferQueue,
                                kInumaNativeVideoSurfaceQueueKey,
                                (void*)kInumaNativeVideoSurfaceQueueKey, NULL);
#endif
    _lastVideoRotation = RTCVideoRotation_0;
#if TARGET_OS_OSX
    _inumaTraceLock = OS_UNFAIR_LOCK_INIT;
    NSDictionary<NSString*, NSString*>* environment = NSProcessInfo.processInfo.environment;
    _inumaNativeSurfaceSelected =
        [environment[@"INUMA_FLUTTER_WEBRTC_MACOS_PIXEL_MODE"]
            isEqualToString:@"native_platform_view"];
    _inumaStrictReplayPaced =
        [environment[@"INUMA_FLUTTER_WEBRTC_MACOS_PRESENTATION_POLICY"]
            isEqualToString:@"strict_replay_paced"];
    _inumaStrictReplayReserveNs =
        _inumaStrictReplayPaced
            ? InumaStrictReplayReserveNanoseconds(environment)
            : 0;
    _inumaTracePath = _inumaNativeSurfaceSelected
                          ? [environment[@"INUMA_FLUTTER_WEBRTC_TEXTURE_TRACE_PATH"] copy]
                          : nil;
    _inumaTrace.enabled = _inumaTracePath.length > 0;
    _inumaSegmentedEvidenceEnabled =
        [environment[@"INUMA_FLUTTER_WEBRTC_SEGMENTED_SCALAR_EVIDENCE"]
            isEqualToString:@"1"];
    _inumaTraceStartedMonotonicNs = _inumaTrace.enabled
                                        ? InumaNativeSurfaceMonotonicNanoseconds()
                                        : 0;
    if (_inumaNativeSurfaceSelected) {
      _inumaSampleBuilder = [[InumaVideoSampleBuilder alloc] init];
      if (_inumaStrictReplayPaced && _inumaStrictReplayReserveNs > 0) {
        const NSUInteger capacity =
            _inumaStrictReplayReserveNs == 95000000
                ? 4
                : (NSUInteger)(_inumaStrictReplayReserveNs /
                               kInumaStrictReplayFrameIntervalNs) +
                      1;
        _inumaStrictReplayPacer = [[InumaStrictReplayPacer alloc]
            initWithPresentationReserveNs:_inumaStrictReplayReserveNs
                           frameIntervalNs:kInumaStrictReplayFrameIntervalNs
                             queueCapacity:capacity
                             hostTimeClock:nil];
      }
      os_unfair_lock_lock(&gInumaNativeVideoSurfaceLifecycleLock);
      gInumaNativeVideoSurfaceCreatedCount += 1;
      gInumaNativeVideoSurfaceLiveCount += 1;
      gInumaNativeVideoSurfaceMaximumLiveCount =
          MAX(gInumaNativeVideoSurfaceMaximumLiveCount,
              gInumaNativeVideoSurfaceLiveCount);
      _inumaSurfaceSessionSequence = gInumaNativeVideoSurfaceCreatedCount;
      _inumaSurfaceRegistered = YES;
      os_unfair_lock_unlock(&gInumaNativeVideoSurfaceLifecycleLock);
      if (_inumaTrace.enabled) {
        _inumaPresentationTrace = [[InumaNativePresentationTrace alloc]
            initWithCapacity:kInumaNativePresentationTraceV2Capacity
             sessionSequence:_inumaSurfaceSessionSequence
                 startedAtNs:_inumaTraceStartedMonotonicNs];
        _inumaDisplayedIdentityLedger =
            [[InumaDisplayedFrameIdentityLedger alloc]
                initWithCapacity:kInumaDisplayedContextCapacity];
        if (_inumaSegmentedEvidenceEnabled) {
          _inumaSegmentStartedMonotonicNs = _inumaTraceStartedMonotonicNs;
          _inumaSegmentedEvidenceWriter =
              [[InumaSegmentedScalarEvidenceWriter alloc]
                  initWithManifestPath:_inumaTracePath
                       sessionSequence:_inumaSurfaceSessionSequence
                     traceStartedAtNs:_inumaTraceStartedMonotonicNs
                      segmentIntervalNs:5 * NSEC_PER_SEC];
        }
      }
#if defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && __MAC_OS_X_VERSION_MAX_ALLOWED >= 140000
      if (@available(macOS 14.0, *)) {
        InumaAVSampleRendererBackend* backend =
            [[InumaAVSampleRendererBackend alloc]
                initWithRenderer:_videoLayer.sampleBufferRenderer];
        _inumaRendererAdapter = [[InumaSampleRendererAdapter alloc]
            initWithBackend:backend
                       clock:[InumaMonotonicClock systemClock]
                   traceSink:_inumaPresentationTrace];
        if (_inumaPresentationTrace != nil &&
            _inumaDisplayedIdentityLedger != nil) {
          [self inumaStartNativePresentationObserver];
        }
      }
#endif
    }
    if (_inumaTrace.enabled) {
      _inumaTraceWriterQueue = dispatch_queue_create(
          "com.cloudwebrtc.flutterwebrtc.video-platform-view.trace-writer",
          DISPATCH_QUEUE_SERIAL);
      _inumaTraceTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                _inumaTraceWriterQueue);
      dispatch_source_set_timer(
          _inumaTraceTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
          5 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
      __weak FlutterRTCVideoPlatformView* weakSelf = self;
      dispatch_source_set_event_handler(_inumaTraceTimer, ^{
        [weakSelf inumaRequestRendererPerformanceMetrics];
        [weakSelf inumaWriteNativeVideoSurfaceTraceOnWriterQueueWithRetryAttempt:0
                                                                      terminal:NO];
      });
      dispatch_resume(_inumaTraceTimer);
    }
#endif
    [self.layer addSublayer:_videoLayer];
#if TARGET_OS_IPHONE
    self.opaque = NO;
#endif
  }
  return self;
}

- (void)dealloc {
#if TARGET_OS_OSX
  [self inumaStopNativeVideoSurface];
#endif
  if (_cropAndScalePixelBufferPool) {
    CFRelease(_cropAndScalePixelBufferPool);
    _cropAndScalePixelBufferPool = NULL;
  }
}

#if TARGET_OS_IPHONE
- (void)layoutSubviews {
  [super layoutSubviews];
  [self layoutVideoLayer];
}
#elif TARGET_OS_OSX
- (BOOL)isOpaque {
  return NO;
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window == nil) {
    [self inumaStopPresentationDisplayLink];
  } else {
    [self inumaStartPresentationDisplayLink];
  }
}

- (void)layout {
  [super layout];
  [self layoutVideoLayer];
}
#endif

- (void)layoutVideoLayer {
  _videoLayer.frame = self.bounds;
  [_videoLayer removeAllAnimations];
}

- (void)setSize:(CGSize)size {
}

- (void)renderFrame:(nullable RTC_OBJC_TYPE(RTCVideoFrame) *)frame {
  if (!frame) {
    return;
  }

#if TARGET_OS_OSX
  uint64_t frameGeneration = 0;
  uint64_t frameRtpTimestamp = 0;
  InumaPresentationFrameContext frameContext = {0};
  if (_inumaTrace.enabled || _inumaStrictReplayPaced) {
    const uint64_t renderedAt = InumaNativeSurfaceMonotonicNanoseconds();
    os_unfair_lock_lock(&_inumaTraceLock);
    _inumaFrameGeneration += 1;
    frameGeneration = _inumaFrameGeneration;
    _inumaTrace.render_frames += 1;
    if (_inumaTrace.render_event_count < kInumaNativeVideoSurfaceTraceCapacity) {
      const NSUInteger index = _inumaTrace.render_event_count++;
      _inumaTrace.render_event_offset_ns[index] =
          renderedAt - _inumaTraceStartedMonotonicNs;
      _inumaTrace.render_frame_generation[index] = frameGeneration;
    } else {
      _inumaTrace.capacity_exhaustions += 1;
    }
    os_unfair_lock_unlock(&_inumaTraceLock);
    frameContext.renderOrdinal = frameGeneration - 1;
    frameContext.nativeGeneration = frameGeneration;
    frameContext.rtpTimestamp = (uint64_t)(uint32_t)frame.timeStamp;
    frameContext.timingPolicy = _inumaStrictReplayPaced
                                    ? InumaPresentationTimingValidHostPTS
                                    : InumaPresentationTimingImmediateInvalid;
    frameRtpTimestamp = frameContext.rtpTimestamp;
    if (_inumaTrace.enabled) {
      [_inumaPresentationTrace recordEventKind:InumaPresentationEventRenderReceived
                                          atNs:renderedAt
                                       context:frameContext
                                     durationNs:0
                                           value:0];
    }
  }
#else
  const uint64_t frameGeneration = 0;
  const uint64_t frameRtpTimestamp = 0;
#endif

  CVPixelBufferRef pixelBuffer = nil;
  if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
    pixelBuffer = [self pixelBufferFromRTCCVPixelBuffer:(RTCCVPixelBuffer*)frame.buffer];
#if TARGET_OS_OSX
    if (_inumaTrace.enabled && pixelBuffer != nil) {
      os_unfair_lock_lock(&_inumaTraceLock);
      _inumaTrace.direct_pixel_buffer_frames += 1;
      os_unfair_lock_unlock(&_inumaTraceLock);
    }
#endif
  } else {
    pixelBuffer = [self toCVPixelBuffer:frame];
#if TARGET_OS_OSX
    if (_inumaTrace.enabled && pixelBuffer != nil) {
      os_unfair_lock_lock(&_inumaTraceLock);
      _inumaTrace.converted_pixel_buffer_frames += 1;
      os_unfair_lock_unlock(&_inumaTraceLock);
    }
#endif
  }

  if (!pixelBuffer) {
#if TARGET_OS_OSX
    if (_inumaTrace.enabled) {
      os_unfair_lock_lock(&_inumaTraceLock);
      _inumaTrace.pixel_buffer_failures += 1;
      os_unfair_lock_unlock(&_inumaTraceLock);
    }
#endif
    return;
  }

  RTCVideoRotation rotation = frame.rotation;
#if TARGET_OS_OSX
  const uint64_t sampleBuildStarted = _inumaTrace.enabled
                                          ? InumaNativeSurfaceMonotonicNanoseconds()
                                          : 0;
  if (_inumaTrace.enabled) {
    [_inumaPresentationTrace recordEventKind:InumaPresentationEventSampleBuildBegin
                                        atNs:sampleBuildStarted
                                     context:frameContext
                                   durationNs:0
                                         value:0];
  }
  InumaStrictReplayPacingDecision pacingDecision = {0};
  if (_inumaStrictReplayPaced && _inumaStrictReplayPacer != nil) {
    pacingDecision =
        [_inumaStrictReplayPacer decisionForGeneration:frameGeneration];
    frameContext.presentationReserveNs = _inumaStrictReplayReserveNs;
    frameContext.scheduledPresentationTimeNs =
        pacingDecision.scheduledPresentationTimeNs;
    frameContext.presentationResidenceNs =
        pacingDecision.presentationResidenceNs;
    frameContext.presentationLatenessNs = pacingDecision.latenessNs;
    frameContext.presentationQueueDepth = pacingDecision.queueDepthAfter;
  }
  if (_inumaStrictReplayPaced && !pacingDecision.accepted) {
    if (pacingDecision.prearmDiscarded) {
      if (_inumaTrace.enabled) {
        os_unfair_lock_lock(&_inumaTraceLock);
        _inumaTrace.strict_replay_pacing_prearm_discards += 1;
        _inumaTrace.strict_replay_pacing_rearm_prearm_discards +=
            pacingDecision.rearmPrearmDiscarded ? 1 : 0;
        os_unfair_lock_unlock(&_inumaTraceLock);
        [_inumaPresentationTrace
            recordEventKind:InumaPresentationEventPacingPrearmDiscarded
                        atNs:sampleBuildStarted
                     context:frameContext
                   durationNs:0
                         value:_inumaStrictReplayPacer.prearmDiscardCount];
      }
      CFRelease(pixelBuffer);
      return;
    }
    const InumaPresentationEventKind rejection =
        !pacingDecision.generationSequenceValid
            ? InumaPresentationEventPacingSequenceRejected
            : (pacingDecision.addedLatencyExceeded
                   ? InumaPresentationEventPacingAddedLatencyRejected
                   : (pacingDecision.overflowed
                          ? InumaPresentationEventPacingOverflowRejected
                          : InumaPresentationEventPacingLateRejected));
    if (_inumaTrace.enabled) {
      os_unfair_lock_lock(&_inumaTraceLock);
      _inumaTrace.strict_replay_pacing_sequence_rejections +=
          rejection == InumaPresentationEventPacingSequenceRejected ? 1 : 0;
      _inumaTrace.strict_replay_pacing_overflow_rejections +=
          rejection == InumaPresentationEventPacingOverflowRejected ? 1 : 0;
      _inumaTrace.strict_replay_pacing_late_rejections +=
          rejection == InumaPresentationEventPacingLateRejected ? 1 : 0;
      _inumaTrace.strict_replay_pacing_pacer_late_rejections +=
          rejection == InumaPresentationEventPacingLateRejected ? 1 : 0;
      _inumaTrace.strict_replay_pacing_added_latency_rejections +=
          rejection == InumaPresentationEventPacingAddedLatencyRejected ? 1 : 0;
      _inumaTrace.strict_replay_pacing_rearm_count +=
          pacingDecision.rearmTriggered ? 1 : 0;
      os_unfair_lock_unlock(&_inumaTraceLock);
      [_inumaPresentationTrace recordEventKind:rejection
                                          atNs:sampleBuildStarted
                                       context:frameContext
                                     durationNs:pacingDecision.latenessNs
                                           value:pacingDecision.queueDepthBefore];
    }
    CFRelease(pixelBuffer);
    return;
  }
  if (_inumaTrace.enabled && _inumaStrictReplayPaced) {
    os_unfair_lock_lock(&_inumaTraceLock);
    _inumaTrace.strict_replay_pacing_accepted += 1;
    _inumaTrace.strict_replay_pacing_late_phase_corrections +=
        pacingDecision.latePhaseCorrected ? 1 : 0;
    _inumaTrace.strict_replay_pacing_early_phase_corrections +=
        pacingDecision.earlyPhaseCorrected ? 1 : 0;
    _inumaTrace.strict_replay_pacing_arm_count +=
        pacingDecision.timelineStarted ? 1 : 0;
    os_unfair_lock_unlock(&_inumaTraceLock);
    if (pacingDecision.latePhaseCorrected) {
      [_inumaPresentationTrace
          recordEventKind:InumaPresentationEventPacingLatePhaseCorrected
                      atNs:sampleBuildStarted
                   context:frameContext
                 durationNs:pacingDecision.presentationResidenceNs
                       value:pacingDecision.queueDepthAfter];
    }
    if (pacingDecision.earlyPhaseCorrected) {
      [_inumaPresentationTrace
          recordEventKind:InumaPresentationEventPacingEarlyPhaseCorrected
                      atNs:sampleBuildStarted
                   context:frameContext
                 durationNs:pacingDecision.presentationResidenceNs
                       value:pacingDecision.queueDepthAfter];
    }
    [_inumaPresentationTrace recordEventKind:InumaPresentationEventPacingAccepted
                                        atNs:sampleBuildStarted
                                     context:frameContext
                                   durationNs:pacingDecision.presentationResidenceNs
                                         value:pacingDecision.queueDepthAfter];
  }
  CMSampleBufferRef sampleBuffer = nil;
  if (_inumaSampleBuilder == nil) {
    sampleBuffer = [self sampleBufferFromPixelBuffer:pixelBuffer];
  } else if (_inumaStrictReplayPaced) {
    sampleBuffer = [_inumaSampleBuilder
        copyTimedSampleBufferFromPixelBuffer:pixelBuffer
                          presentationTimeNs:
                              pacingDecision.scheduledPresentationTimeNs
                               durationNs:kInumaStrictReplayFrameIntervalNs];
  } else {
    sampleBuffer = [_inumaSampleBuilder
        copyImmediateSampleBufferFromPixelBuffer:pixelBuffer];
  }
#else
  CMSampleBufferRef sampleBuffer = [self sampleBufferFromPixelBuffer:pixelBuffer];
#endif
#if TARGET_OS_OSX
  if (_inumaStrictReplayPaced && sampleBuffer != nil) {
    const uint64_t bindingStartedAt =
        InumaNativeSurfaceMonotonicNanoseconds();
    const InumaDisplayedFrameIdentityLookupResult binding =
        InumaBindProductWatermarkIdentityToContext(pixelBuffer, &frameContext);
    const uint64_t bindingDurationNs =
        InumaNativeSurfaceMonotonicNanoseconds() - bindingStartedAt;
    if (_inumaTrace.enabled) {
      os_unfair_lock_lock(&_inumaTraceLock);
      _inumaTrace.display_identity_context_binding_attempts += 1;
      _inumaTrace.display_identity_context_binding_successes +=
          binding == InumaDisplayedFrameIdentityLookupFound ? 1 : 0;
      _inumaTrace.display_identity_context_binding_failures +=
          binding == InumaDisplayedFrameIdentityLookupFound ? 0 : 1;
      _inumaTrace.display_identity_context_binding_total_duration_ns +=
          bindingDurationNs;
      _inumaTrace.display_identity_context_binding_maximum_duration_ns =
          MAX(_inumaTrace.display_identity_context_binding_maximum_duration_ns,
              bindingDurationNs);
      _inumaTrace.display_identity_context_binding_durations_over_250us +=
          bindingDurationNs > 250000 ? 1 : 0;
      _inumaTrace.display_identity_context_binding_durations_over_1ms +=
          bindingDurationNs > 1000000 ? 1 : 0;
      os_unfair_lock_unlock(&_inumaTraceLock);
    }
  }
#endif
  CFRelease(pixelBuffer);

  if (!sampleBuffer) {
#if TARGET_OS_OSX
    if (_inumaTrace.enabled) {
      const uint64_t failedAt = InumaNativeSurfaceMonotonicNanoseconds();
      os_unfair_lock_lock(&_inumaTraceLock);
      _inumaTrace.sample_buffer_failures += 1;
      os_unfair_lock_unlock(&_inumaTraceLock);
      [_inumaPresentationTrace recordEventKind:InumaPresentationEventSampleBuildFailed
                                          atNs:failedAt
                                       context:frameContext
                                     durationNs:failedAt - sampleBuildStarted
                                           value:0];
    }
#endif
    return;
  }

#if TARGET_OS_OSX
  if (_inumaTrace.enabled) {
    const uint64_t sampleBuiltAt = InumaNativeSurfaceMonotonicNanoseconds();
    [_inumaPresentationTrace recordEventKind:InumaPresentationEventSampleBuildEnd
                                        atNs:sampleBuiltAt
                                     context:frameContext
                                   durationNs:sampleBuiltAt - sampleBuildStarted
                                         value:0];
    [self inumaRegisterDisplayedContext:frameContext];
  }
  if (_inumaNativeSurfaceSelected) {
    if (_inumaStrictReplayPaced) {
      [self inumaSubmitStrictReplaySampleBuffer:sampleBuffer
                                       rotation:rotation
                                   frameContext:frameContext];
    } else {
      [self inumaSubmitLatestSampleBuffer:sampleBuffer
                                rotation:rotation
                            frameContext:frameContext];
    }
  } else {
#endif
    dispatch_async(_sampleBufferQueue, ^{
      [self renderSampleBuffer:sampleBuffer
                      rotation:rotation
               frameGeneration:frameGeneration
                   rtpTimestamp:frameRtpTimestamp
                    pendingAgeNs:0];
      CFRelease(sampleBuffer);
    });
#if TARGET_OS_OSX
  }
#endif
}

- (void)renderSampleBuffer:(CMSampleBufferRef)sampleBuffer
                  rotation:(RTCVideoRotation)rotation
           frameGeneration:(uint64_t)frameGeneration
              rtpTimestamp:(uint64_t)rtpTimestamp
              pendingAgeNs:(uint64_t)pendingAgeNs {
  [self updateVideoLayerTransformForRotation:rotation];

#if TARGET_OS_OSX
  InumaPresentationFrameContext frameContext = {0};
  frameContext.renderOrdinal = frameGeneration == 0 ? 0 : frameGeneration - 1;
  frameContext.nativeGeneration = frameGeneration;
  frameContext.rtpTimestamp = rtpTimestamp;
  frameContext.pendingAgeNs = pendingAgeNs;
  frameContext.timingPolicy = InumaPresentationTimingImmediateInvalid;
  const uint64_t enqueueStarted = _inumaTrace.enabled
                                      ? InumaNativeSurfaceMonotonicNanoseconds()
                                      : 0;
  if (_inumaTrace.enabled) {
    os_unfair_lock_lock(&_inumaTraceLock);
    _inumaTrace.enqueue_attempts += 1;
    os_unfair_lock_unlock(&_inumaTraceLock);
  }
#endif

#if TARGET_OS_IPHONE
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 170000
  if (@available(iOS 17.0, *)) {
    AVSampleBufferVideoRenderer* renderer = _videoLayer.sampleBufferRenderer;
    if ([renderer requiresFlushToResumeDecoding]) {
      [renderer flushWithRemovalOfDisplayedImage:YES completionHandler:nil];
    }
    [renderer enqueueSampleBuffer:sampleBuffer];
    return;
  }
#endif
  if (@available(iOS 14.0, *)) {
    if ([_videoLayer requiresFlushToResumeDecoding]) {
      [_videoLayer flushAndRemoveImage];
    }
  }
#elif TARGET_OS_OSX
#if defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && __MAC_OS_X_VERSION_MAX_ALLOWED >= 140000
  if (@available(macOS 14.0, *)) {
    if (_inumaNativeSurfaceSelected && _inumaRendererAdapter != nil) {
      InumaRendererSubmissionResult result =
          [_inumaRendererAdapter submitSampleBuffer:sampleBuffer context:frameContext];
      if (_inumaTrace.enabled) {
        os_unfair_lock_lock(&_inumaTraceLock);
        _inumaTrace.renderer_flushes += result.flushedBeforeEnqueue ? 1 : 0;
        _inumaTrace.renderer_not_ready_observations +=
            result.readyBeforeEnqueue ? 0 : 1;
        _inumaTrace.modern_renderer_enqueues += result.accepted ? 1 : 0;
        _inumaTrace.renderer_failures += result.failedAfterEnqueue ? 1 : 0;
        os_unfair_lock_unlock(&_inumaTraceLock);
        if (result.accepted) {
          [self inumaRecordEnqueueCompletionForGeneration:
                    frameContext.nativeGeneration
                                                 startedAt:enqueueStarted];
        }
      }
      return;
    }
    AVSampleBufferVideoRenderer* renderer = _videoLayer.sampleBufferRenderer;
    if ([renderer requiresFlushToResumeDecoding]) {
      [renderer flushWithRemovalOfDisplayedImage:YES completionHandler:nil];
      if (_inumaTrace.enabled) {
        os_unfair_lock_lock(&_inumaTraceLock);
        _inumaTrace.renderer_flushes += 1;
        os_unfair_lock_unlock(&_inumaTraceLock);
      }
    }
    if (_inumaTrace.enabled && !renderer.readyForMoreMediaData) {
      os_unfair_lock_lock(&_inumaTraceLock);
      _inumaTrace.renderer_not_ready_observations += 1;
      os_unfair_lock_unlock(&_inumaTraceLock);
    }
    [renderer enqueueSampleBuffer:sampleBuffer];
    if (_inumaTrace.enabled) {
      os_unfair_lock_lock(&_inumaTraceLock);
      _inumaTrace.modern_renderer_enqueues += 1;
      if (renderer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        _inumaTrace.renderer_failures += 1;
      }
      os_unfair_lock_unlock(&_inumaTraceLock);
      [self inumaRecordEnqueueCompletionForGeneration:frameContext.nativeGeneration
                                           startedAt:enqueueStarted];
    }
    return;
  }
#endif
  if (@available(macOS 11.0, *)) {
    if ([_videoLayer requiresFlushToResumeDecoding]) {
      [_videoLayer flushAndRemoveImage];
      if (_inumaTrace.enabled) {
        os_unfair_lock_lock(&_inumaTraceLock);
        _inumaTrace.renderer_flushes += 1;
        os_unfair_lock_unlock(&_inumaTraceLock);
      }
    }
  }
#endif
  [_videoLayer enqueueSampleBuffer:sampleBuffer];
#if TARGET_OS_OSX
  if (_inumaTrace.enabled) {
    os_unfair_lock_lock(&_inumaTraceLock);
    _inumaTrace.legacy_layer_enqueues += 1;
    if (_videoLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
      _inumaTrace.renderer_failures += 1;
    }
    os_unfair_lock_unlock(&_inumaTraceLock);
    [self inumaRecordEnqueueCompletionForGeneration:frameContext.nativeGeneration
                                         startedAt:enqueueStarted];
  }
#endif
}

#if TARGET_OS_OSX
- (void)inumaRenderNativeSampleBuffer:(CMSampleBufferRef)sampleBuffer
                             rotation:(RTCVideoRotation)rotation
                         frameContext:
                             (InumaPresentationFrameContext)frameContext {
  [self updateVideoLayerTransformForRotation:rotation];
  const uint64_t enqueueStarted = _inumaTrace.enabled
                                      ? InumaNativeSurfaceMonotonicNanoseconds()
                                      : 0;
  if (_inumaStrictReplayPaced &&
      frameContext.scheduledPresentationTimeNs > 0) {
    const uint64_t hostNow = InumaNativeSurfaceHostTimeNanoseconds();
    if (hostNow == 0 ||
        hostNow >= frameContext.scheduledPresentationTimeNs) {
      frameContext.presentationLatenessNs =
          hostNow > frameContext.scheduledPresentationTimeNs
              ? hostNow - frameContext.scheduledPresentationTimeNs
              : 0;
      const BOOL rearmTriggered =
          [_inumaStrictReplayPacer invalidateTimelineAfterAcceptedGeneration:
              frameContext.nativeGeneration];
      if (_inumaTrace.enabled) {
        os_unfair_lock_lock(&_inumaTraceLock);
        _inumaTrace.strict_replay_pacing_late_rejections += 1;
        _inumaTrace.strict_replay_dispatch_late_rejections += 1;
        _inumaTrace.strict_replay_pacing_rearm_count +=
            rearmTriggered ? 1 : 0;
        os_unfair_lock_unlock(&_inumaTraceLock);
        [_inumaPresentationTrace
            recordEventKind:InumaPresentationEventPacingLateRejected
                        atNs:enqueueStarted
                     context:frameContext
                   durationNs:frameContext.presentationLatenessNs
                         value:frameContext.presentationQueueDepth];
      }
      return;
    }
  }
  if (_inumaTrace.enabled) {
    os_unfair_lock_lock(&_inumaTraceLock);
    _inumaTrace.enqueue_attempts += 1;
    os_unfair_lock_unlock(&_inumaTraceLock);
  }
#if defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && __MAC_OS_X_VERSION_MAX_ALLOWED >= 140000
  if (@available(macOS 14.0, *)) {
    if (_inumaRendererAdapter != nil) {
      InumaRendererSubmissionResult result =
          [_inumaRendererAdapter submitSampleBuffer:sampleBuffer
                                            context:frameContext];
      if (_inumaTrace.enabled) {
        os_unfair_lock_lock(&_inumaTraceLock);
        _inumaTrace.renderer_flushes += result.flushedBeforeEnqueue ? 1 : 0;
        _inumaTrace.renderer_not_ready_observations +=
            result.readyBeforeEnqueue ? 0 : 1;
        _inumaTrace.modern_renderer_enqueues += result.accepted ? 1 : 0;
        _inumaTrace.renderer_failures += result.failedAfterEnqueue ? 1 : 0;
        os_unfair_lock_unlock(&_inumaTraceLock);
        if (result.accepted) {
          [self inumaRecordEnqueueCompletionForGeneration:
                    frameContext.nativeGeneration
                                                 startedAt:enqueueStarted];
        }
      }
      return;
    }
  }
#endif
  [_videoLayer enqueueSampleBuffer:sampleBuffer];
  if (_inumaTrace.enabled) {
    os_unfair_lock_lock(&_inumaTraceLock);
    _inumaTrace.legacy_layer_enqueues += 1;
    if (_videoLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
      _inumaTrace.renderer_failures += 1;
    }
    os_unfair_lock_unlock(&_inumaTraceLock);
    [self inumaRecordEnqueueCompletionForGeneration:frameContext.nativeGeneration
                                         startedAt:enqueueStarted];
  }
}

- (void)inumaSubmitStrictReplaySampleBuffer:(CMSampleBufferRef)sampleBuffer
                                   rotation:(RTCVideoRotation)rotation
                               frameContext:
                                   (InumaPresentationFrameContext)frameContext {
  BOOL rejected = NO;
  BOOL rearmAfterRejection = NO;
  os_unfair_lock_lock(&_inumaTraceLock);
  const NSUInteger capacity = _inumaStrictReplayPacer.queueCapacity;
  if (_inumaShuttingDown || capacity == 0 ||
      _inumaStrictReplayDispatchPending >= capacity) {
    _inumaTrace.strict_replay_dispatch_overflow_rejections += 1;
    rejected = YES;
    rearmAfterRejection = !_inumaShuttingDown && capacity > 0;
  } else {
    _inumaStrictReplayDispatchPending += 1;
    _inumaTrace.strict_replay_dispatch_submissions += 1;
    _inumaTrace.strict_replay_dispatch_depth_high_water =
        MAX(_inumaTrace.strict_replay_dispatch_depth_high_water,
            _inumaStrictReplayDispatchPending);
  }
  os_unfair_lock_unlock(&_inumaTraceLock);
  if (rejected) {
    const BOOL rearmTriggered =
        rearmAfterRejection &&
        [_inumaStrictReplayPacer invalidateTimelineAfterAcceptedGeneration:
            frameContext.nativeGeneration];
    if (_inumaTrace.enabled) {
      if (rearmTriggered) {
        os_unfair_lock_lock(&_inumaTraceLock);
        _inumaTrace.strict_replay_pacing_rearm_count += 1;
        os_unfair_lock_unlock(&_inumaTraceLock);
      }
      [_inumaPresentationTrace
          recordEventKind:InumaPresentationEventPacingOverflowRejected
                      atNs:InumaNativeSurfaceMonotonicNanoseconds()
                   context:frameContext
                 durationNs:0
                       value:capacity];
    }
    CFRelease(sampleBuffer);
    return;
  }
  dispatch_async(_sampleBufferQueue, ^{
    [self inumaRenderNativeSampleBuffer:sampleBuffer
                               rotation:rotation
                           frameContext:frameContext];
    os_unfair_lock_lock(&self->_inumaTraceLock);
    self->_inumaStrictReplayDispatchPending -= 1;
    os_unfair_lock_unlock(&self->_inumaTraceLock);
    CFRelease(sampleBuffer);
  });
}

- (void)inumaSubmitLatestSampleBuffer:(CMSampleBufferRef)sampleBuffer
                            rotation:(RTCVideoRotation)rotation
                        frameContext:(InumaPresentationFrameContext)frameContext {
  const uint64_t submittedAt = _inumaTrace.enabled
                                   ? InumaNativeSurfaceMonotonicNanoseconds()
                                   : 0;
  CMSampleBufferRef replacedSampleBuffer = nil;
  InumaPresentationFrameContext replacedContext = {0};
  uint64_t replacedSetAtNs = 0;
  BOOL rejectedAfterShutdown = NO;
  BOOL scheduleDrain = NO;
  os_unfair_lock_lock(&_inumaTraceLock);
  _inumaTrace.latest_sample_submissions += 1;
  if (_inumaShuttingDown) {
    _inumaTrace.latest_sample_rejections_after_shutdown += 1;
    rejectedAfterShutdown = YES;
  } else {
    replacedSampleBuffer = _inumaPendingSampleBuffer;
    if (replacedSampleBuffer != nil) {
      _inumaTrace.latest_sample_replacements += 1;
      replacedContext = _inumaPendingContext;
      replacedSetAtNs = _inumaPendingSetAtNs;
    }
    _inumaPendingSampleBuffer = sampleBuffer;
    _inumaPendingRotation = rotation;
    _inumaPendingContext = frameContext;
    _inumaPendingSetAtNs = submittedAt;
    _inumaTrace.queue_depth_high_water = 1;
    if (!_inumaDrainScheduled) {
      _inumaDrainScheduled = YES;
      _inumaTrace.drain_callbacks_scheduled += 1;
      scheduleDrain = YES;
    }
  }
  os_unfair_lock_unlock(&_inumaTraceLock);

  if (_inumaTrace.enabled) {
    if (rejectedAfterShutdown) {
      [_inumaPresentationTrace
          recordEventKind:InumaPresentationEventPendingRejectedAfterShutdown
                      atNs:submittedAt
                   context:frameContext
                 durationNs:0
                       value:0];
      [_inumaPresentationTrace
          recordEventKind:InumaPresentationEventCallbackAfterStopRejected
                      atNs:submittedAt
                   context:frameContext
                 durationNs:0
                       value:0];
    } else {
      if (replacedSampleBuffer != nil) {
        replacedContext.pendingAgeNs = submittedAt - replacedSetAtNs;
        [_inumaPresentationTrace
            recordEventKind:InumaPresentationEventPendingReplaced
                        atNs:submittedAt
                     context:replacedContext
                   durationNs:replacedContext.pendingAgeNs
                         value:frameContext.nativeGeneration];
      }
      [_inumaPresentationTrace recordEventKind:InumaPresentationEventPendingSet
                                          atNs:submittedAt
                                       context:frameContext
                                     durationNs:0
                                           value:0];
      [_inumaPresentationTrace
          recordEventKind:InumaPresentationEventPendingDeferred
                      atNs:submittedAt
                   context:frameContext
                 durationNs:0
                       value:scheduleDrain ? 1 : 0];
    }
  }
  if (replacedSampleBuffer != nil) {
    CFRelease(replacedSampleBuffer);
  }
  if (rejectedAfterShutdown) {
    CFRelease(sampleBuffer);
    return;
  }
  if (!scheduleDrain) {
    return;
  }

  dispatch_async(_sampleBufferQueue, ^{
    while (true) {
      CMSampleBufferRef pendingSampleBuffer = nil;
      RTCVideoRotation pendingRotation = RTCVideoRotation_0;
      InumaPresentationFrameContext pendingContext = {0};
      uint64_t pendingSetAtNs = 0;
      os_unfair_lock_lock(&self->_inumaTraceLock);
      pendingSampleBuffer = self->_inumaPendingSampleBuffer;
      if (pendingSampleBuffer == nil) {
        self->_inumaDrainScheduled = NO;
        os_unfair_lock_unlock(&self->_inumaTraceLock);
        return;
      }
      pendingRotation = self->_inumaPendingRotation;
      pendingContext = self->_inumaPendingContext;
      pendingSetAtNs = self->_inumaPendingSetAtNs;
      self->_inumaPendingSampleBuffer = nil;
      self->_inumaPendingContext = (InumaPresentationFrameContext){0};
      self->_inumaPendingSetAtNs = 0;
      self->_inumaTrace.drain_dequeues += 1;
      os_unfair_lock_unlock(&self->_inumaTraceLock);

      const uint64_t dequeuedAt = self->_inumaTrace.enabled
                                      ? InumaNativeSurfaceMonotonicNanoseconds()
                                      : 0;
      pendingContext.pendingAgeNs = self->_inumaTrace.enabled
                                        ? dequeuedAt - pendingSetAtNs
                                        : 0;
      if (self->_inumaTrace.enabled) {
        [self->_inumaPresentationTrace
            recordEventKind:InumaPresentationEventPendingResumed
                        atNs:dequeuedAt
                     context:pendingContext
                   durationNs:pendingContext.pendingAgeNs
                         value:0];
      }
      [self inumaRenderNativeSampleBuffer:pendingSampleBuffer
                                rotation:pendingRotation
                            frameContext:pendingContext];
      CFRelease(pendingSampleBuffer);
    }
  });
}

- (void)inumaRecordEnqueueCompletionForGeneration:(uint64_t)frameGeneration
                                         startedAt:(uint64_t)startedAt {
  const uint64_t completedAt = InumaNativeSurfaceMonotonicNanoseconds();
  os_unfair_lock_lock(&_inumaTraceLock);
  _inumaTrace.enqueue_completions += 1;
  if (_inumaTrace.enqueue_event_count < kInumaNativeVideoSurfaceTraceCapacity) {
    const NSUInteger index = _inumaTrace.enqueue_event_count++;
    _inumaTrace.enqueue_event_offset_ns[index] =
        completedAt - _inumaTraceStartedMonotonicNs;
    _inumaTrace.enqueue_frame_generation[index] = frameGeneration;
    _inumaTrace.enqueue_call_duration_ns[index] = completedAt - startedAt;
  } else {
    _inumaTrace.capacity_exhaustions += 1;
  }
  os_unfair_lock_unlock(&_inumaTraceLock);
}

- (void)inumaStartPresentationDisplayLink {
  if (!_inumaStrictReplayPaced || _inumaStrictReplayPacer == nil ||
      _inumaPresentationDisplayLink != nil) {
    return;
  }
  if (@available(macOS 14.0, *)) {
    NSScreen* screen = self.window.screen ?: NSScreen.mainScreen ?:
        NSScreen.screens.firstObject;
    if (screen == nil) return;
    __weak FlutterRTCVideoPlatformView* weakSelf = self;
    InumaPresentationDisplayLinkTarget* target =
        [[InumaPresentationDisplayLinkTarget alloc]
            initWithHandler:^(id displayLink) {
              [weakSelf inumaPresentationDisplayLinkDidFire:
                            (CADisplayLink*)displayLink];
            }];
    CADisplayLink* displayLink =
        [screen displayLinkWithTarget:target
                            selector:@selector(displayLinkDidFire:)];
    if (displayLink == nil) return;
    _inumaPresentationDisplayLinkTarget = target;
    _inumaPresentationDisplayLink = displayLink;
    [displayLink addToRunLoop:NSRunLoop.mainRunLoop
                      forMode:NSRunLoopCommonModes];
  }
}

- (void)inumaStopPresentationDisplayLink {
  id displayLink = _inumaPresentationDisplayLink;
  _inumaPresentationDisplayLink = nil;
  _inumaPresentationDisplayLinkTarget = nil;
  [displayLink invalidate];
}

- (void)inumaPresentationDisplayLinkDidFire:(CADisplayLink*)displayLink
    API_AVAILABLE(macos(14.0)) {
  const uint64_t timestampNs =
      InumaFiniteSecondsToNanoseconds(displayLink.timestamp);
  const uint64_t targetTimeNs =
      InumaFiniteSecondsToNanoseconds(displayLink.targetTimestamp);
  const uint64_t refreshPeriodNs =
      InumaFiniteSecondsToNanoseconds(displayLink.duration);
  const BOOL accepted =
      [_inumaStrictReplayPacer updateDisplayPhaseTimestampNs:timestampNs
                                                targetTimeNs:targetTimeNs
                                             refreshPeriodNs:refreshPeriodNs];
  if (_inumaTrace.enabled) {
    os_unfair_lock_lock(&_inumaTraceLock);
    _inumaTrace.strict_replay_display_link_callbacks += 1;
    _inumaTrace.strict_replay_display_phase_updates += accepted ? 1 : 0;
    _inumaTrace.strict_replay_display_phase_rejections += accepted ? 0 : 1;
    if (accepted) {
      _inumaTrace.strict_replay_last_display_timestamp_ns = timestampNs;
      _inumaTrace.strict_replay_last_display_target_time_ns = targetTimeNs;
      _inumaTrace.strict_replay_last_display_refresh_period_ns =
          refreshPeriodNs;
    }
    os_unfair_lock_unlock(&_inumaTraceLock);
  }
}

- (void)inumaRequestRendererPerformanceMetrics {
  if (!_inumaTrace.enabled || !_inumaNativeSurfaceSelected ||
      !_inumaStrictReplayPaced) {
    return;
  }
  if (@available(macOS 14.4, *)) {
    os_unfair_lock_lock(&_inumaTraceLock);
    if (_inumaShuttingDown || _inumaRendererPerformanceMetricRequestPending) {
      os_unfair_lock_unlock(&_inumaTraceLock);
      return;
    }
    _inumaRendererPerformanceMetricRequestPending = YES;
    _inumaTrace.renderer_performance_metric_request_count += 1;
    os_unfair_lock_unlock(&_inumaTraceLock);

    __weak FlutterRTCVideoPlatformView* weakSelf = self;
    [_videoLayer.sampleBufferRenderer
        loadVideoPerformanceMetricsWithCompletionHandler:
            ^(AVVideoPerformanceMetrics* metrics) {
              FlutterRTCVideoPlatformView* strongSelf = weakSelf;
              if (strongSelf == nil) return;
              const NSInteger totalFrames = metrics.totalNumberOfFrames;
              const NSInteger droppedFrames = metrics.numberOfDroppedFrames;
              const NSInteger corruptedFrames = metrics.numberOfCorruptedFrames;
              const NSInteger optimizedFrames =
                  metrics.numberOfFramesDisplayedUsingOptimizedCompositing;
              const NSTimeInterval accumulatedDelay =
                  metrics.totalAccumulatedFrameDelay;
              const uint64_t accumulatedDelayNs =
                  metrics == nil
                      ? 0
                      : InumaFiniteSecondsToNanoseconds(accumulatedDelay);
              const BOOL metricsValid =
                  metrics != nil && totalFrames >= 0 && droppedFrames >= 0 &&
                  corruptedFrames >= 0 && optimizedFrames >= 0 &&
                  droppedFrames <= totalFrames &&
                  corruptedFrames <= totalFrames &&
                  optimizedFrames <= totalFrames &&
                  isfinite(accumulatedDelay) && accumulatedDelay >= 0.0 &&
                  (accumulatedDelay == 0.0 || accumulatedDelayNs > 0);
              os_unfair_lock_lock(&strongSelf->_inumaTraceLock);
              strongSelf->_inumaRendererPerformanceMetricRequestPending = NO;
              strongSelf->_inumaTrace.renderer_performance_metric_callback_count +=
                  1;
              if (metrics == nil) {
                strongSelf->_inumaTrace.renderer_performance_metric_nil_count +=
                    1;
              } else if (!metricsValid) {
                strongSelf->_inumaTrace
                    .renderer_performance_metric_invalid_count += 1;
              } else {
                strongSelf->_inumaTrace
                    .renderer_performance_metric_snapshot_count += 1;
                strongSelf->_inumaTrace.renderer_performance_metric_total_frames =
                    (uint64_t)totalFrames;
                strongSelf->_inumaTrace
                    .renderer_performance_metric_dropped_frames =
                    (uint64_t)droppedFrames;
                strongSelf->_inumaTrace
                    .renderer_performance_metric_corrupted_frames =
                    (uint64_t)corruptedFrames;
                strongSelf->_inumaTrace
                    .renderer_performance_metric_optimized_compositing_frames =
                    (uint64_t)optimizedFrames;
                strongSelf->_inumaTrace
                    .renderer_performance_metric_total_accumulated_delay_ns =
                    accumulatedDelayNs;
                strongSelf->_inumaTrace
                    .renderer_performance_metric_last_snapshot_monotonic_ns =
                    InumaNativeSurfaceMonotonicNanoseconds();
              }
              os_unfair_lock_unlock(&strongSelf->_inumaTraceLock);
            }];
  }
}

- (void)inumaRegisterDisplayedContext:(InumaPresentationFrameContext)context {
  const BOOL registered =
      [_inumaDisplayedIdentityLedger registerContext:context];
  os_unfair_lock_lock(&_inumaTraceLock);
  _inumaTrace.display_identity_context_registrations += registered ? 1 : 0;
  _inumaTrace.display_identity_context_registration_failures +=
      registered ? 0 : 1;
  os_unfair_lock_unlock(&_inumaTraceLock);
}

- (void)inumaStartNativePresentationObserver {
  if (_inumaPresentationObserverTimer != nil) return;
  dispatch_queue_attr_t observerAttributes =
      dispatch_queue_attr_make_with_qos_class(
          DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
  _inumaPresentationObserverQueue = dispatch_queue_create(
      "com.cloudwebrtc.flutterwebrtc.video-platform-view.presentation-observer",
      observerAttributes);
  _inumaPresentationObserverTimer = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _inumaPresentationObserverQueue);
  dispatch_source_set_timer(_inumaPresentationObserverTimer,
                            dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_MSEC,
                            100 * NSEC_PER_USEC);
  __weak FlutterRTCVideoPlatformView* weakSelf = self;
  dispatch_source_set_event_handler(_inumaPresentationObserverTimer, ^{
    if (@available(macOS 14.4, *)) {
      [weakSelf inumaObserveNativePresentedPixelBuffer];
    }
  });
  dispatch_resume(_inumaPresentationObserverTimer);
}

- (void)inumaObserveNativePresentedPixelBuffer API_AVAILABLE(macos(14.4)) {
  CVPixelBufferRef displayed =
      [_videoLayer.sampleBufferRenderer copyDisplayedPixelBuffer];
  if (displayed == nil) return;
  InumaPresentationFrameContext context = {0};
  const uint64_t lookupStartedAt = InumaNativeSurfaceMonotonicNanoseconds();
  const InumaDisplayedFrameIdentityLookupResult lookup =
      [_inumaDisplayedIdentityLedger
          lookupContextForDisplayedPixelBuffer:displayed
                                        context:&context];
  const uint64_t lookupDurationNs =
      InumaNativeSurfaceMonotonicNanoseconds() - lookupStartedAt;
  const BOOL lookupFound = lookup == InumaDisplayedFrameIdentityLookupFound;
  BOOL newObservation = NO;
  os_unfair_lock_lock(&_inumaTraceLock);
  _inumaTrace.display_identity_watermark_reads += 1;
  _inumaTrace.display_identity_watermark_decode_successes +=
      lookup == InumaDisplayedFrameIdentityLookupFound ||
              lookup == InumaDisplayedFrameIdentityLookupContextMissing
          ? 1
          : 0;
  _inumaTrace.display_identity_watermark_decode_total_duration_ns +=
      lookupDurationNs;
  _inumaTrace.display_identity_watermark_decode_maximum_duration_ns =
      MAX(_inumaTrace.display_identity_watermark_decode_maximum_duration_ns,
          lookupDurationNs);
  _inumaTrace.display_identity_watermark_decode_durations_over_250us +=
      lookupDurationNs > 250000 ? 1 : 0;
  _inumaTrace.display_identity_watermark_decode_durations_over_1ms +=
      lookupDurationNs > 1000000 ? 1 : 0;
  _inumaTrace.display_identity_unsupported_pixel_format_failures +=
      lookup == InumaDisplayedFrameIdentityLookupUnsupportedPixelFormat ? 1 : 0;
  _inumaTrace.display_identity_pixel_buffer_lock_failures +=
      lookup == InumaDisplayedFrameIdentityLookupPixelBufferLockFailed ? 1 : 0;
  _inumaTrace.display_identity_geometry_failures +=
      lookup == InumaDisplayedFrameIdentityLookupGeometryInvalid ? 1 : 0;
  _inumaTrace.display_identity_contrast_failures +=
      lookup == InumaDisplayedFrameIdentityLookupInsufficientContrast ? 1 : 0;
  _inumaTrace.display_identity_sync_failures +=
      lookup == InumaDisplayedFrameIdentityLookupSyncMismatch ? 1 : 0;
  _inumaTrace.display_identity_checksum_failures +=
      lookup == InumaDisplayedFrameIdentityLookupChecksumMismatch ? 1 : 0;
  _inumaTrace.display_identity_context_misses +=
      lookup == InumaDisplayedFrameIdentityLookupContextMissing ? 1 : 0;
  _inumaTrace.display_identity_invalid_lookups +=
      lookup == InumaDisplayedFrameIdentityLookupInvalid ? 1 : 0;
  if (lookupFound) {
    newObservation = !_inumaHasObservedPresentationState ||
                     !_inumaLastObservationResolved ||
                     !_inumaHasLastObservedNativeGeneration ||
                     context.nativeGeneration !=
                         _inumaLastObservedNativeGeneration;
    _inumaHasObservedPresentationState = YES;
    _inumaLastObservationResolved = YES;
    _inumaHasLastObservedNativeGeneration = YES;
    _inumaLastObservedNativeGeneration = context.nativeGeneration;
  } else {
    newObservation = !_inumaHasObservedPresentationState ||
                     _inumaLastObservationResolved;
    _inumaHasObservedPresentationState = YES;
    _inumaLastObservationResolved = NO;
  }
  os_unfair_lock_unlock(&_inumaTraceLock);
  if (newObservation) {
    [_inumaPresentationTrace
        recordEventKind:(lookupFound
                             ? InumaPresentationEventDisplayedObserved
                             : InumaPresentationEventDisplayedLookupMiss)
                    atNs:InumaNativeSurfaceMonotonicNanoseconds()
                 context:context
               durationNs:0
                     value:0];
  }
  CFRelease(displayed);
}

- (void)inumaStopNativePresentationObserver {
  if (_inumaPresentationObserverTimer == nil) return;
  dispatch_source_cancel(_inumaPresentationObserverTimer);
  dispatch_sync(_inumaPresentationObserverQueue, ^{});
  _inumaPresentationObserverTimer = nil;
}

- (void)inumaWriteNativeVideoSurfaceTrace {
  if (_inumaTraceWriterQueue == nil) return;
  dispatch_async(_inumaTraceWriterQueue, ^{
    [self inumaWriteNativeVideoSurfaceTraceOnWriterQueueWithRetryAttempt:0
                                                                terminal:NO];
  });
}

- (void)inumaWriteNativeVideoSurfaceTraceOnWriterQueueWithRetryAttempt:
    (NSUInteger)retryAttempt
                                                         terminal:(BOOL)terminal {
  if (!_inumaTrace.enabled || _inumaTracePath.length == 0) {
    return;
  }
  const InumaStrictReplayPacerSnapshot pacerSnapshot =
      _inumaStrictReplayPacer == nil
          ? (InumaStrictReplayPacerSnapshot){0}
          : [_inumaStrictReplayPacer snapshot];
  InumaNativeVideoSurfaceTrace* snapshot =
      malloc(sizeof(InumaNativeVideoSurfaceTrace));
  if (snapshot == NULL) {
    return;
  }
  const uint64_t snapshotAt = InumaNativeSurfaceMonotonicNanoseconds();
  const uint64_t snapshotWallTimeNs =
      (uint64_t)(NSDate.date.timeIntervalSince1970 * 1000000000.0);
  os_unfair_lock_lock(&_inumaTraceLock);
  memcpy(snapshot, &_inumaTrace, sizeof(InumaNativeVideoSurfaceTrace));
  if (_inumaSegmentedEvidenceEnabled) {
    _inumaTrace.render_event_count = 0;
    _inumaTrace.enqueue_event_count = 0;
  }
  const BOOL pendingSamplePresent = _inumaPendingSampleBuffer != nil;
  const BOOL drainScheduled = _inumaDrainScheduled;
  const NSUInteger strictReplayDispatchPending =
      _inumaStrictReplayDispatchPending;
  const BOOL shuttingDown = _inumaShuttingDown;
  const BOOL rendererPerformanceMetricRequestPending =
      _inumaRendererPerformanceMetricRequestPending;
  _inumaTraceSnapshotCount += 1;
  const uint64_t snapshotCount = _inumaTraceSnapshotCount;
  os_unfair_lock_unlock(&_inumaTraceLock);

  const uint64_t pacingDecisionTerminalCount =
      pacerSnapshot.acceptedCount + pacerSnapshot.prearmDiscardCount +
      pacerSnapshot.lateCount + pacerSnapshot.overflowCount +
      pacerSnapshot.generationSequenceFailureCount +
      pacerSnapshot.addedLatencyViolationCount;
  const uint64_t pixelBufferSuccessCount =
      snapshot->direct_pixel_buffer_frames +
      snapshot->converted_pixel_buffer_frames;
  const BOOL strictReplaySnapshotCoherent =
      !_inumaStrictReplayPaced ||
      (pacerSnapshot.acceptedCount ==
           snapshot->strict_replay_pacing_accepted &&
       pacerSnapshot.prearmDiscardCount ==
           snapshot->strict_replay_pacing_prearm_discards &&
       pacerSnapshot.rearmCount ==
           snapshot->strict_replay_pacing_rearm_count &&
       pacerSnapshot.rearmPrearmDiscardCount ==
           snapshot->strict_replay_pacing_rearm_prearm_discards &&
       pacerSnapshot.armCount ==
           snapshot->strict_replay_pacing_arm_count &&
       pacerSnapshot.latePhaseCorrectionCount ==
           snapshot->strict_replay_pacing_late_phase_corrections &&
       pacerSnapshot.earlyPhaseCorrectionCount ==
           snapshot->strict_replay_pacing_early_phase_corrections &&
       pacerSnapshot.lateCount ==
           snapshot->strict_replay_pacing_pacer_late_rejections &&
       pacerSnapshot.overflowCount ==
           snapshot->strict_replay_pacing_overflow_rejections &&
       pacerSnapshot.generationSequenceFailureCount ==
           snapshot->strict_replay_pacing_sequence_rejections &&
       pacerSnapshot.addedLatencyViolationCount ==
           snapshot->strict_replay_pacing_added_latency_rejections &&
       pacerSnapshot.displayPhaseUpdateCount ==
           snapshot->strict_replay_display_phase_updates &&
       pacerSnapshot.displayPhaseTimestampNs ==
           snapshot->strict_replay_last_display_timestamp_ns &&
       pacerSnapshot.displayPhaseTargetTimeNs ==
           snapshot->strict_replay_last_display_target_time_ns &&
       pacerSnapshot.displayRefreshPeriodNs ==
           snapshot->strict_replay_last_display_refresh_period_ns &&
       snapshot->strict_replay_display_link_callbacks ==
           snapshot->strict_replay_display_phase_updates +
               snapshot->strict_replay_display_phase_rejections &&
       pacerSnapshot.displayPhaseAlignmentCount == pacerSnapshot.armCount &&
       pacerSnapshot.displayPhaseFallbackCount == 0 &&
       snapshot->strict_replay_pacing_late_rejections ==
           snapshot->strict_replay_pacing_pacer_late_rejections +
               snapshot->strict_replay_dispatch_late_rejections &&
       pacingDecisionTerminalCount == pixelBufferSuccessCount &&
       pixelBufferSuccessCount + snapshot->pixel_buffer_failures ==
           snapshot->render_frames &&
       pacerSnapshot.acceptedCount ==
           snapshot->sample_buffer_failures +
               snapshot->strict_replay_dispatch_submissions +
               snapshot->strict_replay_dispatch_overflow_rejections &&
       strictReplayDispatchPending == 0 &&
       snapshot->strict_replay_dispatch_submissions ==
           snapshot->enqueue_attempts +
               snapshot->strict_replay_dispatch_late_rejections &&
       snapshot->enqueue_completions <= snapshot->enqueue_attempts);
  if (!strictReplaySnapshotCoherent && !shuttingDown &&
      !_inumaSegmentedEvidenceEnabled &&
      retryAttempt < kInumaTraceMaximumCoherentSnapshotRetries) {
    free(snapshot);
    _inumaCoherentSnapshotRetryCount += 1;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, kInumaTraceCoherentSnapshotRetryNs),
        _inumaTraceWriterQueue, ^{
          [self inumaWriteNativeVideoSurfaceTraceOnWriterQueueWithRetryAttempt:
                    retryAttempt + 1
                                                                terminal:NO];
        });
    return;
  }

  const uint64_t prerendererSmoothingDisabledConfigurationCount =
      InumaPrerendererSmoothingDisabledConfigurationCount();
  const uint64_t lowLatencyVideoPlayoutEnabledConfigurationCount =
      InumaLowLatencyVideoPlayoutEnabledConfigurationCount();
  os_unfair_lock_lock(&gInumaNativeVideoSurfaceLifecycleLock);
  const uint64_t surfaceCreatedCount =
      gInumaNativeVideoSurfaceCreatedCount;
  const uint64_t surfaceLiveCount = gInumaNativeVideoSurfaceLiveCount;
  const uint64_t surfaceMaximumLiveCount =
      gInumaNativeVideoSurfaceMaximumLiveCount;
  os_unfair_lock_unlock(&gInumaNativeVideoSurfaceLifecycleLock);
  NSDictionary<NSString*, id>* presentationTrace =
      _inumaPresentationTrace == nil
          ? @{
              @"schema" :
                  @"inuma.flutter_webrtc.macos_native_presentation_trace.v2",
              @"status" : @"fail",
              @"finding" : @"presentation_trace_not_initialized",
            }
          : (_inumaSegmentedEvidenceEnabled
                 ? [_inumaPresentationTrace drainSnapshotAtNs:snapshotAt]
                 : [_inumaPresentationTrace snapshotAtNs:snapshotAt]);
  BOOL layerReadyForDisplay = NO;
  if (@available(macOS 14.4, *)) {
    layerReadyForDisplay = _videoLayer.readyForDisplay;
  }
  NSDictionary* report = @{
    @"schema" : @"inuma.flutter_webrtc.macos_native_video_surface_trace.v10",
    @"status" : strictReplaySnapshotCoherent ? @"pass" : @"fail",
    @"surface_mode" : @"native_platform_view",
    @"surface_contract" :
        (_inumaStrictReplayPaced
             ? @"one_appkit_view_one_avsamplebufferdisplaylayer_strict_replay_paced_valid_host_pts"
             : @"one_appkit_view_one_avsamplebufferdisplaylayer_immediate_display"),
    @"presentation_policy" :
        (_inumaStrictReplayPaced ? @"strict_replay_paced"
                                 : @"legacy_immediate_unpaced"),
    @"presentation_timing_policy" :
        (_inumaStrictReplayPaced ? @"valid_host_pts"
                                 : @"immediate_invalid"),
    @"presentation_clock_contract" :
        (_inumaStrictReplayPaced
             ? @"display_layer_nil_control_timebase_uses_mach_host_clock"
             : @"display_immediately_ignores_pts"),
    @"strict_replay_configured_reserve_ns" :
        @(_inumaStrictReplayReserveNs),
    @"strict_replay_frame_interval_ns" :
        @(_inumaStrictReplayPaced ? kInumaStrictReplayFrameIntervalNs : 0),
    @"strict_replay_queue_capacity" :
        @(_inumaStrictReplayPacer.queueCapacity),
    @"strict_replay_pacer_accepted_count" :
        @(pacerSnapshot.acceptedCount),
    @"strict_replay_pacer_prearm_discard_count" :
        @(pacerSnapshot.prearmDiscardCount),
    @"strict_replay_pacer_late_phase_correction_count" :
        @(pacerSnapshot.latePhaseCorrectionCount),
    @"strict_replay_pacer_early_phase_correction_count" :
        @(pacerSnapshot.earlyPhaseCorrectionCount),
    @"strict_replay_pacer_armed_generation" :
        @(pacerSnapshot.armedGeneration),
    @"strict_replay_pacer_last_armed_generation" :
        @(pacerSnapshot.lastArmedGeneration),
    @"strict_replay_pacer_arm_count" : @(pacerSnapshot.armCount),
    @"strict_replay_pacer_rearm_count" : @(pacerSnapshot.rearmCount),
    @"strict_replay_pacer_rearm_prearm_discard_count" :
        @(pacerSnapshot.rearmPrearmDiscardCount),
    @"strict_replay_pacer_late_count" : @(pacerSnapshot.lateCount),
    @"strict_replay_pacer_overflow_count" :
        @(pacerSnapshot.overflowCount),
    @"strict_replay_pacer_generation_sequence_failure_count" :
        @(pacerSnapshot.generationSequenceFailureCount),
    @"strict_replay_maximum_added_latency_ns" :
        @(_inumaStrictReplayPacer.maximumAddedLatencyNs),
    @"strict_replay_minimum_presentation_interval_ns" :
        @(_inumaStrictReplayPacer.minimumPresentationIntervalNs),
    @"strict_replay_maximum_presentation_interval_ns" :
        @(_inumaStrictReplayPacer.maximumPresentationIntervalNs),
    @"strict_replay_minimum_presentation_lead_ns" :
        @(_inumaStrictReplayPacer.minimumPresentationLeadNs),
    @"strict_replay_stable_cadence_interval_minimum_ns" :
        @(_inumaStrictReplayPacer.stableCadenceIntervalMinimumNs),
    @"strict_replay_stable_cadence_interval_maximum_ns" :
        @(_inumaStrictReplayPacer.stableCadenceIntervalMaximumNs),
    @"strict_replay_required_stable_cadence_intervals" :
        @(_inumaStrictReplayPacer.requiredStableCadenceIntervals),
    @"strict_replay_pacer_added_latency_violation_count" :
        @(pacerSnapshot.addedLatencyViolationCount),
    @"strict_replay_display_phase_policy" :
        (_inumaStrictReplayPaced ? @"display_link_half_refresh_lead"
                                 : @"disabled"),
    @"strict_replay_display_link_callbacks" :
        @(snapshot->strict_replay_display_link_callbacks),
    @"strict_replay_display_phase_update_count" :
        @(pacerSnapshot.displayPhaseUpdateCount),
    @"strict_replay_display_phase_rejection_count" :
        @(snapshot->strict_replay_display_phase_rejections),
    @"strict_replay_display_phase_alignment_count" :
        @(pacerSnapshot.displayPhaseAlignmentCount),
    @"strict_replay_display_phase_fallback_count" :
        @(pacerSnapshot.displayPhaseFallbackCount),
    @"strict_replay_last_display_timestamp_ns" :
        @(snapshot->strict_replay_last_display_timestamp_ns),
    @"strict_replay_last_display_target_time_ns" :
        @(snapshot->strict_replay_last_display_target_time_ns),
    @"strict_replay_last_display_refresh_period_ns" :
        @(snapshot->strict_replay_last_display_refresh_period_ns),
    @"strict_replay_last_aligned_display_timestamp_ns" :
        @(pacerSnapshot.lastAlignedDisplayPhaseTimestampNs),
    @"strict_replay_last_aligned_display_target_time_ns" :
        @(pacerSnapshot.lastAlignedDisplayPhaseTargetTimeNs),
    @"strict_replay_last_aligned_display_refresh_period_ns" :
        @(pacerSnapshot.lastAlignedDisplayRefreshPeriodNs),
    @"strict_replay_last_aligned_display_safety_lead_ns" :
        @(pacerSnapshot.lastAlignedDisplaySafetyLeadNs),
    @"renderer_performance_metric_source" :
        @"avsamplebuffervideorenderer_video_performance_metrics",
    @"renderer_performance_metric_request_count" :
        @(snapshot->renderer_performance_metric_request_count),
    @"renderer_performance_metric_callback_count" :
        @(snapshot->renderer_performance_metric_callback_count),
    @"renderer_performance_metric_snapshot_count" :
        @(snapshot->renderer_performance_metric_snapshot_count),
    @"renderer_performance_metric_nil_count" :
        @(snapshot->renderer_performance_metric_nil_count),
    @"renderer_performance_metric_invalid_count" :
        @(snapshot->renderer_performance_metric_invalid_count),
    @"renderer_performance_metric_total_frames" :
        @(snapshot->renderer_performance_metric_total_frames),
    @"renderer_performance_metric_dropped_frames" :
        @(snapshot->renderer_performance_metric_dropped_frames),
    @"renderer_performance_metric_corrupted_frames" :
        @(snapshot->renderer_performance_metric_corrupted_frames),
    @"renderer_performance_metric_optimized_compositing_frames" :
        @(snapshot->renderer_performance_metric_optimized_compositing_frames),
    @"renderer_performance_metric_total_accumulated_delay_ns" :
        @(snapshot->renderer_performance_metric_total_accumulated_delay_ns),
    @"renderer_performance_metric_last_snapshot_monotonic_ns" :
        @(snapshot->renderer_performance_metric_last_snapshot_monotonic_ns),
    @"renderer_performance_metric_request_pending" :
        @(rendererPerformanceMetricRequestPending),
    @"strict_replay_pacer_queue_depth_high_water" :
        @(pacerSnapshot.queueDepthHighWater),
    @"payload_policy" : @"scalar_timing_and_counts_only_no_pixel_payloads",
    @"trace_clock_domain" :
        @"macos_clock_monotonic_raw_shared_mach_host_time",
    @"frame_identity_contract" :
        @"crc16_product_watermark_frame_identity_joined_to_renderer_local_context",
    @"display_identity_binding_contract" :
        @"crc16_product_watermark_decoded_from_each_accepted_input_pixel_buffer_then_resolved_from_renderer_displayed_pixel_buffer_with_source_identity_keyed_context_no_ordinal_assumption_no_pointer_identity_no_pixel_retention",
    @"display_identity_context_binding_version" : @2,
    @"sample_capacity" : @(kInumaNativeVideoSurfaceTraceCapacity),
    @"sample_capacity_exhaustions" : @(snapshot->capacity_exhaustions),
    @"trace_started_monotonic_ns" : @(_inumaTraceStartedMonotonicNs),
    @"trace_snapshot_monotonic_ns" : @(snapshotAt),
    @"trace_snapshot_wall_time_ns" : @(snapshotWallTimeNs),
    @"trace_snapshot_count" : @(snapshotCount),
    @"coherent_snapshot_retry_count" : @(_inumaCoherentSnapshotRetryCount),
    @"render_frames" : @(snapshot->render_frames),
    @"direct_pixel_buffer_frames" : @(snapshot->direct_pixel_buffer_frames),
    @"converted_pixel_buffer_frames" : @(snapshot->converted_pixel_buffer_frames),
    @"pixel_buffer_failures" : @(snapshot->pixel_buffer_failures),
    @"sample_buffer_failures" : @(snapshot->sample_buffer_failures),
    @"enqueue_attempts" : @(snapshot->enqueue_attempts),
    @"enqueue_completions" : @(snapshot->enqueue_completions),
    @"renderer_not_ready_observations" :
        @(snapshot->renderer_not_ready_observations),
    @"renderer_flushes" : @(snapshot->renderer_flushes),
    @"renderer_failures" : @(snapshot->renderer_failures),
    @"modern_renderer_enqueues" : @(snapshot->modern_renderer_enqueues),
    @"legacy_layer_enqueues" : @(snapshot->legacy_layer_enqueues),
    @"latest_sample_submissions" : @(snapshot->latest_sample_submissions),
    @"latest_sample_replacements" : @(snapshot->latest_sample_replacements),
    @"latest_sample_rejections_after_shutdown" :
        @(snapshot->latest_sample_rejections_after_shutdown),
    @"latest_sample_releases_on_shutdown" :
        @(snapshot->latest_sample_releases_on_shutdown),
    @"drain_callbacks_scheduled" : @(snapshot->drain_callbacks_scheduled),
    @"drain_dequeues" : @(snapshot->drain_dequeues),
    @"queue_depth_high_water" : @(snapshot->queue_depth_high_water),
    @"strict_replay_pacing_accepted" :
        @(snapshot->strict_replay_pacing_accepted),
    @"strict_replay_pacing_late_rejections" :
        @(snapshot->strict_replay_pacing_late_rejections),
    @"strict_replay_pacing_pacer_late_rejections" :
        @(snapshot->strict_replay_pacing_pacer_late_rejections),
    @"strict_replay_pacing_overflow_rejections" :
        @(snapshot->strict_replay_pacing_overflow_rejections),
    @"strict_replay_pacing_sequence_rejections" :
        @(snapshot->strict_replay_pacing_sequence_rejections),
    @"strict_replay_pacing_added_latency_rejections" :
        @(snapshot->strict_replay_pacing_added_latency_rejections),
    @"strict_replay_pacing_prearm_discards" :
        @(snapshot->strict_replay_pacing_prearm_discards),
    @"strict_replay_pacing_rearm_count" :
        @(snapshot->strict_replay_pacing_rearm_count),
    @"strict_replay_pacing_rearm_prearm_discards" :
        @(snapshot->strict_replay_pacing_rearm_prearm_discards),
    @"strict_replay_pacing_arm_count" :
        @(snapshot->strict_replay_pacing_arm_count),
    @"strict_replay_pacing_late_phase_corrections" :
        @(snapshot->strict_replay_pacing_late_phase_corrections),
    @"strict_replay_pacing_early_phase_corrections" :
        @(snapshot->strict_replay_pacing_early_phase_corrections),
    @"strict_replay_dispatch_submissions" :
        @(snapshot->strict_replay_dispatch_submissions),
    @"strict_replay_dispatch_late_rejections" :
        @(snapshot->strict_replay_dispatch_late_rejections),
    @"strict_replay_dispatch_overflow_rejections" :
        @(snapshot->strict_replay_dispatch_overflow_rejections),
    @"strict_replay_dispatch_depth_high_water" :
        @(snapshot->strict_replay_dispatch_depth_high_water),
    @"strict_replay_dispatch_pending" : @(strictReplayDispatchPending),
    @"shutdown_count" : @(snapshot->shutdown_count),
    @"display_identity_context_binding_attempts" :
        @(snapshot->display_identity_context_binding_attempts),
    @"display_identity_context_binding_successes" :
        @(snapshot->display_identity_context_binding_successes),
    @"display_identity_context_binding_failures" :
        @(snapshot->display_identity_context_binding_failures),
    @"display_identity_context_binding_total_duration_ns" :
        @(snapshot->display_identity_context_binding_total_duration_ns),
    @"display_identity_context_binding_maximum_duration_ns" :
        @(snapshot->display_identity_context_binding_maximum_duration_ns),
    @"display_identity_context_binding_durations_over_250us" :
        @(snapshot->display_identity_context_binding_durations_over_250us),
    @"display_identity_context_binding_durations_over_1ms" :
        @(snapshot->display_identity_context_binding_durations_over_1ms),
    @"display_identity_context_registrations" :
        @(snapshot->display_identity_context_registrations),
    @"display_identity_context_registration_failures" :
        @(snapshot->display_identity_context_registration_failures),
    @"display_identity_watermark_reads" :
        @(snapshot->display_identity_watermark_reads),
    @"display_identity_watermark_decode_successes" :
        @(snapshot->display_identity_watermark_decode_successes),
    @"display_identity_watermark_decode_total_duration_ns" :
        @(snapshot->display_identity_watermark_decode_total_duration_ns),
    @"display_identity_watermark_decode_maximum_duration_ns" :
        @(snapshot->display_identity_watermark_decode_maximum_duration_ns),
    @"display_identity_watermark_decode_durations_over_250us" :
        @(snapshot->display_identity_watermark_decode_durations_over_250us),
    @"display_identity_watermark_decode_durations_over_1ms" :
        @(snapshot->display_identity_watermark_decode_durations_over_1ms),
    @"display_identity_unsupported_pixel_format_failures" :
        @(snapshot->display_identity_unsupported_pixel_format_failures),
    @"display_identity_pixel_buffer_lock_failures" :
        @(snapshot->display_identity_pixel_buffer_lock_failures),
    @"display_identity_geometry_failures" :
        @(snapshot->display_identity_geometry_failures),
    @"display_identity_contrast_failures" :
        @(snapshot->display_identity_contrast_failures),
    @"display_identity_sync_failures" :
        @(snapshot->display_identity_sync_failures),
    @"display_identity_checksum_failures" :
        @(snapshot->display_identity_checksum_failures),
    @"display_identity_context_misses" :
        @(snapshot->display_identity_context_misses),
    @"display_identity_invalid_lookups" :
        @(snapshot->display_identity_invalid_lookups),
    @"display_identity_pointer_comparisons" :
        @(snapshot->display_identity_pointer_comparisons),
    @"surface_created_count" : @(surfaceCreatedCount),
    @"surface_live_count" : @(surfaceLiveCount),
    @"surface_maximum_live_count" : @(surfaceMaximumLiveCount),
    @"pending_sample_present" : @(pendingSamplePresent),
    @"drain_scheduled" : @(drainScheduled),
    @"shutting_down" : @(shuttingDown),
    @"layer_ready_for_display" : @(layerReadyForDisplay),
    @"render_event_offset_ns" : InumaNativeSurfaceSamples(
        snapshot->render_event_offset_ns, snapshot->render_event_count),
    @"render_frame_generation" : InumaNativeSurfaceSamples(
        snapshot->render_frame_generation, snapshot->render_event_count),
    @"enqueue_event_offset_ns" : InumaNativeSurfaceSamples(
        snapshot->enqueue_event_offset_ns, snapshot->enqueue_event_count),
    @"enqueue_frame_generation" : InumaNativeSurfaceSamples(
        snapshot->enqueue_frame_generation, snapshot->enqueue_event_count),
    @"enqueue_call_duration_ns" : InumaNativeSurfaceSamples(
        snapshot->enqueue_call_duration_ns, snapshot->enqueue_event_count),
    @"presentation_trace_v2" : presentationTrace,
    @"decoder_boundary_trace" :
        (_inumaSegmentedEvidenceEnabled
             ? InumaDecoderBoundaryTraceDrainSnapshot()
             : InumaDecoderBoundaryTraceSnapshot()),
    @"receiver_scheduler_trace" :
        (_inumaSegmentedEvidenceEnabled
             ? RTCInumaReceiverSchedulerTraceDrainSnapshot(terminal)
             : RTCInumaReceiverSchedulerTraceSnapshot()),
    @"prerenderer_smoothing_disabled_configuration_count" :
        @(prerendererSmoothingDisabledConfigurationCount),
    @"prerenderer_smoothing_configuration_contract" :
        @"explicit_objc_to_native_peer_configuration",
    @"prerenderer_smoothing_disabled_applied" :
        prerendererSmoothingDisabledConfigurationCount > 0 ? @YES : @NO,
    @"low_latency_video_playout_enabled_configuration_count" :
        @(lowLatencyVideoPlayoutEnabledConfigurationCount),
    @"low_latency_video_playout_configuration_contract" :
        @"explicit_dart_to_objc_factory_field_trials",
    @"low_latency_video_playout_enabled" :
        lowLatencyVideoPlayoutEnabledConfigurationCount > 0 ? @YES : @NO,
    @"low_latency_video_playout_forced_minimum_ms" :
        @(InumaLowLatencyVideoPlayoutForcedMinimumMs()),
    @"low_latency_video_playout_forced_maximum_ms" :
        @(InumaLowLatencyVideoPlayoutForcedMaximumMs()),
    @"low_latency_video_playout_minimum_pacing_ms" :
        @(InumaLowLatencyVideoPlayoutMinimumPacingMs()),
    @"low_latency_video_playout_maximum_decode_queue_size" :
        @(InumaLowLatencyVideoPlayoutMaximumDecodeQueueSize()),
    @"low_latency_video_playout_initial_nack_rtt_ms" :
        @(InumaLowLatencyVideoPlayoutInitialNackRttMs()),
    @"low_latency_video_playout_nack_periodic_interval_ms" :
        @(InumaLowLatencyVideoPlayoutNackPeriodicIntervalMs()),
    @"low_latency_video_playout_nack_timer_high_precision" :
        @(InumaLowLatencyVideoPlayoutNackTimerHighPrecision()),
    @"credential_value_retained" : @NO,
    @"raw_pixels_retained" : @NO,
  };
  NSError* error = nil;
  if (_inumaSegmentedEvidenceEnabled) {
    NSMutableDictionary<NSString*, id>* surface = [report mutableCopy];
    NSDictionary* decoder = surface[@"decoder_boundary_trace"];
    NSDictionary* receiver = surface[@"receiver_scheduler_trace"];
    [surface removeObjectForKey:@"presentation_trace_v2"];
    [surface removeObjectForKey:@"decoder_boundary_trace"];
    [surface removeObjectForKey:@"receiver_scheduler_trace"];
    NSDictionary* segmentPayload = @{
      @"surface_trace" : surface,
      @"presentation_trace_v2" : presentationTrace,
      @"decoder_boundary_trace" : decoder,
      @"receiver_scheduler_trace" : receiver,
    };
    if (![_inumaSegmentedEvidenceWriter writeSegment:segmentPayload
                                         startedAtNs:_inumaSegmentStartedMonotonicNs
                                           endedAtNs:snapshotAt
                                   snapshotWallTimeNs:snapshotWallTimeNs
                                            terminal:terminal]) {
      fprintf(stderr, "INUMA_SEGMENTED_SCALAR_EVIDENCE_WRITE_FAILED\n");
    } else {
      _inumaSegmentStartedMonotonicNs = snapshotAt;
    }
    free(snapshot);
    return;
  }
  NSData* data = [NSJSONSerialization dataWithJSONObject:report
                                                 options:0
                                                   error:&error];
  if (data != nil && error == nil) {
    if (![data writeToFile:_inumaTracePath
                   options:NSDataWritingAtomic
                     error:&error]) {
      fprintf(stderr, "INUMA_NATIVE_SURFACE_TRACE_WRITE_FAILED\n");
    }
  } else {
    fprintf(stderr, "INUMA_NATIVE_SURFACE_TRACE_SERIALIZATION_FAILED\n");
  }
  free(snapshot);
}

- (void)inumaStopNativeVideoSurface {
  if (!_inumaNativeSurfaceSelected && !_inumaTrace.enabled) {
    return;
  }
  os_unfair_lock_lock(&_inumaTraceLock);
  if (_inumaStopRequested) {
    os_unfair_lock_unlock(&_inumaTraceLock);
    return;
  }
  _inumaStopRequested = YES;
  os_unfair_lock_unlock(&_inumaTraceLock);
  [self inumaStopPresentationDisplayLink];
  [self inumaStopNativePresentationObserver];
  void (^stopOnSampleQueue)(void) = ^{
    const uint64_t stopStartedAt = self->_inumaTrace.enabled
                                       ? InumaNativeSurfaceMonotonicNanoseconds()
                                       : 0;
    InumaPresentationFrameContext shutdownContext = {0};
    if (self->_inumaTrace.enabled) {
      [self->_inumaPresentationTrace
          recordEventKind:InumaPresentationEventShutdownBegin
                      atNs:stopStartedAt
                   context:shutdownContext
                 durationNs:0
                       value:self->_inumaSurfaceSessionSequence];
    }
    CMSampleBufferRef pendingSampleBuffer = nil;
    InumaPresentationFrameContext pendingContext = {0};
    uint64_t pendingSetAtNs = 0;
    os_unfair_lock_lock(&self->_inumaTraceLock);
    if (!self->_inumaShuttingDown) {
      self->_inumaShuttingDown = YES;
      self->_inumaTrace.shutdown_count += 1;
    }
    pendingSampleBuffer = self->_inumaPendingSampleBuffer;
    pendingContext = self->_inumaPendingContext;
    pendingSetAtNs = self->_inumaPendingSetAtNs;
    self->_inumaPendingSampleBuffer = nil;
    self->_inumaPendingContext = (InumaPresentationFrameContext){0};
    self->_inumaPendingSetAtNs = 0;
    if (pendingSampleBuffer != nil) {
      self->_inumaTrace.latest_sample_releases_on_shutdown += 1;
    }
    os_unfair_lock_unlock(&self->_inumaTraceLock);
    if (pendingSampleBuffer != nil) {
      if (self->_inumaTrace.enabled) {
        pendingContext.pendingAgeNs = stopStartedAt - pendingSetAtNs;
        [self->_inumaPresentationTrace
            recordEventKind:InumaPresentationEventPendingCancelledAtShutdown
                        atNs:stopStartedAt
                     context:pendingContext
                   durationNs:pendingContext.pendingAgeNs
                         value:0];
      }
      CFRelease(pendingSampleBuffer);
    }
    [self->_inumaRendererAdapter stop];
    [self->_inumaStrictReplayPacer stop];
    if (self->_inumaTrace.enabled) {
      const uint64_t stoppedAt = InumaNativeSurfaceMonotonicNanoseconds();
      [self->_inumaPresentationTrace closeOpenIntervalsAtNs:stoppedAt
                                                    context:shutdownContext];
      [self->_inumaPresentationTrace
          recordEventKind:InumaPresentationEventShutdownEnd
                      atNs:stoppedAt
                   context:shutdownContext
                 durationNs:stoppedAt - stopStartedAt
                       value:self->_inumaSurfaceSessionSequence];
    }
    os_unfair_lock_lock(&gInumaNativeVideoSurfaceLifecycleLock);
    if (self->_inumaSurfaceRegistered) {
      self->_inumaSurfaceRegistered = NO;
      gInumaNativeVideoSurfaceLiveCount -= 1;
    }
    os_unfair_lock_unlock(&gInumaNativeVideoSurfaceLifecycleLock);
  };
  if (dispatch_get_specific(kInumaNativeVideoSurfaceQueueKey) != NULL) {
    stopOnSampleQueue();
  } else {
    dispatch_sync(_sampleBufferQueue, stopOnSampleQueue);
  }
  if (_inumaTraceTimer != nil) {
    dispatch_source_cancel(_inumaTraceTimer);
    _inumaTraceTimer = nil;
  }
  if (_inumaTraceWriterQueue != nil) {
    dispatch_sync(_inumaTraceWriterQueue, ^{
      [self inumaWriteNativeVideoSurfaceTraceOnWriterQueueWithRetryAttempt:0
                                                                  terminal:YES];
    });
  }
}
#else
- (void)inumaWriteNativeVideoSurfaceTrace {
}

- (void)inumaStopNativeVideoSurface {
}
#endif

- (void)updateVideoLayerTransformForRotation:(RTCVideoRotation)rotation {
  if (_lastVideoRotation == rotation) {
    return;
  }
  _lastVideoRotation = rotation;

  CATransform3D transform = [self fromFrameRotation:rotation];
  // CoreAnimation derives the layer's geometry from `frame` through the
  // active transform, so both must be applied together: updating only the
  // transform leaves the layer with bounds computed under the old rotation
  // until the next layout pass.
  void (^applyRotation)(void) = ^{
    self->_videoLayer.transform = transform;
    [self layoutVideoLayer];
  };
  if ([NSThread isMainThread]) {
    applyRotation();
  } else {
    dispatch_async(dispatch_get_main_queue(), applyRotation);
  }
}

- (CVPixelBufferRef)pixelBufferFromRTCCVPixelBuffer:(RTCCVPixelBuffer*)buffer {
  if (![buffer requiresCropping] &&
      ![buffer requiresScalingToWidth:buffer.width height:buffer.height]) {
    CVPixelBufferRef pixelBuffer = buffer.pixelBuffer;
    CFRetain(pixelBuffer);
    return pixelBuffer;
  }

  CVPixelBufferRef outputPixelBuffer = nil;
  OSType pixelFormat = CVPixelBufferGetPixelFormatType(buffer.pixelBuffer);
  @synchronized(self) {
    CVPixelBufferPoolRef pixelBufferPool =
        [self pixelBufferPoolForWidth:buffer.width height:buffer.height pixelFormat:pixelFormat];
    if (pixelBufferPool) {
      CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &outputPixelBuffer);
    }
  }
  if (!outputPixelBuffer) {
    return nil;
  }

  int tempBufferSize =
      [buffer bufferSizeForCroppingAndScalingToWidth:buffer.width height:buffer.height];
  uint8_t* tempBuffer = nil;
  if (tempBufferSize > 0) {
    tempBuffer = malloc((size_t)tempBufferSize);
    if (!tempBuffer) {
      CFRelease(outputPixelBuffer);
      return nil;
    }
  }

  BOOL didCropAndScale = [buffer cropAndScaleTo:outputPixelBuffer withTempBuffer:tempBuffer];
  if (tempBuffer) {
    free(tempBuffer);
  }
  if (!didCropAndScale) {
    CFRelease(outputPixelBuffer);
    return nil;
  }

  CVBufferPropagateAttachments(buffer.pixelBuffer, outputPixelBuffer);
  return outputPixelBuffer;
}

- (CVPixelBufferPoolRef)pixelBufferPoolForWidth:(int)width
                                         height:(int)height
                                    pixelFormat:(OSType)pixelFormat {
  if (_cropAndScalePixelBufferPool && _cropAndScalePixelBufferPoolWidth == width &&
      _cropAndScalePixelBufferPoolHeight == height &&
      _cropAndScalePixelBufferPoolPixelFormat == pixelFormat) {
    return _cropAndScalePixelBufferPool;
  }

  NSDictionary* pixelBufferAttributes = @{
    (id)kCVPixelBufferCGImageCompatibilityKey : @YES,
    (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (id)kCVPixelBufferWidthKey : @(width),
    (id)kCVPixelBufferHeightKey : @(height),
    (id)kCVPixelBufferPixelFormatTypeKey : @(pixelFormat),
  };
  NSDictionary* poolAttributes = @{
    (id)kCVPixelBufferPoolMinimumBufferCountKey : @4,
  };

  CVPixelBufferPoolRef pixelBufferPool = NULL;
  CVReturn result =
      CVPixelBufferPoolCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)poolAttributes,
                              (__bridge CFDictionaryRef)pixelBufferAttributes, &pixelBufferPool);
  if (result != kCVReturnSuccess) {
    return NULL;
  }

  if (_cropAndScalePixelBufferPool) {
    CFRelease(_cropAndScalePixelBufferPool);
  }
  _cropAndScalePixelBufferPool = pixelBufferPool;
  _cropAndScalePixelBufferPoolWidth = width;
  _cropAndScalePixelBufferPoolHeight = height;
  _cropAndScalePixelBufferPoolPixelFormat = pixelFormat;

  return _cropAndScalePixelBufferPool;
}

- (CVPixelBufferRef)toCVPixelBuffer:(RTCVideoFrame*)frame {
  CVPixelBufferRef outputPixelBuffer = nil;
  NSDictionary* pixelAttributes = @{
    (id)kCVPixelBufferCGImageCompatibilityKey : @YES,
    (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
  CVPixelBufferCreate(kCFAllocatorDefault, frame.width, frame.height, kCVPixelFormatType_32BGRA,
                      (__bridge CFDictionaryRef)(pixelAttributes), &outputPixelBuffer);
  if (!outputPixelBuffer) {
    return nil;
  }

  id<RTCI420Buffer> i420Buffer = [frame.buffer toI420];

  CVPixelBufferLockBaseAddress(outputPixelBuffer, 0);
  uint8_t* dst = CVPixelBufferGetBaseAddress(outputPixelBuffer);
  const size_t bytesPerRow = CVPixelBufferGetBytesPerRow(outputPixelBuffer);

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

  CVPixelBufferUnlockBaseAddress(outputPixelBuffer, 0);
  return outputPixelBuffer;
}

- (CMSampleBufferRef)sampleBufferFromPixelBuffer:(CVPixelBufferRef)pixelBuffer {
  CMSampleBufferRef sampleBuffer = NULL;
  CMVideoFormatDescriptionRef formatDesc = NULL;
  OSStatus err = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);
  if (err != noErr) {
    return nil;
  }

  CMSampleTimingInfo sampleTimingInfo = kCMTimingInfoInvalid;
  err = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixelBuffer, formatDesc,
                                                 &sampleTimingInfo, &sampleBuffer);
  if (formatDesc) {
    CFRelease(formatDesc);
  }
  if (err != noErr) {
    return nil;
  }

  if (sampleBuffer) {
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
    if (attachments && CFArrayGetCount(attachments) > 0) {
      CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
      if (dict) {
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
      }
    }
  }
  return sampleBuffer;
}

- (CATransform3D)fromFrameRotation:(RTCVideoRotation)rotation {
  switch (rotation) {
    case RTCVideoRotation_0:
      return CATransform3DIdentity;
    case RTCVideoRotation_90:
      return CATransform3DMakeRotation(M_PI / 2.0, 0, 0, 1);
    case RTCVideoRotation_180:
      return CATransform3DMakeRotation(M_PI, 0, 0, 1);
    case RTCVideoRotation_270:
      return CATransform3DMakeRotation(-M_PI / 2.0, 0, 0, 1);
  }
  return CATransform3DIdentity;
}

@end
