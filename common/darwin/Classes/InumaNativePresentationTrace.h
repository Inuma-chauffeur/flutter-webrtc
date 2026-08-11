// Bounded scalar evidence contract for macOS native video presentation.

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <CoreVideo/CoreVideo.h>

#if TARGET_OS_OSX

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint32_t, InumaPresentationEventKind) {
  InumaPresentationEventSessionStart = 1,
  InumaPresentationEventRenderReceived = 2,
  InumaPresentationEventSampleBuildBegin = 3,
  InumaPresentationEventSampleBuildEnd = 4,
  InumaPresentationEventSampleBuildFailed = 5,
  InumaPresentationEventPendingSet = 6,
  InumaPresentationEventPendingReplaced = 7,
  InumaPresentationEventPendingRejectedAfterShutdown = 8,
  InumaPresentationEventPendingDeferred = 9,
  InumaPresentationEventPendingResumed = 10,
  InumaPresentationEventEnqueueBegin = 11,
  InumaPresentationEventRendererFlush = 12,
  InumaPresentationEventReadinessFalse = 13,
  InumaPresentationEventReadinessTrue = 14,
  InumaPresentationEventReadinessClosedAtShutdown = 15,
  InumaPresentationEventEnqueueEnd = 16,
  InumaPresentationEventRendererFailed = 17,
  InumaPresentationEventDisplayedObserved = 18,
  InumaPresentationEventDisplayedLookupMiss = 19,
  InumaPresentationEventSurfaceResize = 20,
  InumaPresentationEventReconnect = 21,
  InumaPresentationEventShutdownBegin = 22,
  InumaPresentationEventPendingCancelledAtShutdown = 23,
  InumaPresentationEventCallbackAfterStopRejected = 24,
  InumaPresentationEventShutdownEnd = 25,
  InumaPresentationEventPacingAccepted = 26,
  InumaPresentationEventPacingLateRejected = 27,
  InumaPresentationEventPacingOverflowRejected = 28,
  InumaPresentationEventPacingSequenceRejected = 29,
  InumaPresentationEventPacingAddedLatencyRejected = 30,
  InumaPresentationEventPacingPrearmDiscarded = 31,
  InumaPresentationEventPacingLatePhaseCorrected = 32,
  InumaPresentationEventPacingEarlyPhaseCorrected = 33,
  InumaPresentationEventKindCount = 34,
};

typedef NS_ENUM(int32_t, InumaRendererErrorDomainClass) {
  InumaRendererErrorDomainNone = 0,
  InumaRendererErrorDomainAVFoundation = 1,
  InumaRendererErrorDomainOther = 2,
};

typedef NS_ENUM(uint32_t, InumaPresentationTimingPolicy) {
  InumaPresentationTimingUnknown = 0,
  InumaPresentationTimingImmediateInvalid = 1,
  InumaPresentationTimingValidHostPTS = 2,
};

typedef struct {
  uint64_t sourceIdentity;
  uint64_t renderOrdinal;
  uint64_t nativeGeneration;
  uint64_t rtpTimestamp;
  uint64_t pendingAgeNs;
  uint64_t presentationReserveNs;
  uint64_t scheduledPresentationTimeNs;
  uint64_t presentationResidenceNs;
  uint64_t presentationLatenessNs;
  uint64_t presentationQueueDepth;
  InumaPresentationTimingPolicy timingPolicy;
  BOOL sourceIdentityValid;
} InumaPresentationFrameContext;

typedef struct {
  BOOL accepted;
  BOOL flushedBeforeEnqueue;
  BOOL readyBeforeEnqueue;
  BOOL failedAfterEnqueue;
  int32_t rendererStatusBeforeEnqueue;
  int32_t rendererStatusAfterEnqueue;
  int32_t rendererErrorDomainClass;
  int64_t rendererErrorCode;
} InumaRendererSubmissionResult;

typedef NS_ENUM(uint32_t, InumaDisplayedFrameIdentityLookupResult) {
  InumaDisplayedFrameIdentityLookupFound = 0,
  InumaDisplayedFrameIdentityLookupUnsupportedPixelFormat = 1,
  InumaDisplayedFrameIdentityLookupPixelBufferLockFailed = 2,
  InumaDisplayedFrameIdentityLookupGeometryInvalid = 3,
  InumaDisplayedFrameIdentityLookupInsufficientContrast = 4,
  InumaDisplayedFrameIdentityLookupSyncMismatch = 5,
  InumaDisplayedFrameIdentityLookupChecksumMismatch = 6,
  InumaDisplayedFrameIdentityLookupContextMissing = 7,
  InumaDisplayedFrameIdentityLookupInvalid = 8,
};

