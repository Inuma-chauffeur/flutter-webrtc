// Crash-safe immutable scalar-evidence writer implementation.

#import "InumaSegmentedScalarEvidenceWriter.h"

#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#if TARGET_OS_OSX

static NSString* const kInumaSegmentManifestSchema =
    @"inuma.flutter_webrtc.macos_native_video_surface_trace.v11";
static NSString* const kInumaSegmentSchema =
    @"inuma.flutter_webrtc.macos_native_video_surface_segment.v1";
static NSString* const kInumaScalarPayloadPolicy =
    @"scalar_timing_and_counts_only_no_media_payloads";

static NSString* InumaSHA256(NSData* data) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString* value = [NSMutableString stringWithCapacity:64];
  for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
    [value appendFormat:@"%02x", digest[index]];
  }
  return value;
}

static BOOL InumaWriteAll(int descriptor, NSData* data) {
  const uint8_t* bytes = data.bytes;
  size_t remaining = data.length;
  while (remaining > 0) {
    const ssize_t written = write(descriptor, bytes, remaining);
    if (written <= 0) return NO;
    bytes += written;
    remaining -= (size_t)written;
  }
  return fsync(descriptor) == 0;
}

@implementation InumaSegmentedScalarEvidenceWriter {
  NSString* _manifestPath;
  NSString* _directoryPath;
  uint64_t _sessionSequence;
  uint64_t _traceStartedAtNs;
  uint64_t _segmentIntervalNs;
  uint64_t _totalSegmentBytes;
  uint64_t _writeFailureCount;
  BOOL _terminalWritten;
  NSMutableArray<NSDictionary<NSString*, id>*>* _entries;
}

- (instancetype)initWithManifestPath:(NSString*)manifestPath
                      sessionSequence:(uint64_t)sessionSequence
                    traceStartedAtNs:(uint64_t)traceStartedAtNs
                     segmentIntervalNs:(uint64_t)segmentIntervalNs {
  if (manifestPath.length == 0 || sessionSequence == 0 ||
      traceStartedAtNs == 0 || segmentIntervalNs == 0) {
    return nil;
  }
  self = [super init];
  if (self) {
    _manifestPath = [manifestPath copy];
    _directoryPath = [_manifestPath stringByDeletingLastPathComponent];
    _sessionSequence = sessionSequence;
    _traceStartedAtNs = traceStartedAtNs;
    _segmentIntervalNs = segmentIntervalNs;
    _entries = [NSMutableArray array];
  }
  return self;
}

- (BOOL)writeOwnerOnlyFileAtPath:(NSString*)path data:(NSData*)data {
  const int descriptor = open(path.fileSystemRepresentation,
                              O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC |
                                  O_NOFOLLOW,
                              S_IRUSR | S_IWUSR);
  if (descriptor < 0) return NO;
  const BOOL accepted = InumaWriteAll(descriptor, data);
  const BOOL closeAccepted = close(descriptor) == 0;
  if (!accepted || !closeAccepted) {
    unlink(path.fileSystemRepresentation);
    return NO;
  }
  return YES;
}

