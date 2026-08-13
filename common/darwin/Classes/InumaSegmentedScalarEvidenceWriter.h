// Crash-safe immutable scalar-evidence writer for the macOS product surface.

#import <Foundation/Foundation.h>

#if TARGET_OS_OSX

NS_ASSUME_NONNULL_BEGIN

@interface InumaSegmentedScalarEvidenceWriter : NSObject

@property(nonatomic, readonly) uint64_t writeFailureCount;
@property(nonatomic, readonly) NSUInteger segmentCount;

- (nullable instancetype)initWithManifestPath:(NSString*)manifestPath
                              sessionSequence:(uint64_t)sessionSequence
                            traceStartedAtNs:(uint64_t)traceStartedAtNs
                             segmentIntervalNs:(uint64_t)segmentIntervalNs;

// Writes one immutable owner-only segment and commits its hash-linked manifest
// last. Any failure is latched permanently; later calls return NO.
- (BOOL)writeSegment:(NSDictionary<NSString*, id>*)segmentPayload
          startedAtNs:(uint64_t)startedAtNs
            endedAtNs:(uint64_t)endedAtNs
    snapshotWallTimeNs:(uint64_t)snapshotWallTimeNs
             terminal:(BOOL)terminal;

@end

NS_ASSUME_NONNULL_END

#endif
