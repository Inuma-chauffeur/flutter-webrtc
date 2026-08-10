#ifndef INUMA_FRAME_OWNERSHIP_POLICY_H_
#define INUMA_FRAME_OWNERSHIP_POLICY_H_

#include <stdbool.h>
#include <stdint.h>

// RTCVideoFrame.timeStampNs is media timing metadata, not a presence token.
// WebRTC legitimately publishes zero for immediate-render frames.  Lifecycle
// and stale-callback ownership therefore use an explicit nonzero generation;
// the timestamp remains an additional equality check for non-zero and zero
// values alike.
typedef struct {
  uint64_t current_generation;
  uint64_t expected_generation;
  int64_t current_timestamp_ns;
  int64_t expected_timestamp_ns;
} InumaFrameOwnershipInput;

static inline bool
InumaFrameOwnershipMatches(InumaFrameOwnershipInput input) {
  return input.expected_generation != 0 &&
         input.current_generation == input.expected_generation &&
         input.current_timestamp_ns == input.expected_timestamp_ns;
}

static inline bool InumaFrameOwnershipValuesMatch(
    uint64_t current_generation,
    uint64_t expected_generation,
    int64_t current_timestamp_ns,
    int64_t expected_timestamp_ns) {
  return InumaFrameOwnershipMatches((InumaFrameOwnershipInput){
      .current_generation = current_generation,
      .expected_generation = expected_generation,
      .current_timestamp_ns = current_timestamp_ns,
      .expected_timestamp_ns = expected_timestamp_ns,
  });
}

#endif  // INUMA_FRAME_OWNERSHIP_POLICY_H_
