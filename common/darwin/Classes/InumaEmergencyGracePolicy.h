#ifndef INUMA_EMERGENCY_GRACE_POLICY_H_
#define INUMA_EMERGENCY_GRACE_POLICY_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
  InumaEmergencyGraceRefuseReasonNone = 0,
  InumaEmergencyGraceRefuseReasonQueueShape = 1,
  InumaEmergencyGraceRefuseReasonNotRepeatDeferred = 2,
  InumaEmergencyGraceRefuseReasonPrimaryBelowMinimumAge = 3,
  InumaEmergencyGraceRefuseReasonOccupied = 4,
  InumaEmergencyGraceRefuseReasonConversionFailure = 5,
} InumaEmergencyGraceRefuseReason;

typedef struct {
  bool enabled;
  bool primary_queue_full;
  size_t maximum_queued_frames;
  size_t pending_frame_count;
  bool current_frame_repeat_deferred;
  uint64_t primary_ready_monotonic_ns;
  uint64_t checked_monotonic_ns;
  uint64_t minimum_hold_ns;
  bool grace_occupied;
} InumaEmergencyGracePolicyInput;

typedef struct {
  bool queue_shape_valid;
  bool primary_old_enough;
  bool eligible;
  InumaEmergencyGraceRefuseReason refuse_reason;
} InumaEmergencyGracePolicyDecision;

static inline InumaEmergencyGracePolicyDecision
InumaEmergencyGraceEvaluate(InumaEmergencyGracePolicyInput input) {
  const bool queue_shape_valid =
      input.primary_queue_full && input.maximum_queued_frames == 1 &&
      input.pending_frame_count == 1;
  const bool primary_old_enough =
      input.primary_ready_monotonic_ns > 0 && input.minimum_hold_ns > 0 &&
      input.checked_monotonic_ns >= input.primary_ready_monotonic_ns &&
      input.checked_monotonic_ns - input.primary_ready_monotonic_ns >=
          input.minimum_hold_ns;
  const bool eligible = input.enabled && queue_shape_valid &&
                        input.current_frame_repeat_deferred &&
                        primary_old_enough && !input.grace_occupied;
  InumaEmergencyGraceRefuseReason refuse_reason =
      InumaEmergencyGraceRefuseReasonNone;
  if (input.enabled && input.primary_queue_full && !eligible) {
    if (input.grace_occupied) {
      refuse_reason = InumaEmergencyGraceRefuseReasonOccupied;
    } else if (!queue_shape_valid) {
      refuse_reason = InumaEmergencyGraceRefuseReasonQueueShape;
    } else if (!input.current_frame_repeat_deferred) {
      refuse_reason = InumaEmergencyGraceRefuseReasonNotRepeatDeferred;
    } else {
      refuse_reason = InumaEmergencyGraceRefuseReasonPrimaryBelowMinimumAge;
    }
  }
  return (InumaEmergencyGracePolicyDecision){
      .queue_shape_valid = queue_shape_valid,
      .primary_old_enough = primary_old_enough,
      .eligible = eligible,
      .refuse_reason = refuse_reason,
  };
}

static inline bool InumaEmergencyGraceShouldShift(bool grace_occupied,
                                                  size_t pending_frame_count) {
  return grace_occupied && pending_frame_count == 1;
}

static inline bool InumaEmergencyGracePromotedFrameDrains(
    bool promoted_from_emergency_grace) {
  return promoted_from_emergency_grace;
}

#endif  // INUMA_EMERGENCY_GRACE_POLICY_H_
