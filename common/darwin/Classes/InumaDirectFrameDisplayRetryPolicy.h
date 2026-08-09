// Pure policy for one bounded display-linked retry of an uncopied direct frame.

#ifndef INUMA_DIRECT_FRAME_DISPLAY_RETRY_POLICY_H_
#define INUMA_DIRECT_FRAME_DISPLAY_RETRY_POLICY_H_

#include <stdbool.h>
#include <stdint.h>

typedef struct {
  bool enabled;
  bool owns_display_link;
  bool renderer_state_matches;
  bool texture_matches;
  bool frame_available;
  bool frame_timestamp_matches;
  bool predecessor_hold_satisfied;
  uint64_t frame_ready_monotonic_ns;
  uint64_t checked_monotonic_ns;
  uint64_t minimum_retry_age_ns;
} InumaDirectFrameDisplayRetryPolicyInput;

typedef struct {
  bool evaluated;
  bool state_current;
  bool timing_valid;
  bool defer;
  bool fire;
  bool stale;
} InumaDirectFrameDisplayRetryPolicyDecision;

static inline InumaDirectFrameDisplayRetryPolicyDecision
InumaDirectFrameDisplayRetryEvaluate(
    InumaDirectFrameDisplayRetryPolicyInput input) {
  InumaDirectFrameDisplayRetryPolicyDecision decision = {0};
  if (!input.enabled || !input.owns_display_link) {
    return decision;
  }
  decision.evaluated = true;
  decision.state_current = input.renderer_state_matches &&
                           input.texture_matches && input.frame_available &&
                           input.frame_timestamp_matches;
  decision.timing_valid = input.minimum_retry_age_ns > 0 &&
                          input.frame_ready_monotonic_ns > 0 &&
                          input.checked_monotonic_ns >=
                              input.frame_ready_monotonic_ns;
  if (!decision.state_current || !decision.timing_valid) {
    decision.stale = true;
    return decision;
  }
  const uint64_t age_ns =
      input.checked_monotonic_ns - input.frame_ready_monotonic_ns;
  decision.defer = age_ns < input.minimum_retry_age_ns ||
                   !input.predecessor_hold_satisfied;
  decision.fire = !decision.defer;
  return decision;
}

#endif // INUMA_DIRECT_FRAME_DISPLAY_RETRY_POLICY_H_