- (BOOL)replaceManifestData:(NSData*)data {
  NSString* temporary = [_manifestPath stringByAppendingFormat:@".tmp-%u",
                                                           arc4random()];
  if (![self writeOwnerOnlyFileAtPath:temporary data:data]) return NO;
  if (rename(temporary.fileSystemRepresentation,
             _manifestPath.fileSystemRepresentation) != 0) {
    unlink(temporary.fileSystemRepresentation);
    return NO;
  }
  const int directory = open(_directoryPath.fileSystemRepresentation,
                             O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
  if (directory < 0) return NO;
  const BOOL syncAccepted = fsync(directory) == 0;
  const BOOL closeAccepted = close(directory) == 0;
  return syncAccepted && closeAccepted;
}

- (BOOL)writeSegment:(NSDictionary<NSString*, id>*)segmentPayload
          startedAtNs:(uint64_t)startedAtNs
            endedAtNs:(uint64_t)endedAtNs
    snapshotWallTimeNs:(uint64_t)snapshotWallTimeNs
             terminal:(BOOL)terminal {
  const uint64_t expectedStart =
      _entries.count == 0
          ? _traceStartedAtNs
          : [_entries.lastObject[@"ended_monotonic_ns"] unsignedLongLongValue];
  if (_writeFailureCount != 0 || _terminalWritten || startedAtNs == 0 ||
      startedAtNs != expectedStart ||
      endedAtNs < startedAtNs || snapshotWallTimeNs == 0 ||
      ![NSJSONSerialization isValidJSONObject:segmentPayload]) {
    _writeFailureCount += 1;
    return NO;
  }
  const NSUInteger sequence = _entries.count + 1;
  const NSString* previous = sequence == 1
                                 ? [@"" stringByPaddingToLength:64
                                                         withString:@"0"
                                                    startingAtIndex:0]
                                 : _entries.lastObject[@"sha256"];
  NSDictionary* segment = @{
    @"schema" : kInumaSegmentSchema,
    @"status" : @"pass",
    @"session_sequence" : @(_sessionSequence),
    @"sequence" : @(sequence),
    @"previous_sha256" : previous,
    @"started_monotonic_ns" : @(startedAtNs),
    @"ended_monotonic_ns" : @(endedAtNs),
    @"snapshot_wall_time_ns" : @(snapshotWallTimeNs),
    @"terminal" : @(terminal),
    @"payload_policy" : kInumaScalarPayloadPolicy,
    @"credential_value_retained" : @NO,
    @"raw_pixels_retained" : @NO,
    @"surface_trace" : segmentPayload[@"surface_trace"] ?: @{},
    @"presentation_trace_v2" : segmentPayload[@"presentation_trace_v2"] ?: @{},
    @"decoder_boundary_trace" : segmentPayload[@"decoder_boundary_trace"] ?: @{},
    @"receiver_scheduler_trace" : segmentPayload[@"receiver_scheduler_trace"] ?: @{},
  };
  NSError* error = nil;
  NSData* data = [NSJSONSerialization dataWithJSONObject:segment
                                                 options:0
                                                   error:&error];
  if (data == nil || error != nil) {
    _writeFailureCount += 1;
    return NO;
  }
  NSString* filename = [NSString stringWithFormat:
      @"flutter-webrtc-texture-trace.segment-%06lu.json",
      (unsigned long)sequence];
  NSString* path = [_directoryPath stringByAppendingPathComponent:filename];
  if (![self writeOwnerOnlyFileAtPath:path data:data]) {
    _writeFailureCount += 1;
    return NO;
  }
  NSString* digest = InumaSHA256(data);
  NSDictionary* entry = @{
    @"sequence" : @(sequence),
    @"filename" : filename,
    @"bytes" : @(data.length),
    @"sha256" : digest,
    @"previous_sha256" : previous,
    @"started_monotonic_ns" : @(startedAtNs),
    @"ended_monotonic_ns" : @(endedAtNs),
    @"snapshot_wall_time_ns" : @(snapshotWallTimeNs),
    @"terminal" : @(terminal),
  };
  [_entries addObject:entry];
  _totalSegmentBytes += data.length;
  NSDictionary* manifest = @{
    @"schema" : kInumaSegmentManifestSchema,
    @"status" : @"pass",
    @"finding" : @"immutable_segmented_scalar_evidence_manifest",
    @"session_sequence" : @(_sessionSequence),
    @"clock_domain" : @"macos_clock_monotonic_raw_shared_mach_host_time",
    @"payload_policy" : kInumaScalarPayloadPolicy,
    @"segment_interval_ns" : @(_segmentIntervalNs),
    @"segment_count" : @(_entries.count),
    @"total_segment_bytes" : @(_totalSegmentBytes),
    @"trace_started_monotonic_ns" : @(_traceStartedAtNs),
    @"trace_snapshot_monotonic_ns" : @(endedAtNs),
    @"trace_snapshot_wall_time_ns" : @(snapshotWallTimeNs),
    @"terminal" : @(terminal),
    @"terminal_segment_count" : @(terminal ? 1 : 0),
    @"write_failure_count" : @(_writeFailureCount),
    @"capacity_exhaustions" : @0,
    @"credential_value_retained" : @NO,
    @"raw_pixels_retained" : @NO,
    @"segments" : _entries,
  };
  NSData* manifestData = [NSJSONSerialization dataWithJSONObject:manifest
                                                         options:0
                                                           error:&error];
  if (manifestData == nil || error != nil ||
      ![self replaceManifestData:manifestData]) {
    [_entries removeLastObject];
    _totalSegmentBytes -= data.length;
    _writeFailureCount += 1;
    return NO;
  }
  _terminalWritten = terminal;
  return YES;
}

- (uint64_t)writeFailureCount {
  return _writeFailureCount;
}

- (NSUInteger)segmentCount {
  return _entries.count;
}

@end

#endif
