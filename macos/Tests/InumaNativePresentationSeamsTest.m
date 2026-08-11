#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#import "../../common/darwin/Classes/InumaNativePresentationSeams.h"

#define INUMA_REQUIRE(condition)                                                \
  do {                                                                          \
    if (!(condition)) {                                                         \
      NSLog(@"requirement failed at %s:%d: %s", __FILE__, __LINE__, #condition); \
      return 1;                                                                 \
    }                                                                           \
  } while (0)

@interface InumaFakeSampleRendererBackend : NSObject <InumaSampleRendererBackend>

@property(nonatomic) BOOL requiresFlush;
@property(nonatomic) BOOL ready;
@property(nonatomic) BOOL failAfterEnqueue;
@property(nonatomic) uint64_t displayedGeneration;
@property(nonatomic) NSUInteger enqueueCount;
@property(nonatomic) NSMutableArray<NSString*>* events;

@end

@implementation InumaFakeSampleRendererBackend

- (instancetype)init {
  self = [super init];
  if (self) {
    _ready = YES;
    _events = [NSMutableArray array];
  }
  return self;
}

- (BOOL)requiresFlushToResumeDecoding {
  [_events addObject:@"requires_flush"];
  return _requiresFlush;
}

- (void)flushRemovingDisplayedImage {
  [_events addObject:@"flush"];
  _displayedGeneration = 0;
}

- (BOOL)readyForMoreMediaData {
  [_events addObject:@"ready"];
  return _ready;
}

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer
                 generation:(uint64_t)generation {
  NSCAssert(sampleBuffer != nil, @"sample buffer must be present");
  [_events addObject:@"enqueue"];
  _enqueueCount += 1;
  _displayedGeneration = generation;
}

- (BOOL)failed {
  [_events addObject:@"failed"];
  return _failAfterEnqueue;
}

@end

static InumaMonotonicClock* InumaTestClock(NSArray<NSNumber*>* values) {
  __block NSUInteger index = 0;
  return [[InumaMonotonicClock alloc] initWithNowBlock:^{
    const NSUInteger current = MIN(index, values.count - 1);
    index += 1;
    return values[current].unsignedLongLongValue;
  }];
}

static CMSampleBufferRef InumaTestSampleBuffer(void) {
  CVPixelBufferRef pixelBuffer = nil;
  const CVReturn created = CVPixelBufferCreate(
      kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixelBuffer);
  if (created != kCVReturnSuccess || pixelBuffer == nil) {
    return nil;
  }
  InumaVideoSampleBuilder* builder = [[InumaVideoSampleBuilder alloc] init];
  CMSampleBufferRef sampleBuffer =
      [builder copyImmediateSampleBufferFromPixelBuffer:pixelBuffer];
  CFRelease(pixelBuffer);
  return sampleBuffer;
}

int main(void) {
  @autoreleasepool {
    CMSampleBufferRef sampleBuffer = InumaTestSampleBuffer();
    INUMA_REQUIRE(sampleBuffer != nil);
    INUMA_REQUIRE(CMTIME_IS_INVALID(CMSampleBufferGetPresentationTimeStamp(
        sampleBuffer)));
    CFArrayRef attachments =
        CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, NO);
    INUMA_REQUIRE(attachments != nil && CFArrayGetCount(attachments) == 1);
    CFDictionaryRef dictionary =
        (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    INUMA_REQUIRE(CFDictionaryGetValue(
                      dictionary, kCMSampleAttachmentKey_DisplayImmediately) ==
                  kCFBooleanTrue);

    InumaBoundedPresentationTraceSink* trace =
        [[InumaBoundedPresentationTraceSink alloc] initWithCapacity:2];
    INUMA_REQUIRE(trace != nil);
    InumaFakeSampleRendererBackend* ready =
        [[InumaFakeSampleRendererBackend alloc] init];
    InumaSampleRendererAdapter* adapter = [[InumaSampleRendererAdapter alloc]
        initWithBackend:ready
                   clock:InumaTestClock(@[ @100, @110, @200, @210, @300, @310 ])
               traceSink:trace];
    InumaRendererSubmissionResult result =
        [adapter submitSampleBuffer:sampleBuffer generation:7];
    INUMA_REQUIRE(result.accepted);
    INUMA_REQUIRE(result.readyBeforeEnqueue);
    INUMA_REQUIRE(!result.flushedBeforeEnqueue);
    INUMA_REQUIRE(!result.failedAfterEnqueue);
    INUMA_REQUIRE(ready.enqueueCount == 1);
    INUMA_REQUIRE(ready.displayedGeneration == 7);
    INUMA_REQUIRE(([ready.events isEqualToArray:
        @[ @"requires_flush", @"ready", @"enqueue", @"failed" ]]));

    InumaFakeSampleRendererBackend* pressured =
        [[InumaFakeSampleRendererBackend alloc] init];
    pressured.ready = NO;
    [adapter reconnectWithBackend:pressured];
    result = [adapter submitSampleBuffer:sampleBuffer generation:8];
    INUMA_REQUIRE(result.accepted);
    INUMA_REQUIRE(!result.readyBeforeEnqueue);
    INUMA_REQUIRE(pressured.enqueueCount == 1);
    INUMA_REQUIRE(pressured.displayedGeneration == 8);

    InumaFakeSampleRendererBackend* flushed =
        [[InumaFakeSampleRendererBackend alloc] init];
    flushed.requiresFlush = YES;
    flushed.failAfterEnqueue = YES;
    flushed.displayedGeneration = 6;
    [adapter reconnectWithBackend:flushed];
    result = [adapter submitSampleBuffer:sampleBuffer generation:9];
    INUMA_REQUIRE(result.accepted);
    INUMA_REQUIRE(result.flushedBeforeEnqueue);
    INUMA_REQUIRE(result.failedAfterEnqueue);
    INUMA_REQUIRE(flushed.displayedGeneration == 9);
    INUMA_REQUIRE(([flushed.events isEqualToArray:@[
      @"requires_flush", @"flush", @"ready", @"enqueue", @"failed"
    ]]));

    INUMA_REQUIRE(trace.count == 2);
    INUMA_REQUIRE(trace.capacityExhaustions == 1);
    NSArray<NSDictionary<NSString*, NSNumber*>*>* rows = [trace snapshot];
    INUMA_REQUIRE(rows.count == 2);
    INUMA_REQUIRE([rows[0][@"generation"] unsignedLongLongValue] == 7);
    INUMA_REQUIRE([rows[0][@"started_at_ns"] unsignedLongLongValue] == 100);
    INUMA_REQUIRE([rows[0][@"completed_at_ns"] unsignedLongLongValue] == 110);
    INUMA_REQUIRE([rows[1][@"generation"] unsignedLongLongValue] == 8);
    INUMA_REQUIRE([rows[1][@"ready_before_enqueue"] boolValue] == NO);

    [adapter stop];
    const NSUInteger beforeLateCallback = flushed.enqueueCount;
    result = [adapter submitSampleBuffer:sampleBuffer generation:10];
    INUMA_REQUIRE(!result.accepted);
    INUMA_REQUIRE(flushed.enqueueCount == beforeLateCallback);

    InumaFakeSampleRendererBackend* reconnected =
        [[InumaFakeSampleRendererBackend alloc] init];
    [adapter reconnectWithBackend:reconnected];
    result = [adapter submitSampleBuffer:sampleBuffer generation:11];
    INUMA_REQUIRE(result.accepted);
    INUMA_REQUIRE(reconnected.enqueueCount == 1);
    INUMA_REQUIRE(reconnected.displayedGeneration == 11);

    [adapter stop];
    result = [adapter submitSampleBuffer:sampleBuffer generation:12];
    INUMA_REQUIRE(!result.accepted);
    INUMA_REQUIRE(reconnected.enqueueCount == 1);

    InumaNativePresentationTrace* realtimeTrace =
        [[InumaNativePresentationTrace alloc] initWithCapacity:32
                                               sessionSequence:2
                                                   startedAtNs:900];
    InumaFakeSampleRendererBackend* realtimePressured =
        [[InumaFakeSampleRendererBackend alloc] init];
    realtimePressured.ready = NO;
    InumaSampleRendererAdapter* realtimeAdapter =
        [[InumaSampleRendererAdapter alloc]
            initWithBackend:realtimePressured
                       clock:InumaTestClock(
                                 @[ @1000, @1010, @1020, @1030, @1040, @1050 ])
                   traceSink:realtimeTrace];
    InumaPresentationFrameContext firstContext = {
        .sourceIdentity = 20,
        .renderOrdinal = 20,
        .nativeGeneration = 21,
        .rtpTimestamp = 60000,
        .timingPolicy = InumaPresentationTimingImmediateInvalid,
        .sourceIdentityValid = YES,
    };
    result = [realtimeAdapter submitSampleBuffer:sampleBuffer
                                         context:firstContext];
    INUMA_REQUIRE(result.accepted && !result.readyBeforeEnqueue);
    InumaFakeSampleRendererBackend* realtimeReady =
        [[InumaFakeSampleRendererBackend alloc] init];
    [realtimeAdapter reconnectWithBackend:realtimeReady];
    InumaPresentationFrameContext secondContext = firstContext;
    secondContext.sourceIdentity = 21;
    secondContext.renderOrdinal = 21;
    secondContext.nativeGeneration = 22;
    secondContext.rtpTimestamp = 63000;
    result = [realtimeAdapter submitSampleBuffer:sampleBuffer
                                         context:secondContext];
    INUMA_REQUIRE(result.accepted && result.readyBeforeEnqueue);
    NSDictionary* realtimeSnapshot = [realtimeTrace snapshotAtNs:1100];
    NSArray* realtimeEvents = realtimeSnapshot[@"events"];
    INUMA_REQUIRE(realtimeEvents.count == 7);
    INUMA_REQUIRE([realtimeEvents[1][@"event_kind"]
        isEqualToString:@"enqueue_begin"]);
    INUMA_REQUIRE(
        [realtimeEvents[1][@"monotonic_ns"] unsignedLongLongValue] == 1000);
    INUMA_REQUIRE([realtimeEvents[2][@"event_kind"]
        isEqualToString:@"readiness_false"]);
    INUMA_REQUIRE(
        [realtimeEvents[2][@"monotonic_ns"] unsignedLongLongValue] == 1010);
    INUMA_REQUIRE([realtimeEvents[3][@"event_kind"]
        isEqualToString:@"enqueue_end"]);
    INUMA_REQUIRE(
        [realtimeEvents[3][@"monotonic_ns"] unsignedLongLongValue] == 1020);
    INUMA_REQUIRE([realtimeEvents[5][@"event_kind"]
        isEqualToString:@"readiness_true"]);
    INUMA_REQUIRE(
        [realtimeEvents[5][@"duration_ns"] unsignedLongLongValue] == 30);
    INUMA_REQUIRE(
        [realtimeEvents[6][@"monotonic_ns"] unsignedLongLongValue] == 1050);
    CFRelease(sampleBuffer);
  }
  return 0;
}
