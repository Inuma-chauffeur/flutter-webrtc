#ifndef INUMA_REPEAT_BOUNDARY_POLICY_H_
#define INUMA_REPEAT_BOUNDARY_POLICY_H_

#include <stdbool.h>
#include <stdint.h>

typedef struct {
  bool enabled;
  bool base_repeat_candidate;
  uint64_t predecessor_tenure_ns;
  uint64_t normal_minimum_hold_ns;
  uint64_t repeat_boundary_ns;
} InumaRepeatBoundaryPolicyInput;

typedef struct {
  bool evaluated;
  bool repeat;
  bool extends_normal_hold;
} InumaRepeatBoundaryPolicyDecision;

static inline InumaRepeatBoundaryPolicyDecision
InumaRepeatBoundaryEvaluate(InumaRepeatBoundaryPolicyInput input) {
  const bool configured = input.enabled && input.repeat_boundary_ns > 0;
  const bool evaluated = configured && input.base_repeat_candidate;
  const uint64_t effective_boundary_ns =
      input.repeat_boundary_ns > input.normal_minimum_hold_ns
          ? input.repeat_boundary_ns
          : input.normal_minimum_hold_ns;
  const bool repeat =
      evaluated && input.predecessor_tenure_ns < effective_boundary_ns;
  return (InumaRepeatBoundaryPolicyDecision){
      .evaluated = evaluated,
      .repeat = repeat,
      .extends_normal_hold =
          repeat && input.predecessor_tenure_ns >= input.normal_minimum_hold_ns,
  };
}

#endif  // INUMA_REPEAT_BOUNDARY_POLICY_H_
