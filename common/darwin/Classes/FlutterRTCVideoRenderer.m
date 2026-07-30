#import "FlutterRTCVideoRenderer.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CGImage.h>
#import <TargetConditionals.h>
#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCYUVHelper.h>
#import <WebRTC/RTCYUVPlanarBuffer.h>
#import <WebRTC/WebRTC.h>

#import <objc/runtime.h>
#include <stdlib.h>
#include <time.h>

#import "FlutterWebRTCPlugin.h"
#import <os/lock.h>

#if TARGET_OS_OSX
enum {
  kInumaTextureTraceCapacity = 8192,
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
  uint64_t strict_hold_timer_created;
  uint64_t strict_hold_timer_fired;
  uint64_t strict_hold_timer_cancelled;
  uint64_t strict_hold_timer_create_failures;
  uint64_t stock_bgra_pool_create_failures;
  uint64_t stock_bgra_pool_buffer_requests;
  uint64_t stock_bgra_pool_buffer_failures;
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
  NSUInteger strict_hold_timer_event_count;
  NSUInteger render_event_count;
  NSUInteger coalesced_pending_age_count;
  NSUInteger copy_event_count;
} InumaTextureTrace;

static uint64_t InumaMonotonicNanoseconds(void) {
  return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
}

static void InumaAppendTraceSample(uint64_t *samples, NSUInteger *count,
                                   uint64_t value) {
  if (*count >= kInumaTextureTraceCapacity) {
    return;
  }
  samples[*count] = value;
  *count += 1;
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
                               bypassMinimumHold:(bool)bypassMinimumHold;
- (void)inumaCancelTextureHoldTimerLocked;
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
#endif
  os_unfair_lock_lock(&_lock);
#if TARGET_OS_OSX
  const uint64_t locked = _inumaTrace.enabled ? InumaMonotonicNanoseconds() : 0;
  if (_inumaTrace.enabled) {
    _inumaTrace.copy_calls += 1;
    InumaAppendTraceSample(_inumaTrace.copy_lock_wait_samples,
                           &_inumaTrace.copy_lock_wait_count, locked - started);
  }
#endif
  if (_pixelBufferRef != nil && _frameAvailable) {
    buffer = CVBufferRetain(_pixelBufferRef);
    _frameAvailable = false;
#if TARGET_OS_OSX
    const uint64_t copiedAt = InumaMonotonicNanoseconds();
    _inumaLastCopyMonotonicNs = copiedAt;
    if (_inumaTrace.enabled) {
      _inumaTrace.copy_hits += 1;
      if (_inumaFrameReadyMonotonicNs > 0 &&
          locked >= _inumaFrameReadyMonotonicNs) {
        InumaAppendTraceSample(_inumaTrace.copy_ready_age_samples,
                               &_inumaTrace.copy_ready_age_count,
                               locked - _inumaFrameReadyMonotonicNs);
      }
      if (_inumaTraceStartedMonotonicNs > 0 &&
          locked >= _inumaTraceStartedMonotonicNs &&
          _inumaTrace.copy_event_count < kInumaTextureTraceCapacity) {
        const NSUInteger copyEventIndex = _inumaTrace.copy_event_count;
        _inumaTrace.copy_event_offset_samples[copyEventIndex] =
            locked - _inumaTraceStartedMonotonicNs;
        _inumaTrace.copy_frame_timestamp_ns_samples[copyEventIndex] =
            _inumaFrameTimestampNs;
        _inumaTrace.copy_event_count += 1;
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
      if (_inumaTrace.enabled) {
        _inumaTrace.queue_promotions += 1;
        _inumaTrace.rescue_hold_preservations += 1;
        const NSUInteger preservationIndex =
            _inumaTrace.rescue_hold_preservation_count;
        if (preservationIndex < kInumaTextureTraceCapacity) {
          _inumaTrace
              .rescue_hold_preservation_frame_timestamp_ns_samples
                  [preservationIndex] = promoted.frame_timestamp_ns;
          _inumaTrace.rescue_hold_preservation_count += 1;
        }
        if (copiedAt >= promoted.ready_monotonic_ns) {
          InumaAppendTraceSample(
              _inumaTrace.queue_wait_samples,
              &_inumaTrace.queue_wait_count,
              copiedAt - promoted.ready_monotonic_ns);
        }
        if (_inumaTraceStartedMonotonicNs > 0 &&
            copiedAt >= _inumaTraceStartedMonotonicNs &&
            _inumaTrace.queue_promote_event_count <
                kInumaTextureTraceCapacity) {
          const NSUInteger promoteIndex =
              _inumaTrace.queue_promote_event_count;
          _inumaTrace.queue_promote_event_offset_samples[promoteIndex] =
              copiedAt - _inumaTraceStartedMonotonicNs;
          _inumaTrace.queue_promote_frame_timestamp_ns_samples[promoteIndex] =
              promoted.frame_timestamp_ns;
          _inumaTrace.queue_promote_event_count += 1;
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
    [self inumaScheduleTextureNotificationForTextureId:promotedTextureId
                                      frameTimestampNs:
                                          promotedFrameTimestampNs
                                     bypassMinimumHold:false];
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
        locked >= _inumaTraceStartedMonotonicNs &&
        _inumaTrace.render_event_count < kInumaTextureTraceCapacity) {
      inumaRenderEventIndex = _inumaTrace.render_event_count;
      _inumaTrace.render_event_offset_samples[inumaRenderEventIndex] =
          locked - _inumaTraceStartedMonotonicNs;
      _inumaTrace.render_frame_timestamp_ns_samples[inumaRenderEventIndex] =
          frame.timeStampNs;
      _inumaTrace.render_outcome_samples[inumaRenderEventIndex] = 0;
      _inumaTrace.render_event_count += 1;
    }
    InumaAppendTraceSample(_inumaTrace.render_lock_wait_samples,
                           &_inumaTrace.render_lock_wait_count,
                           locked - started);
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
            frameReadyNs >= _inumaTraceStartedMonotonicNs &&
            _inumaTrace.queue_enqueue_event_count <
                kInumaTextureTraceCapacity) {
          const NSUInteger enqueueIndex =
              _inumaTrace.queue_enqueue_event_count;
          _inumaTrace.queue_enqueue_event_offset_samples[enqueueIndex] =
              frameReadyNs - _inumaTraceStartedMonotonicNs;
          _inumaTrace.queue_enqueue_frame_timestamp_ns_samples[enqueueIndex] =
              frame.timeStampNs;
          _inumaTrace.queue_enqueue_event_count += 1;
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
      InumaAppendTraceSample(_inumaTrace.coalesced_pending_age_samples,
                             &_inumaTrace.coalesced_pending_age_count,
                             locked - _inumaFrameReadyMonotonicNs);
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
                                         bypassMinimumHold:false];
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
            InumaMonotonicNanoseconds() - conversionStarted);
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
                               bypassMinimumHold:(bool)bypassMinimumHold {
  const uint64_t enqueuedAt = InumaMonotonicNanoseconds();
  __block uint64_t scheduledDelayNs = 0;
  os_unfair_lock_lock(&_lock);
  const bool notificationCanBeScheduled =
      _textureId == textureId && _frameAvailable &&
      _inumaFrameTimestampNs == frameTimestampNs;
  if (notificationCanBeScheduled && bypassMinimumHold &&
      _inumaTrace.enabled) {
    _inumaTrace.rescue_hold_bypasses += 1;
    const NSUInteger bypassIndex = _inumaTrace.rescue_hold_bypass_count;
    if (bypassIndex < kInumaTextureTraceCapacity) {
      _inumaTrace
          .rescue_hold_bypass_frame_timestamp_ns_samples[bypassIndex] =
          frameTimestampNs;
      _inumaTrace.rescue_hold_bypass_count += 1;
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
        const NSUInteger holdIndex =
            _inumaTrace.texture_hold_delay_count;
        InumaAppendTraceSample(
            _inumaTrace.texture_hold_delay_samples,
            &_inumaTrace.texture_hold_delay_count,
            scheduledDelayNs);
        if (holdIndex < kInumaTextureTraceCapacity) {
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
        notifyStarted >= strongSelf->_inumaTraceStartedMonotonicNs &&
        strongSelf->_inumaTrace.texture_notify_event_count <
            kInumaTextureTraceCapacity) {
      const NSUInteger notifyEventIndex =
          strongSelf->_inumaTrace.texture_notify_event_count;
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
      strongSelf->_inumaTrace.texture_notify_event_count += 1;
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
            notifyStarted - enqueuedAt);
      }
      InumaAppendTraceSample(
          strongSelf->_inumaTrace.texture_notify_samples,
          &strongSelf->_inumaTrace.texture_notify_count,
          notifyEnded - notifyStarted);
      os_unfair_lock_unlock(&strongSelf->_lock);
    }
  };
  if ([NSThread isMainThread] && scheduledDelayNs == 0) {
    notifyTextureFrameAvailable();
  } else if (scheduledDelayNs == 0) {
    dispatch_async(dispatch_get_main_queue(), notifyTextureFrameAvailable);
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
          dispatch_get_main_queue(), notifyTextureFrameAvailable);
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
            deadlineNs >= _inumaTraceStartedMonotonicNs &&
            _inumaTrace.strict_hold_timer_event_count <
                kInumaTextureTraceCapacity) {
          timerEventIndex = _inumaTrace.strict_hold_timer_event_count;
          _inumaTrace.strict_hold_timer_deadline_offset_samples
              [timerEventIndex] =
              deadlineNs - _inumaTraceStartedMonotonicNs;
          _inumaTrace.strict_hold_timer_frame_timestamp_ns_samples
              [timerEventIndex] = frameTimestampNs;
          _inumaTrace.strict_hold_timer_event_count += 1;
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
        notifyTextureFrameAvailable();
      }
    });
    dispatch_source_set_timer(
        timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)scheduledDelayNs),
        DISPATCH_TIME_FOREVER, 0);
    dispatch_resume(timer);
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
  os_unfair_lock_lock(&_lock);
  *snapshot = _inumaTrace;
  pendingTextureFrameCount = _inumaPendingTextureFrameCount;
  textureHoldTimerActive = _inumaTextureHoldTimer != nil;
  os_unfair_lock_unlock(&_lock);
  NSString *mode = _inumaPixelMode == InumaMacOSPixelModeNativeNV12
                       ? @"native_nv12"
                       : @"stock_bgra";
  NSDictionary *report = @{
    @"schema" : @"inuma.flutter_webrtc.macos_texture_trace.v1",
    @"status" : @"pass",
    @"pixel_mode" : mode,
    @"payload_policy" : @"scalar_timing_and_counts_only_no_pixel_payloads",
    @"sample_capacity" : @(kInumaTextureTraceCapacity),
    @"tail_diagnostics_version" : @13,
    @"trace_clock_domain" :
        @"macos_clock_monotonic_raw_shared_mach_host_time",
    @"texture_notification_contract" :
        @"frame_state_before_platform_thread_notification",
    @"trace_snapshot_monotonic_ns" : @(InumaMonotonicNanoseconds()),
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
