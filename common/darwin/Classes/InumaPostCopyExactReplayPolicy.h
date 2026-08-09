// Scalar policy for one bounded, exact-buffer post-copy replay.

#ifndef INUMA_POST_COPY_EXACT_REPLAY_POLICY_H_
#define INUMA_POST_COPY_EXACT_REPLAY_POLICY_H_

#include <stdbool.h>
#include <stdint.h>

typedef enum {
  InumaPostCopyExactReplayScheduleReasonNone = 0,
  InumaPostCopyExactReplayScheduleReasonAccepted = 1,
  InumaPostCopyExactReplayScheduleReasonRecursiveCopy = 2,
  InumaPostCopyExactReplayScheduleReasonSlotOccupied = 3,
  InumaPostCopyExactReplayScheduleReasonInvalidOwner = 4,
} InumaPostCopyExactReplayScheduleReason;

typedef struct {
  bool enabled;
  bool new_source_copy;
  bool texture_registered;
  bool buffer_available;
  bool frame_timestamp_valid;
  bool slot_occupied;
} InumaPostCopyExactReplayScheduleInput;

typedef struct {
  bool evaluated;
  bool schedule;
  bool defer_current_notification;
  InumaPostCopyExactReplayScheduleReason reason;
} InumaPostCopyExactReplayScheduleDecision;

static inline InumaPostCopyExactReplayScheduleDecision
InumaPostCopyExactReplayEvaluateSchedule(
    InumaPostCopyExactReplayScheduleInput input) {
  InumaPostCopyExactReplayScheduleDecision decision = {0};
  if (!input.enabled) {
    return decision;
  }
  decision.evaluated = true;
  if (!input.new_source_copy) {
    decision.reason = InumaPostCopyExactReplayScheduleReasonRecursiveCopy;
    return decision;
  }
  if (!input.texture_registered || !input.buffer_available ||
      !input.frame_timestamp_valid) {
    decision.reason = InumaPostCopyExactReplayScheduleReasonInvalidOwner;
    return decision;
  }
  if (input.slot_occupied) {
    decision.reason = InumaPostCopyExactReplayScheduleReasonSlotOccupied;
    return decision;
  }
  decision.schedule = true;
  decision.defer_current_notification = true;
  decision.reason = InumaPostCopyExactReplayScheduleReasonAccepted;
  return decision;
}

typedef struct {
  bool enabled;
  bool owns_display_link;
  bool renderer_state_matches;
  bool texture_registered;
  bool slot_occupied;
  bool buffer_available;
  bool notification_issued;
} InumaPostCopyExactReplayFireInput;

typedef struct {
  bool evaluated;
  bool state_current;
  bool fire;
  bool stale;
} InumaPostCopyExactReplayFireDecision;

static inline InumaPostCopyExactReplayFireDecision
InumaPostCopyExactReplayEvaluateFire(InumaPostCopyExactReplayFireInput input) {
  InumaPostCopyExactReplayFireDecision decision = {0};
  if (!input.enabled) {
    return decision;
  }
  decision.evaluated = true;
  decision.state_current = input.owns_display_link &&
                           input.renderer_state_matches &&
                           input.texture_registered && input.slot_occupied &&
                           input.buffer_available && !input.notification_issued;
  decision.fire = decision.state_current;
  decision.stale = !decision.state_current;
  return decision;
}

typedef struct {
  bool enabled;
  bool slot_occupied;
  bool buffer_available;
  bool notification_issued;
  bool current_frame_available;
} InumaPostCopyExactReplayConsumeInput;

typedef struct {
  bool evaluated;
  bool consume;
  bool renotify_current;
} InumaPostCopyExactReplayConsumeDecision;

static inline InumaPostCopyExactReplayConsumeDecision
InumaPostCopyExactReplayEvaluateConsume(
    InumaPostCopyExactReplayConsumeInput input) {
  InumaPostCopyExactReplayConsumeDecision decision = {0};
  if (!input.enabled) {
    return decision;
  }
  decision.evaluated = true;
  decision.consume = input.slot_occupied && input.buffer_available &&
                     input.notification_issued;
  decision.renotify_current =
      decision.consume && input.current_frame_available;
  return decision;
}

#endif  // INUMA_POST_COPY_EXACT_REPLAY_POLICY_H_
