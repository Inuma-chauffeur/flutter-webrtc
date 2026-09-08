// Constant-size scalar observer evidence. Caller serializes access/snapshots.
// These times witness copyDisplayedPixelBuffer calls, not physical panel tenure.
#ifndef INUMA_NATIVE_OBSERVER_TIMING_H
#define INUMA_NATIVE_OBSERVER_TIMING_H

#include <stdbool.h>
#include <stdint.h>

typedef struct {
  uint64_t pollCount;
  uint64_t nilCount;
  uint64_t resolvedCount;
  uint64_t unresolvedCount;
  uint64_t invalidTimingCount;
  uint64_t firstCopyBeginNs;
  uint64_t lastCopyBeginNs;
  uint64_t lastCopyEndNs;
  uint64_t copyTotalDurationNs;
  uint64_t copyMaximumDurationNs;
  uint64_t pollGapMaximumNs;
  uint64_t pollGapsOver20Ms;
  uint64_t previousGeneration;
  bool previousResolved;
} InumaNativeObserverTiming;

// Returns the preceding resolved old-generation copy start, or zero when an
// initial/nil/unresolved/invalid poll prevents that bracket. Never invents a
// bracket across unknown identity. No allocation, clock access or pixel data.
static inline uint64_t InumaNativeObserverRecordPoll(
    InumaNativeObserverTiming* state, uint64_t copyBeginNs, uint64_t copyEndNs,
    bool hasBuffer, bool resolved, uint64_t generation) {
  state->pollCount += 1;
  state->nilCount += !hasBuffer;
  state->resolvedCount += hasBuffer && resolved;
  state->unresolvedCount += hasBuffer && !resolved;
  if (copyBeginNs == 0 || copyEndNs < copyBeginNs ||
      (state->lastCopyEndNs != 0 && copyBeginNs < state->lastCopyEndNs) ||
      (resolved && (!hasBuffer || generation == 0))) {
    state->invalidTimingCount += 1;
    state->previousResolved = false;
    return 0;
  }
  const uint64_t previous =
      resolved && state->previousResolved &&
              generation != state->previousGeneration
          ? state->lastCopyBeginNs : 0;
  if (state->firstCopyBeginNs == 0) state->firstCopyBeginNs = copyBeginNs;
  if (state->lastCopyBeginNs != 0) {
    const uint64_t gap = copyBeginNs - state->lastCopyBeginNs;
    if (gap > state->pollGapMaximumNs) state->pollGapMaximumNs = gap;
    state->pollGapsOver20Ms += gap > 20000000;
  }
  const uint64_t duration = copyEndNs - copyBeginNs;
  state->copyTotalDurationNs += duration;
  if (duration > state->copyMaximumDurationNs)
    state->copyMaximumDurationNs = duration;
  state->lastCopyBeginNs = copyBeginNs;
  state->lastCopyEndNs = copyEndNs;
  state->previousResolved = resolved;
  state->previousGeneration = resolved ? generation : 0;
  return previous;
}

#endif
