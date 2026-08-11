#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

#import "InumaNativePresentationTrace.h"

#if TARGET_OS_OSX

NS_ASSUME_NONNULL_BEGIN

typedef uint64_t (^InumaMonotonicClockBlock)(void);

@interface InumaMonotonicClock : NSObject

- (instancetype)initWithNowBlock:(InumaMonotonicClockBlock)nowBlock;
- (uint64_t)nowNanoseconds;
+ (instancetype)systemClock;

@end

@interface InumaVideoSampleBuilder : NSObject

- (nullable CMSampleBufferRef)copyImmediateSampleBufferFromPixelBuffer:
    (CVPixelBufferRef)pixelBuffer CF_RETURNS_RETAINED;

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
