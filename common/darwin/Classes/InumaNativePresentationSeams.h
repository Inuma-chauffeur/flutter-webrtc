#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

#import "InumaNativePresentationTrace.h"

#if TARGET_OS_OSX

NS_ASSUME_NONNULL_BEGIN

typedef uint64_t (^InumaMonotonicClockBlock)(void);
typedef uint64_t (^InumaHostTimeClockBlock)(void);

typedef struct {
  BOOL accepted;
  BOOL timelineStarted;
  BOOL prearmDiscarded;
  BOOL rearmTriggered;
  BOOL rearmPrearmDiscarded;
  BOOL timelineRearmed;
  BOOL generationSequenceValid;
  BOOL late;
  BOOL overflowed;
  BOOL addedLatencyExceeded;
  BOOL latePhaseCorrected;
  BOOL earlyPhaseCorrected;
  uint64_t arrivedAtHostTimeNs;
  uint64_t scheduledPresentationTimeNs;
  uint64_t presentationResidenceNs;
  uint64_t latenessNs;
  NSUInteger queueDepthBefore;
  NSUInteger queueDepthAfter;
} InumaStrictReplayPacingDecision;

typedef struct {
  uint64_t acceptedCount;
  uint64_t prearmDiscardCount;
  uint64_t latePhaseCorrectionCount;
  uint64_t earlyPhaseCorrectionCount;
  uint64_t armedGeneration;
  uint64_t lastArmedGeneration;
  uint64_t armCount;
  uint64_t rearmCount;
  uint64_t rearmPrearmDiscardCount;
  uint64_t lateCount;
  uint64_t overflowCount;
  uint64_t generationSequenceFailureCount;
  uint64_t addedLatencyViolationCount;
  NSUInteger queueDepthHighWater;
} InumaStrictReplayPacerSnapshot;

@interface InumaMonotonicClock : NSObject

- (instancetype)initWithNowBlock:(InumaMonotonicClockBlock)nowBlock;
- (uint64_t)nowNanoseconds;
+ (instancetype)systemClock;

@end

@interface InumaVideoSampleBuilder : NSObject

- (nullable CMSampleBufferRef)copyImmediateSampleBufferFromPixelBuffer:
    (CVPixelBufferRef)pixelBuffer CF_RETURNS_RETAINED;
- (nullable CMSampleBufferRef)copyTimedSampleBufferFromPixelBuffer:
                                    (CVPixelBufferRef)pixelBuffer
                                      presentationTimeNs:
                                          (uint64_t)presentationTimeNs
                                               durationNs:(uint64_t)durationNs
    CF_RETURNS_RETAINED;

@end

@interface InumaStrictReplayPacer : NSObject

@property(nonatomic, readonly) uint64_t presentationReserveNs;
@property(nonatomic, readonly) uint64_t maximumAddedLatencyNs;
@property(nonatomic, readonly) uint64_t frameIntervalNs;
@property(nonatomic, readonly) uint64_t minimumPresentationIntervalNs;
@property(nonatomic, readonly) uint64_t maximumPresentationIntervalNs;
@property(nonatomic, readonly) uint64_t minimumPresentationLeadNs;
@property(nonatomic, readonly) uint64_t stableCadenceIntervalMinimumNs;
@property(nonatomic, readonly) uint64_t stableCadenceIntervalMaximumNs;
@property(nonatomic, readonly) NSUInteger requiredStableCadenceIntervals;
@property(nonatomic, readonly) NSUInteger queueCapacity;
@property(nonatomic, readonly) uint64_t acceptedCount;
@property(nonatomic, readonly) uint64_t prearmDiscardCount;
@property(nonatomic, readonly) uint64_t latePhaseCorrectionCount;
@property(nonatomic, readonly) uint64_t earlyPhaseCorrectionCount;
@property(nonatomic, readonly) uint64_t armedGeneration;
@property(nonatomic, readonly) uint64_t lastArmedGeneration;
@property(nonatomic, readonly) uint64_t armCount;
@property(nonatomic, readonly) uint64_t rearmCount;
@property(nonatomic, readonly) uint64_t rearmPrearmDiscardCount;
@property(nonatomic, readonly) uint64_t lateCount;
@property(nonatomic, readonly) uint64_t overflowCount;
@property(nonatomic, readonly) uint64_t generationSequenceFailureCount;
@property(nonatomic, readonly) uint64_t addedLatencyViolationCount;
@property(nonatomic, readonly) NSUInteger queueDepthHighWater;

- (nullable instancetype)initWithPresentationReserveNs:(uint64_t)reserveNs
                                        frameIntervalNs:(uint64_t)frameIntervalNs
                                          queueCapacity:(NSUInteger)queueCapacity
                                          hostTimeClock:
                                              (nullable InumaHostTimeClockBlock)hostTimeClock;
- (InumaStrictReplayPacingDecision)decisionForGeneration:(uint64_t)generation;
- (InumaStrictReplayPacerSnapshot)snapshot;
- (void)stop;
- (void)reset;

@end

@protocol InumaSampleRendererBackend <NSObject>

- (BOOL)requiresFlushToResumeDecoding;
- (void)flushRemovingDisplayedImage;
- (BOOL)readyForMoreMediaData;
- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer
                 generation:(uint64_t)generation;
- (BOOL)failed;

@optional
- (int32_t)rendererStatus;
- (int32_t)rendererErrorDomainClass;
- (int64_t)rendererErrorCode;

@end

API_AVAILABLE(macos(14.0))
@interface InumaAVSampleRendererBackend : NSObject <InumaSampleRendererBackend>

- (instancetype)initWithRenderer:(AVSampleBufferVideoRenderer*)renderer;

@end

@interface InumaBoundedPresentationTraceSink : NSObject <InumaPresentationTraceSink>

@property(nonatomic, readonly) NSUInteger capacity;
@property(nonatomic, readonly) NSUInteger count;
@property(nonatomic, readonly) NSUInteger capacityExhaustions;

- (instancetype)initWithCapacity:(NSUInteger)capacity;
- (NSArray<NSDictionary<NSString*, NSNumber*>*>*)snapshot;

@end

@interface InumaSampleRendererAdapter : NSObject

- (instancetype)initWithBackend:(id<InumaSampleRendererBackend>)backend
                           clock:(InumaMonotonicClock*)clock
                       traceSink:(nullable id<InumaPresentationTraceSink>)traceSink;
- (InumaRendererSubmissionResult)submitSampleBuffer:(CMSampleBufferRef)sampleBuffer
                                         generation:(uint64_t)generation;
- (InumaRendererSubmissionResult)submitSampleBuffer:(CMSampleBufferRef)sampleBuffer
                                            context:(InumaPresentationFrameContext)context;
- (void)stop;
- (void)reconnectWithBackend:(id<InumaSampleRendererBackend>)backend;

@end

NS_ASSUME_NONNULL_END

#endif
