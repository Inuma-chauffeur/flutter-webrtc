// Deterministic lifecycle, interval, privacy, and ring tests for trace v2.

#import <Foundation/Foundation.h>

#import "../../common/darwin/Classes/InumaNativePresentationTrace.h"

#define INUMA_REQUIRE(condition)                                                \
  do {                                                                          \
    if (!(condition)) {                                                         \
      NSLog(@"requirement failed at %s:%d: %s", __FILE__, __LINE__, #condition); \
      return 1;                                                                 \
    }                                                                           \
  } while (0)

static InumaPresentationFrameContext InumaContext(uint64_t generation) {
  InumaPresentationFrameContext context = {0};
  context.sourceIdentity = generation + 99;
  context.sourceIdentityValid = YES;
  context.renderOrdinal = generation - 1;
  context.nativeGeneration = generation;
  context.rtpTimestamp = generation * 3000;
  context.pendingAgeNs = 700;
  context.timingPolicy = InumaPresentationTimingImmediateInvalid;
  return context;
}

static uint64_t InumaEventCount(NSDictionary* snapshot, NSString* name) {
  return [snapshot[@"event_counts"][name] unsignedLongLongValue];
}

int main(void) {
  @autoreleasepool {
    InumaNativePresentationTrace* trace = [[InumaNativePresentationTrace alloc]
        initWithCapacity:32
         sessionSequence:7
             startedAtNs:1000];
    INUMA_REQUIRE(trace != nil);
    InumaPresentationFrameContext first = InumaContext(1);
    [trace recordEventKind:InumaPresentationEventRenderReceived
                      atNs:1010
                   context:first
                 durationNs:0
                       value:0];
    InumaRendererSubmissionResult pressured = {
        .accepted = YES,
        .readyBeforeEnqueue = NO,
        .rendererStatusBeforeEnqueue = 1,
        .rendererStatusAfterEnqueue = 1,
    };
    [trace recordContext:first
              startedAtNs:1020
            completedAtNs:1030
                   result:pressured];
    InumaPresentationFrameContext second = InumaContext(2);
    InumaRendererSubmissionResult ready = {
        .accepted = YES,
        .readyBeforeEnqueue = YES,
        .rendererStatusBeforeEnqueue = 1,
        .rendererStatusAfterEnqueue = 1,
    };
    [trace recordContext:second
              startedAtNs:1050
            completedAtNs:1060
                   result:ready];
    NSDictionary* snapshot = [trace snapshotAtNs:1100];
    INUMA_REQUIRE([snapshot[@"status"] isEqualToString:@"pass"]);
    INUMA_REQUIRE([snapshot[@"session_sequence"] unsignedLongLongValue] == 7);
    INUMA_REQUIRE([snapshot[@"readiness_intervals_opened"] unsignedLongLongValue] ==
                  1);
    INUMA_REQUIRE(
        [snapshot[@"readiness_intervals_closed_ready"] unsignedLongLongValue] ==
        1);
    INUMA_REQUIRE([snapshot[@"readiness_total_duration_ns"] unsignedLongLongValue] ==
                  30);
    INUMA_REQUIRE([snapshot[@"readiness_interval_open"] boolValue] == NO);
    INUMA_REQUIRE(InumaEventCount(snapshot, @"session_start") == 1);
    INUMA_REQUIRE(InumaEventCount(snapshot, @"render_received") == 1);
    INUMA_REQUIRE(InumaEventCount(snapshot, @"enqueue_begin") == 2);
    INUMA_REQUIRE(InumaEventCount(snapshot, @"enqueue_end") == 2);
    INUMA_REQUIRE(InumaEventCount(snapshot, @"readiness_false") == 1);
    INUMA_REQUIRE(InumaEventCount(snapshot, @"readiness_true") == 1);
    NSArray* events = snapshot[@"events"];
    INUMA_REQUIRE(events.count == trace.totalEventCount);
    for (NSUInteger index = 0; index < events.count; index++) {
      INUMA_REQUIRE([events[index][@"event_sequence"] unsignedLongLongValue] ==
                    index + 1);
    }
    NSDictionary* render = events[1];
    INUMA_REQUIRE([render[@"source_identity"] unsignedLongLongValue] == 100);
    INUMA_REQUIRE([render[@"source_identity_valid"] boolValue] == YES);
    INUMA_REQUIRE([render[@"render_ordinal"] unsignedLongLongValue] == 0);
    INUMA_REQUIRE([render[@"native_generation"] unsignedLongLongValue] == 1);
    INUMA_REQUIRE([render[@"rtp_timestamp"] unsignedLongLongValue] == 3000);
    INUMA_REQUIRE([render[@"timing_policy"] isEqualToString:@"immediate_invalid"]);
    INUMA_REQUIRE([render[@"session_sequence"] unsignedLongLongValue] == 7);
    INUMA_REQUIRE([render[@"monotonic_ns"] unsignedLongLongValue] == 1010);
    INUMA_REQUIRE([snapshot[@"serialized_pixel_payload_bytes"] unsignedLongLongValue]
                  == 0);
    INUMA_REQUIRE([snapshot[@"pointer_values_retained"] boolValue] == NO);
    INUMA_REQUIRE([snapshot[@"hot_path_filesystem_writes"] unsignedLongLongValue]
                  == 0);

    InumaNativePresentationTrace* shutdown =
        [[InumaNativePresentationTrace alloc] initWithCapacity:16
                                               sessionSequence:8
                                                   startedAtNs:2000];
    [shutdown recordContext:first
                startedAtNs:2010
              completedAtNs:2020
                     result:pressured];
    [shutdown closeOpenIntervalsAtNs:2070 context:first];
    snapshot = [shutdown snapshotAtNs:2080];
    INUMA_REQUIRE(
        [snapshot[@"readiness_intervals_closed_shutdown"] unsignedLongLongValue]
        == 1);
    INUMA_REQUIRE([snapshot[@"readiness_total_duration_ns"] unsignedLongLongValue]
                  == 60);
    INUMA_REQUIRE(InumaEventCount(snapshot, @"readiness_closed_at_shutdown") ==
                  1);

    InumaNativePresentationTrace* ring = [[InumaNativePresentationTrace alloc]
        initWithCapacity:3
         sessionSequence:9
             startedAtNs:3000];
    for (uint64_t index = 0; index < 5; index++) {
      [ring recordEventKind:InumaPresentationEventPendingSet
                       atNs:3010 + index
                    context:first
                  durationNs:0
                        value:index];
    }
    snapshot = [ring snapshotAtNs:3100];
    INUMA_REQUIRE([snapshot[@"retained_event_count"] unsignedLongLongValue] == 3);
    INUMA_REQUIRE([snapshot[@"total_event_count"] unsignedLongLongValue] == 6);
    INUMA_REQUIRE([snapshot[@"overwritten_event_count"] unsignedLongLongValue] ==
                  3);
    INUMA_REQUIRE(
        [snapshot[@"first_retained_event_sequence"] unsignedLongLongValue] == 4);
    INUMA_REQUIRE(
        [snapshot[@"last_retained_event_sequence"] unsignedLongLongValue] == 6);
    INUMA_REQUIRE([snapshot[@"capacity_exhaustions"] unsignedLongLongValue] == 0);
  }
  return 0;
}
