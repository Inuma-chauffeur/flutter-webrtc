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
  InumaEmergencyGraceRefuseReasonBurstNotRearmed = 6,
} InumaEmergencyGraceRefuseReason;

typedef struct {
  bool enabled;
  bool primary_queue_full;
  size_t maximum_queued_frames;
  size_t pending_frame_count;
  bool current_frame_repeat_deferred;
  bool current_frame_rescue_promoted;
  bool current_frame_awaits_copy;
  uint64_t current_ready_monotonic_ns;
  uint64_t primary_ready_monotonic_ns;
  uint64_t checked_monotonic_ns;
  uint64_t minimum_hold_ns;
  bool grace_occupied;
  bool burst_armed;
} InumaEmergencyGracePolicyInput;

typedef struct {
  bool queue_shape_valid;
  bool current_overdue_copy;
  bool current_protection_valid;
  bool primary_old_enough;
  bool eligible;
  bool admitted_via_overdue_copy;
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
  const bool current_overdue_copy =
      input.current_frame_awaits_copy &&
      input.current_ready_monotonic_ns > 0 && input.minimum_hold_ns > 0 &&
      input.checked_monotonic_ns >= input.current_ready_monotonic_ns &&
      input.checked_monotonic_ns - input.current_ready_monotonic_ns >=
          input.minimum_hold_ns;
  const bool current_protection_valid =
      input.current_frame_repeat_deferred || current_overdue_copy;
  const bool eligible = input.enabled && input.burst_armed &&
                        queue_shape_valid &&
                        current_protection_valid &&
                        primary_old_enough && !input.grace_occupied;
  InumaEmergencyGraceRefuseReason refuse_reason =
      InumaEmergencyGraceRefuseReasonNone;
  if (input.enabled && input.primary_queue_full && !eligible) {
    if (input.grace_occupied) {
      refuse_reason = InumaEmergencyGraceRefuseReasonOccupied;
    } else if (!input.burst_armed) {
      refuse_reason = InumaEmergencyGraceRefuseReasonBurstNotRearmed;
    } else if (!queue_shape_valid) {
      refuse_reason = InumaEmergencyGraceRefuseReasonQueueShape;
    } else if (!current_protection_valid) {
      refuse_reason = InumaEmergencyGraceRefuseReasonNotRepeatDeferred;
    } else {
      refuse_reason = InumaEmergencyGraceRefuseReasonPrimaryBelowMinimumAge;
    }
  }
  return (InumaEmergencyGracePolicyDecision){
      .queue_shape_valid = queue_shape_valid,
      .current_overdue_copy = current_overdue_copy,
      .current_protection_valid = current_protection_valid,
      .primary_old_enough = primary_old_enough,
      .eligible = eligible,
      .admitted_via_overdue_copy = eligible && current_overdue_copy &&
                                  !input.current_frame_repeat_deferred,
      .refuse_reason = refuse_reason,
  };
}

static inline bool InumaEmergencyGraceShouldRearm(
    bool grace_occupied, bool primary_queue_full,
    size_t pending_frame_count) {
  // One grace frame may be admitted per overload burst.  The burst cannot
  // rearm merely because a copy shifted or drained that frame: the renderer
  // must first observe the ordinary queue shape again.  This prevents the
  // emergency slot from turning a transient depth-one queue into a sustained
  // depth-two pipeline.
  return !grace_occupied && !primary_queue_full && pending_frame_count == 0;
}

static inline bool InumaEmergencyGraceShouldShift(bool grace_occupied,
                                                  size_t pending_frame_count) {
  // The renderer calls this after popping the one-slot primary queue.  The
  // grace frame may move into that newly empty slot only at exact depth zero.
  return grace_occupied && pending_frame_count == 0;
}

static inline bool InumaEmergencyGracePromotedFrameDrains(
    bool promoted_from_emergency_grace) {
  return promoted_from_emergency_grace;
}

#endif  // INUMA_EMERGENCY_GRACE_POLICY_H_
