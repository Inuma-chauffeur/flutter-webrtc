// Deterministic lifecycle, interval, privacy, and ring tests for trace v2.

#import <Foundation/Foundation.h>

#include <string.h>

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

static uint16_t InumaTestProductChecksum(const uint8_t* bytes) {
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

static void InumaTestWriteUint32(uint8_t* bytes, NSUInteger offset,
                                 uint32_t value) {
  bytes[offset] = (uint8_t)(value >> 24);
  bytes[offset + 1] = (uint8_t)(value >> 16);
  bytes[offset + 2] = (uint8_t)(value >> 8);
  bytes[offset + 3] = (uint8_t)value;
}

static BOOL InumaTestWriteProductWatermark(CVPixelBufferRef pixelBuffer,
                                           uint32_t identity,
                                           BOOL corruptChecksum) {
  if (pixelBuffer == nil) return NO;
  const OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
  const BOOL bgra = format == kCVPixelFormatType_32BGRA;
  const BOOL nv12 = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
  if (!bgra && !nv12) return NO;
  if (CVPixelBufferLockBaseAddress(pixelBuffer, 0) != kCVReturnSuccess) return NO;
  uint8_t* base = nv12 ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
                       : CVPixelBufferGetBaseAddress(pixelBuffer);
  const size_t stride =
      nv12 ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
           : CVPixelBufferGetBytesPerRow(pixelBuffer);
  const size_t width =
      nv12 ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
           : CVPixelBufferGetWidth(pixelBuffer);
  const size_t height =
      nv12 ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
           : CVPixelBufferGetHeight(pixelBuffer);
  for (size_t y = 0; y < height; y++) {
    uint8_t* row = base + y * stride;
    if (bgra) {
      for (size_t x = 0; x < width; x++) {
        row[x * 4] = 80;
        row[x * 4 + 1] = 80;
        row[x * 4 + 2] = 80;
        row[x * 4 + 3] = 255;
      }
    } else {
      memset(row, 80, width);
    }
  }
  uint8_t bytes[16] = {0xDD, 0xAB};
  InumaTestWriteUint32(bytes, 2, identity);
  InumaTestWriteUint32(bytes, 6, 1000000 + identity * 33333);
  InumaTestWriteUint32(bytes, 10, 1010000 + identity * 33333);
  const uint16_t checksum = InumaTestProductChecksum(bytes);
  bytes[14] = (uint8_t)(checksum >> 8);
  bytes[15] = (uint8_t)checksum;
  if (corruptChecksum) bytes[15] ^= 1;
  for (NSUInteger bit = 0; bit < 128; bit++) {
    const uint8_t value =
        (bytes[bit / 8] & (uint8_t)(0x80 >> (bit % 8))) != 0 ? 235 : 16;
    const NSUInteger column = bit % 16;
    const NSUInteger markerRow = bit / 16;
    for (NSUInteger y = 96 + markerRow * 12;
         y < 96 + (markerRow + 1) * 12; y++) {
      uint8_t* row = base + y * stride;
      for (NSUInteger x = 128 + column * 6;
           x < 128 + (column + 1) * 6; x++) {
        if (bgra) {
          row[x * 4] = value;
          row[x * 4 + 1] = value;
          row[x * 4 + 2] = value;
          row[x * 4 + 3] = 255;
        } else {
          row[x] = value;
        }
      }
    }
  }
  CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
  return YES;
}

static CVPixelBufferRef InumaTestProductPixelBuffer(OSType format,
                                                     uint32_t identity,
                                                     BOOL corruptChecksum) {
  CVPixelBufferRef pixelBuffer = nil;
  NSDictionary* attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
  const CVReturn result = CVPixelBufferCreate(
      kCFAllocatorDefault, 320, 240, format,
      (__bridge CFDictionaryRef)attributes, &pixelBuffer);
  if (result != kCVReturnSuccess || pixelBuffer == nil ||
      !InumaTestWriteProductWatermark(pixelBuffer, identity, corruptChecksum)) {
    if (pixelBuffer != nil) CVPixelBufferRelease(pixelBuffer);
    return nil;
  }
  return pixelBuffer;
}

static CVPixelBufferRef InumaTestSmallPixelBuffer(void) {
  CVPixelBufferRef pixelBuffer = nil;
  const CVReturn result = CVPixelBufferCreate(
      kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixelBuffer);
  return result == kCVReturnSuccess ? pixelBuffer : nil;
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

    InumaNativePresentationTrace* armedPhase =
        [[InumaNativePresentationTrace alloc] initWithCapacity:8
                                               sessionSequence:10
                                                   startedAtNs:1500];
    [armedPhase recordEventKind:InumaPresentationEventPacingPrearmDiscarded
                           atNs:1510
                        context:first
                      durationNs:0
                            value:1];
    [armedPhase recordEventKind:InumaPresentationEventPacingLatePhaseCorrected
                           atNs:1520
                        context:second
                      durationNs:95000000
                            value:2];
    [armedPhase recordEventKind:InumaPresentationEventPacingEarlyPhaseCorrected
                           atNs:1530
                        context:second
                      durationNs:90000000
                            value:2];
    snapshot = [armedPhase snapshotAtNs:1540];
    INUMA_REQUIRE(InumaEventCount(snapshot, @"pacing_prearm_discarded") == 1);
    INUMA_REQUIRE(InumaEventCount(snapshot, @"pacing_late_phase_corrected") == 1);
    INUMA_REQUIRE(InumaEventCount(snapshot, @"pacing_early_phase_corrected") == 1);
    events = snapshot[@"events"];
    INUMA_REQUIRE([events[1][@"event_kind"]
        isEqualToString:@"pacing_prearm_discarded"]);
    INUMA_REQUIRE([events[2][@"event_kind"]
        isEqualToString:@"pacing_late_phase_corrected"]);
    INUMA_REQUIRE([events[3][@"event_kind"]
        isEqualToString:@"pacing_early_phase_corrected"]);

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

    InumaDisplayedFrameIdentityLedger* identity =
        [[InumaDisplayedFrameIdentityLedger alloc] initWithCapacity:2];
    INUMA_REQUIRE(identity != nil && identity.capacity == 2);
    CVPixelBufferRef reused = InumaTestProductPixelBuffer(
        kCVPixelFormatType_32BGRA, (uint32_t)first.sourceIdentity, NO);
    CVPixelBufferRef nv12 = InumaTestProductPixelBuffer(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        (uint32_t)second.sourceIdentity, NO);
    CVPixelBufferRef corrupt = InumaTestProductPixelBuffer(
        kCVPixelFormatType_32BGRA, (uint32_t)first.sourceIdentity, YES);
    CVPixelBufferRef tooSmall = InumaTestSmallPixelBuffer();
    INUMA_REQUIRE(reused != nil && nv12 != nil && corrupt != nil &&
                  tooSmall != nil);
    InumaProductWatermarkIdentity decoded = {0};
    INUMA_REQUIRE(InumaDecodeProductWatermark(reused, &decoded) ==
                  InumaDisplayedFrameIdentityLookupFound);
    INUMA_REQUIRE(decoded.frameIdentity == first.sourceIdentity);
    INUMA_REQUIRE(InumaDecodeProductWatermark(nv12, &decoded) ==
                  InumaDisplayedFrameIdentityLookupFound);
    INUMA_REQUIRE(decoded.frameIdentity == second.sourceIdentity);
    INUMA_REQUIRE(InumaDecodeProductWatermark(corrupt, &decoded) ==
                  InumaDisplayedFrameIdentityLookupChecksumMismatch);
    INUMA_REQUIRE(InumaDecodeProductWatermark(tooSmall, &decoded) ==
                  InumaDisplayedFrameIdentityLookupGeometryInvalid);
    InumaPresentationFrameContext observed = {0};
    INUMA_REQUIRE([identity registerContext:first]);
    INUMA_REQUIRE(
        [identity lookupContextForDisplayedPixelBuffer:reused context:&observed] ==
        InumaDisplayedFrameIdentityLookupFound);
    INUMA_REQUIRE(observed.nativeGeneration == 1);

    // Reusing the exact same CVPixelBuffer with a different watermark must
    // resolve by decoded scalar identity, never by pointer identity.
    INUMA_REQUIRE([identity registerContext:second]);
    INUMA_REQUIRE(InumaTestWriteProductWatermark(
        reused, (uint32_t)second.sourceIdentity, NO));
    observed = (InumaPresentationFrameContext){0};
    INUMA_REQUIRE(
        [identity lookupContextForDisplayedPixelBuffer:reused context:&observed] ==
        InumaDisplayedFrameIdentityLookupFound);
    INUMA_REQUIRE(observed.nativeGeneration == 2);

    observed = (InumaPresentationFrameContext){0};
    INUMA_REQUIRE([identity lookupContextForDisplayedPixelBuffer:nv12
                                                     context:&observed] ==
                  InumaDisplayedFrameIdentityLookupFound);
    INUMA_REQUIRE(observed.nativeGeneration == 2);
    INUMA_REQUIRE([identity lookupContextForDisplayedPixelBuffer:corrupt
                                                     context:&observed] ==
                  InumaDisplayedFrameIdentityLookupChecksumMismatch);

    InumaDisplayedFrameIdentityLedger* bounded =
        [[InumaDisplayedFrameIdentityLedger alloc] initWithCapacity:1];
    CVPixelBufferRef evicted = InumaTestProductPixelBuffer(
        kCVPixelFormatType_32BGRA, (uint32_t)first.sourceIdentity, NO);
    CVPixelBufferRef current = InumaTestProductPixelBuffer(
        kCVPixelFormatType_32BGRA, (uint32_t)second.sourceIdentity, NO);
    INUMA_REQUIRE(evicted != nil && current != nil);
    INUMA_REQUIRE([bounded registerContext:first]);
    INUMA_REQUIRE([bounded registerContext:second]);
    observed = (InumaPresentationFrameContext){0};
    INUMA_REQUIRE([bounded lookupContextForDisplayedPixelBuffer:evicted
                                                    context:&observed] ==
                  InumaDisplayedFrameIdentityLookupContextMissing);
    InumaPresentationFrameContext invalid = first;
    invalid.sourceIdentityValid = NO;
    INUMA_REQUIRE(![bounded registerContext:invalid]);
    CVPixelBufferRelease(reused);
    CVPixelBufferRelease(nv12);
    CVPixelBufferRelease(corrupt);
    CVPixelBufferRelease(tooSmall);
    CVPixelBufferRelease(evicted);
    CVPixelBufferRelease(current);
  }
  return 0;
}
