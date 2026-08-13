#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Returns a bounded scalar snapshot of macOS WebRTC decoder submissions and
 * decoder-output callbacks. The trace contains timestamps and counters only;
 * encoded or decoded media payloads are never retained.
 */
NSDictionary<NSString *, id> *InumaDecoderBoundaryTraceSnapshot(void);

/** Atomically drains only completed decoder/callback rows. Cumulative
 * counters and in-flight token ownership survive the segment boundary. */
NSDictionary<NSString *, id> *InumaDecoderBoundaryTraceDrainSnapshot(void);

NS_ASSUME_NONNULL_END
