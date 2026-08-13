// Deterministic crash-safe segmented scalar-evidence writer contract test.

#import <Foundation/Foundation.h>

#import "../../common/darwin/Classes/InumaSegmentedScalarEvidenceWriter.h"

#define INUMA_REQUIRE(condition) if (!(condition)) return 1

int main(void) {
  @autoreleasepool {
    NSString* root = [NSTemporaryDirectory()
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    INUMA_REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:root
                                            withIntermediateDirectories:YES
                                                             attributes:@{
                                                               NSFilePosixPermissions : @0700
                                                             }
                                                                  error:nil]);
    NSString* manifest = [root stringByAppendingPathComponent:
        @"flutter-webrtc-texture-trace.json"];
    InumaSegmentedScalarEvidenceWriter* writer =
        [[InumaSegmentedScalarEvidenceWriter alloc]
            initWithManifestPath:manifest
                 sessionSequence:7
               traceStartedAtNs:1000
                segmentIntervalNs:5000000000];
    INUMA_REQUIRE(writer != nil);
    NSDictionary* payload = @{
      @"surface_trace" : @{},
      @"presentation_trace_v2" : @{},
      @"decoder_boundary_trace" : @{},
      @"receiver_scheduler_trace" : @{},
    };
    INUMA_REQUIRE([writer writeSegment:payload
                           startedAtNs:1000
                             endedAtNs:2000
                     snapshotWallTimeNs:3000
                              terminal:NO]);
    INUMA_REQUIRE([writer writeSegment:payload
                           startedAtNs:2000
                             endedAtNs:3000
                     snapshotWallTimeNs:4000
                              terminal:YES]);
    NSData* data = [NSData dataWithContentsOfFile:manifest];
    NSDictionary* report = [NSJSONSerialization JSONObjectWithData:data
                                                           options:0
                                                             error:nil];
    INUMA_REQUIRE([report[@"status"] isEqualToString:@"pass"]);
    INUMA_REQUIRE([report[@"segment_count"] unsignedIntegerValue] == 2);
    INUMA_REQUIRE([report[@"terminal"] boolValue]);
    INUMA_REQUIRE(writer.writeFailureCount == 0);
    NSArray* entries = report[@"segments"];
    INUMA_REQUIRE([entries[1][@"previous_sha256"]
        isEqualToString:entries[0][@"sha256"]]);
    INUMA_REQUIRE([[NSFileManager defaultManager] removeItemAtPath:root error:nil]);
  }
  return 0;
}
