#ifndef INUMA_PRE_NOTIFICATION_COPY_POLICY_H_
#define INUMA_PRE_NOTIFICATION_COPY_POLICY_H_

#include <stdbool.h>
#include <stdint.h>

typedef enum {
  InumaPreNotificationCopyReasonNone = 0,
  InumaPreNotificationCopyReasonRepeatPredecessor = 1,
  InumaPreNotificationCopyReasonSuppressDuplicate = 2,
  InumaPreNotificationCopyReasonOwnNotificationIssued = 3,
  InumaPreNotificationCopyReasonRescuePromoted = 4,
  InumaPreNotificationCopyReasonMissingPredecessor = 5,
  InumaPreNotificationCopyReasonAtOrAboveMinimumHold = 6,
  InumaPreNotificationCopyReasonNoNormalNotificationOwner = 7,
  InumaPreNotificationCopyReasonInvalidClock = 8,
} InumaPreNotificationCopyReason;

typedef struct {
  bool enabled;
  bool frame_available;
  bool current_frame_rescue_promoted;
  bool normal_notification_pending;
  bool own_notification_issued;
  bool predecessor_available;
  bool predecessor_already_repeated;
  uint64_t last_copy_monotonic_ns;
  uint64_t checked_monotonic_ns;
  uint64_t minimum_hold_ns;
} InumaPreNotificationCopyPolicyInput;

typedef struct {
  bool evaluated;
  bool suppress_current_copy;
  bool repeat_predecessor;
  uint64_t predecessor_tenure_ns;
  InumaPreNotificationCopyReason reason;
} InumaPreNotificationCopyPolicyDecision;

static inline InumaPreNotificationCopyPolicyDecision
InumaPreNotificationCopyEvaluate(InumaPreNotificationCopyPolicyInput input) {
  InumaPreNotificationCopyPolicyDecision decision = {
      .evaluated = false,
      .suppress_current_copy = false,
      .repeat_predecessor = false,
      .predecessor_tenure_ns = 0,
      .reason = InumaPreNotificationCopyReasonNone,
  };
  if (!input.enabled || !input.frame_available) {
    return decision;
  }
  decision.evaluated = true;
  if (input.current_frame_rescue_promoted) {
    decision.reason = InumaPreNotificationCopyReasonRescuePromoted;
    return decision;
  }
  if (input.own_notification_issued) {
    decision.reason = InumaPreNotificationCopyReasonOwnNotificationIssued;
    return decision;
  }
  if (!input.normal_notification_pending) {
    decision.reason = InumaPreNotificationCopyReasonNoNormalNotificationOwner;
    return decision;
  }
  if (input.minimum_hold_ns == 0 || input.last_copy_monotonic_ns == 0 ||
      input.checked_monotonic_ns < input.last_copy_monotonic_ns) {
    decision.reason = InumaPreNotificationCopyReasonInvalidClock;
    return decision;
  }
  decision.predecessor_tenure_ns =
      input.checked_monotonic_ns - input.last_copy_monotonic_ns;
  if (decision.predecessor_tenure_ns >= input.minimum_hold_ns) {
    decision.reason = InumaPreNotificationCopyReasonAtOrAboveMinimumHold;
    return decision;
  }
  decision.suppress_current_copy = true;
  if (!input.predecessor_available) {
    decision.reason = InumaPreNotificationCopyReasonMissingPredecessor;
    return decision;
  }
  if (input.predecessor_already_repeated) {
    decision.reason = InumaPreNotificationCopyReasonSuppressDuplicate;
    return decision;
  }
  decision.repeat_predecessor = true;
  decision.reason = InumaPreNotificationCopyReasonRepeatPredecessor;
  return decision;
}

#endif  // INUMA_PRE_NOTIFICATION_COPY_POLICY_H_
