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

/** Latches the evidence boundary, rejects new trace tokens without changing
 * decoder behavior, waits boundedly for already-started calls, then drains.
 * A timeout remains explicit fail-closed evidence in the returned report. */
NSDictionary<NSString *, id> *InumaDecoderBoundaryTraceTerminalDrainSnapshot(void);

NS_ASSUME_NONNULL_END
