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

static InumaHostTimeClockBlock InumaTestHostClock(NSArray<NSNumber*>* values) {
  __block NSUInteger index = 0;
  return ^uint64_t {
    const NSUInteger current = MIN(index, values.count - 1);
    index += 1;
    return values[current].unsignedLongLongValue;
  };
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

    CVPixelBufferRef timedPixelBuffer = nil;
    INUMA_REQUIRE(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2,
                                     kCVPixelFormatType_32BGRA, nil,
                                     &timedPixelBuffer) == kCVReturnSuccess);
    InumaVideoSampleBuilder* timedBuilder = [[InumaVideoSampleBuilder alloc] init];
    CMSampleBufferRef timedSample =
        [timedBuilder copyTimedSampleBufferFromPixelBuffer:timedPixelBuffer
                                        presentationTimeNs:1234567890
                                             durationNs:33333333];
    CFRelease(timedPixelBuffer);
    INUMA_REQUIRE(timedSample != nil);
    INUMA_REQUIRE(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(timedSample),
                                CMTimeMake(1234567890, 1000000000)) == 0);
    INUMA_REQUIRE(CMTimeCompare(CMSampleBufferGetDuration(timedSample),
                                CMTimeMake(33333333, 1000000000)) == 0);
    attachments = CMSampleBufferGetSampleAttachmentsArray(timedSample, NO);
    dictionary = attachments == nil || CFArrayGetCount(attachments) == 0
                     ? nil
                     : (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    INUMA_REQUIRE(dictionary == nil ||
                  CFDictionaryGetValue(
                      dictionary, kCMSampleAttachmentKey_DisplayImmediately) ==
                      nil);
    CFRelease(timedSample);
    const uint64_t capturedIntervalsNs[] = {
        672750,    7485750,   17602334,  17403666,  17335542,
        17122458,  16888209,  27349000,  32797000,  32931000,
        37670000,  33333333,  126450083, 14404667,  17750916,
        16877417,  18127583,  17315584,  17655083,  33333333,
        73997875,  15104084,  17542208,  33333333,  94433750,
        14767375,  17473833,  15954625,  33333333,  89242125,
        15558500,  15554583,  16553125,  33333333,
    };
    NSMutableArray<NSNumber*>* capturedTimes = [NSMutableArray array];
    uint64_t capturedTimeNs = 1000000000;
    [capturedTimes addObject:@(capturedTimeNs)];
    for (NSUInteger index = 0;
         index < sizeof(capturedIntervalsNs) / sizeof(capturedIntervalsNs[0]);
         index++) {
      capturedTimeNs += capturedIntervalsNs[index];
      [capturedTimes addObject:@(capturedTimeNs)];
    }
    InumaStrictReplayPacer* paced = [[InumaStrictReplayPacer alloc]
        initWithPresentationReserveNs:95000000
                       frameIntervalNs:33333333
                         queueCapacity:4
                         hostTimeClock:InumaTestHostClock(capturedTimes)];
    INUMA_REQUIRE(paced != nil);
    INUMA_REQUIRE(paced.minimumPresentationIntervalNs == 25000000);
    INUMA_REQUIRE(paced.maximumPresentationIntervalNs == 49999999);
    INUMA_REQUIRE(paced.minimumPresentationLeadNs == 8333333);
    INUMA_REQUIRE(paced.stableCadenceIntervalMinimumNs == 25000000);
    INUMA_REQUIRE(paced.stableCadenceIntervalMaximumNs == 42000000);
    INUMA_REQUIRE(paced.requiredStableCadenceIntervals == 3);
    InumaStrictReplayPacingDecision pace = {0};
    uint64_t previousPresentationTimeNs = 0;
    uint64_t minimumPresentationIntervalNs = UINT64_MAX;
    uint64_t maximumPresentationIntervalNs = 0;
    for (uint64_t generation = 1; generation <= capturedTimes.count;
         generation++) {
      pace = [paced decisionForGeneration:generation];
      INUMA_REQUIRE(pace.generationSequenceValid);
      if (generation <= 10) {
        INUMA_REQUIRE(!pace.accepted && pace.prearmDiscarded);
        INUMA_REQUIRE(!pace.timelineStarted);
        continue;
      }
      INUMA_REQUIRE(pace.accepted && !pace.prearmDiscarded);
      INUMA_REQUIRE(!pace.late && !pace.overflowed &&
                    !pace.addedLatencyExceeded);
      INUMA_REQUIRE(pace.presentationResidenceNs > 0 &&
                    pace.presentationResidenceNs <= 100000000);
      if (generation == 11) {
        INUMA_REQUIRE(pace.timelineStarted);
        INUMA_REQUIRE(pace.presentationResidenceNs == 95000000);
      } else {
        const uint64_t intervalNs =
            pace.scheduledPresentationTimeNs - previousPresentationTimeNs;
        minimumPresentationIntervalNs =
            MIN(minimumPresentationIntervalNs, intervalNs);
        maximumPresentationIntervalNs =
            MAX(maximumPresentationIntervalNs, intervalNs);
        INUMA_REQUIRE(intervalNs >= 25000000 && intervalNs < 50000000);
      }
      previousPresentationTimeNs = pace.scheduledPresentationTimeNs;
    }
    INUMA_REQUIRE(paced.armedGeneration == 11);
    INUMA_REQUIRE(paced.prearmDiscardCount == 10);
    INUMA_REQUIRE(paced.acceptedCount == capturedTimes.count - 10);
    INUMA_REQUIRE(paced.queueDepthHighWater == 4);
    INUMA_REQUIRE(paced.latePhaseCorrectionCount == 1);
    INUMA_REQUIRE(paced.earlyPhaseCorrectionCount == 1);
    INUMA_REQUIRE(minimumPresentationIntervalNs == 27131252);
    INUMA_REQUIRE(maximumPresentationIntervalNs == 44120083);
    INUMA_REQUIRE(paced.lateCount == 0 && paced.overflowCount == 0 &&
                  paced.generationSequenceFailureCount == 0 &&
                  paced.addedLatencyViolationCount == 0);
    const InumaStrictReplayPacerSnapshot pacedSnapshot = [paced snapshot];
    INUMA_REQUIRE(pacedSnapshot.armedGeneration == 11);
    INUMA_REQUIRE(pacedSnapshot.lastArmedGeneration == 11);
    INUMA_REQUIRE(pacedSnapshot.armCount == 1);
    INUMA_REQUIRE(pacedSnapshot.rearmCount == 0);
    INUMA_REQUIRE(pacedSnapshot.rearmPrearmDiscardCount == 0);
    INUMA_REQUIRE(pacedSnapshot.prearmDiscardCount == 10);
    INUMA_REQUIRE(pacedSnapshot.acceptedCount == capturedTimes.count - 10);
    INUMA_REQUIRE(pacedSnapshot.queueDepthHighWater == 4);
    INUMA_REQUIRE(pacedSnapshot.latePhaseCorrectionCount == 1);
    INUMA_REQUIRE(pacedSnapshot.earlyPhaseCorrectionCount == 1);
    INUMA_REQUIRE(pacedSnapshot.lateCount == 0 &&
                  pacedSnapshot.overflowCount == 0 &&
                  pacedSnapshot.generationSequenceFailureCount == 0 &&
                  pacedSnapshot.addedLatencyViolationCount == 0);

    InumaStrictReplayPacer* late = [[InumaStrictReplayPacer alloc]
        initWithPresentationReserveNs:95000000
                       frameIntervalNs:33333333
                         queueCapacity:4
                         hostTimeClock:InumaTestHostClock(@[
                           @1000000000,
                           @1033333333,
                           @1066666666,
                           @1099999999,
                           @1299999999,
                           @1333333332,
                           @1366666665,
                           @1399999998,
                           @1433333331,
                         ])];
    for (uint64_t generation = 1; generation <= 4; generation++) {
      pace = [late decisionForGeneration:generation];
    }
    INUMA_REQUIRE(pace.accepted && pace.timelineStarted);
    pace = [late decisionForGeneration:5];
    INUMA_REQUIRE(!pace.accepted && pace.late && pace.rearmTriggered);
    INUMA_REQUIRE(pace.latenessNs > 0);
    INUMA_REQUIRE(late.lateCount == 1);
    for (uint64_t generation = 6; generation <= 7; generation++) {
      pace = [late decisionForGeneration:generation];
      INUMA_REQUIRE(!pace.accepted && pace.prearmDiscarded &&
                    pace.rearmPrearmDiscarded && !pace.rearmTriggered);
    }
    pace = [late decisionForGeneration:8];
    INUMA_REQUIRE(pace.accepted && pace.timelineStarted &&
                  pace.timelineRearmed && !pace.prearmDiscarded);
    const uint64_t rearmedPresentationTimeNs =
        pace.scheduledPresentationTimeNs;
    pace = [late decisionForGeneration:9];
    INUMA_REQUIRE(pace.accepted && !pace.timelineStarted &&
                  !pace.timelineRearmed);
    INUMA_REQUIRE(pace.scheduledPresentationTimeNs -
                      rearmedPresentationTimeNs ==
                  33333333);
    INUMA_REQUIRE(late.armedGeneration == 4);
    INUMA_REQUIRE(late.lastArmedGeneration == 8);
    INUMA_REQUIRE(late.armCount == 2);
    INUMA_REQUIRE(late.rearmCount == 1);
    INUMA_REQUIRE(late.rearmPrearmDiscardCount == 2);
    INUMA_REQUIRE(late.prearmDiscardCount == 5);
    INUMA_REQUIRE(late.acceptedCount == 3);

    InumaStrictReplayPacer* overflow = [[InumaStrictReplayPacer alloc]
        initWithPresentationReserveNs:95000000
                       frameIntervalNs:33333333
                         queueCapacity:1
                         hostTimeClock:InumaTestHostClock(@[
                           @1000000000,
                           @1033333333,
                           @1066666666,
                           @1099999999,
                           @1133333332,
                         ])];
    for (uint64_t generation = 1; generation <= 4; generation++) {
      pace = [overflow decisionForGeneration:generation];
    }
    INUMA_REQUIRE(pace.accepted);
    pace = [overflow decisionForGeneration:5];
    INUMA_REQUIRE(!pace.accepted && pace.overflowed && pace.rearmTriggered);
    INUMA_REQUIRE(overflow.overflowCount == 1);
    INUMA_REQUIRE(overflow.rearmCount == 1);

    InumaStrictReplayPacer* sequence = [[InumaStrictReplayPacer alloc]
        initWithPresentationReserveNs:95000000
                       frameIntervalNs:33333333
                         queueCapacity:4
                         hostTimeClock:InumaTestHostClock(@[
                           @1000000000,
                           @1033333333,
                           @1066666666,
                           @1099999999,
                           @1133333332,
                           @1166666665,
                           @1199999998,
                           @1233333331,
                           @1266666664,
                         ])];
    for (uint64_t generation = 7; generation <= 10; generation++) {
      pace = [sequence decisionForGeneration:generation];
    }
    INUMA_REQUIRE(pace.accepted && sequence.armedGeneration == 10);
    pace = [sequence decisionForGeneration:12];
    INUMA_REQUIRE(!pace.accepted && !pace.generationSequenceValid &&
                  pace.rearmTriggered);
    INUMA_REQUIRE(sequence.generationSequenceFailureCount == 1);
    for (uint64_t generation = 13; generation <= 14; generation++) {
      pace = [sequence decisionForGeneration:generation];
      INUMA_REQUIRE(!pace.accepted && pace.prearmDiscarded &&
                    pace.rearmPrearmDiscarded && pace.generationSequenceValid);
    }
    pace = [sequence decisionForGeneration:15];
    INUMA_REQUIRE(pace.accepted && pace.generationSequenceValid &&
                  pace.timelineRearmed);
    pace = [sequence decisionForGeneration:16];
    INUMA_REQUIRE(pace.accepted && pace.generationSequenceValid);
    INUMA_REQUIRE(sequence.generationSequenceFailureCount == 1);
    INUMA_REQUIRE(sequence.rearmCount == 1);
    INUMA_REQUIRE(sequence.rearmPrearmDiscardCount == 2);
    [sequence stop];
    INUMA_REQUIRE(![sequence decisionForGeneration:17].accepted);
    [sequence reset];
    pace = [sequence decisionForGeneration:20];
    INUMA_REQUIRE(!pace.accepted && pace.prearmDiscarded);
    INUMA_REQUIRE([[InumaStrictReplayPacer alloc]
        initWithPresentationReserveNs:100000001
                       frameIntervalNs:33333333
                         queueCapacity:4
                         hostTimeClock:nil] == nil);

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