typedef struct {
  uint32_t frameIdentity;
  uint32_t sourceSofUsLow;
  uint32_t sourceEofUsLow;
} InumaProductWatermarkIdentity;

// Decodes the existing CRC-checked product watermark directly from a read-only
// BGRA or NV12 displayed pixel buffer. No pixel, pointer, or attachment escapes
// this call.
FOUNDATION_EXPORT InumaDisplayedFrameIdentityLookupResult
InumaDecodeProductWatermark(CVPixelBufferRef pixelBuffer,
                            InumaProductWatermarkIdentity* identity);

// Binds a scalar source identity to its live frame context and resolves only a
// CRC-checked watermark identity decoded from the renderer-displayed buffer.
// It never stores or compares buffer pointers or retains pixel payloads.
@interface InumaDisplayedFrameIdentityLedger : NSObject

@property(nonatomic, readonly) NSUInteger capacity;

- (nullable instancetype)initWithCapacity:(NSUInteger)capacity;

- (BOOL)registerContext:(InumaPresentationFrameContext)context;

- (InumaDisplayedFrameIdentityLookupResult)
    lookupContextForDisplayedPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                  context:(InumaPresentationFrameContext*)context;

@end

@protocol InumaPresentationTraceSink <NSObject>

- (void)recordGeneration:(uint64_t)generation
             startedAtNs:(uint64_t)startedAtNs
           completedAtNs:(uint64_t)completedAtNs
                  result:(InumaRendererSubmissionResult)result;

@optional
- (void)recordSubmissionBeginContext:(InumaPresentationFrameContext)context
                                atNs:(uint64_t)atNs;
- (void)recordRendererFlushContext:(InumaPresentationFrameContext)context
                              atNs:(uint64_t)atNs
                             result:(InumaRendererSubmissionResult)result;
- (void)recordReadinessContext:(InumaPresentationFrameContext)context
                           atNs:(uint64_t)atNs
                          result:(InumaRendererSubmissionResult)result;
- (void)recordSubmissionEndContext:(InumaPresentationFrameContext)context
                         startedAtNs:(uint64_t)startedAtNs
                       completedAtNs:(uint64_t)completedAtNs
                              result:(InumaRendererSubmissionResult)result;
- (void)recordContext:(InumaPresentationFrameContext)context
           startedAtNs:(uint64_t)startedAtNs
         completedAtNs:(uint64_t)completedAtNs
                result:(InumaRendererSubmissionResult)result;

@end

@interface InumaNativePresentationTrace : NSObject <InumaPresentationTraceSink>

@property(nonatomic, readonly) NSUInteger capacity;
@property(nonatomic, readonly) NSUInteger count;
@property(nonatomic, readonly) uint64_t totalEventCount;
@property(nonatomic, readonly) uint64_t overwrittenEventCount;
@property(nonatomic, readonly) uint64_t capacityExhaustions;
@property(nonatomic, readonly) uint64_t serializedPixelPayloadBytes;

- (nullable instancetype)initWithCapacity:(NSUInteger)capacity
                          sessionSequence:(uint64_t)sessionSequence
                              startedAtNs:(uint64_t)startedAtNs;

- (void)recordEventKind:(InumaPresentationEventKind)kind
                    atNs:(uint64_t)atNs
                 context:(InumaPresentationFrameContext)context
               durationNs:(uint64_t)durationNs
                     value:(uint64_t)value;

- (void)recordSubmissionBeginContext:(InumaPresentationFrameContext)context
                                atNs:(uint64_t)atNs;
- (void)recordRendererFlushContext:(InumaPresentationFrameContext)context
                              atNs:(uint64_t)atNs
                             result:(InumaRendererSubmissionResult)result;
- (void)recordReadinessContext:(InumaPresentationFrameContext)context
                           atNs:(uint64_t)atNs
                          result:(InumaRendererSubmissionResult)result;
- (void)recordSubmissionEndContext:(InumaPresentationFrameContext)context
                         startedAtNs:(uint64_t)startedAtNs
                       completedAtNs:(uint64_t)completedAtNs
                              result:(InumaRendererSubmissionResult)result;

- (void)closeOpenIntervalsAtNs:(uint64_t)atNs
                       context:(InumaPresentationFrameContext)context;

- (NSDictionary<NSString*, id>*)snapshotAtNs:(uint64_t)snapshotAtNs;

@end

NS_ASSUME_NONNULL_END

#endif
