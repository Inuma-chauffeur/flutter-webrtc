// Scalar ownership policy for one ordinary texture mark on a persistent
// main-run-loop source. This file owns no Objective-C or Core Foundation state.

#ifndef INUMA_MAIN_RUN_LOOP_NOTIFICATION_POLICY_H_
#define INUMA_MAIN_RUN_LOOP_NOTIFICATION_POLICY_H_

#include <stdbool.h>

typedef enum {
  InumaMainRunLoopNotificationArmReasonNone = 0,
  InumaMainRunLoopNotificationArmReasonAccepted = 1,
  InumaMainRunLoopNotificationArmReasonNonOrdinaryPath = 2,
  InumaMainRunLoopNotificationArmReasonSourceUnavailable = 3,
  InumaMainRunLoopNotificationArmReasonInvalidOwner = 4,
  InumaMainRunLoopNotificationArmReasonTokenOccupied = 5,
} InumaMainRunLoopNotificationArmReason;

typedef struct {
  bool enabled;
  bool ordinary_normal_path;
  bool source_registered;
  bool texture_registered;
  bool frame_available;
  bool frame_timestamp_valid;
  bool token_occupied;
} InumaMainRunLoopNotificationArmInput;

typedef struct {
  bool evaluated;
  bool arm;
  bool signal;
  bool wake;
  InumaMainRunLoopNotificationArmReason reason;
} InumaMainRunLoopNotificationArmDecision;

static inline InumaMainRunLoopNotificationArmDecision
InumaMainRunLoopNotificationEvaluateArm(
    InumaMainRunLoopNotificationArmInput input) {
  InumaMainRunLoopNotificationArmDecision decision = {0};
  if (!input.enabled) {
    return decision;
  }
  decision.evaluated = true;
  if (!input.ordinary_normal_path) {
    decision.reason = InumaMainRunLoopNotificationArmReasonNonOrdinaryPath;
    return decision;
  }
  if (!input.source_registered) {
    decision.reason = InumaMainRunLoopNotificationArmReasonSourceUnavailable;
    return decision;
  }
  if (!input.texture_registered || !input.frame_available ||
      !input.frame_timestamp_valid) {
    decision.reason = InumaMainRunLoopNotificationArmReasonInvalidOwner;
    return decision;
  }
  if (input.token_occupied) {
    decision.reason = InumaMainRunLoopNotificationArmReasonTokenOccupied;
    return decision;
  }
  decision.arm = true;
  decision.signal = true;
  decision.wake = true;
  decision.reason = InumaMainRunLoopNotificationArmReasonAccepted;
  return decision;
}

typedef struct {
  bool enabled;
  bool platform_thread;
  bool owns_source;
  bool token_occupied;
  bool renderer_state_matches;
  bool texture_registered;
  bool registry_available;
  bool texture_matches;
  bool frame_available;
  bool frame_timestamp_matches;
} InumaMainRunLoopNotificationFireInput;

typedef struct {
  bool evaluated;
  bool state_current;
  bool fire;
  bool close_stale;
} InumaMainRunLoopNotificationFireDecision;

static inline InumaMainRunLoopNotificationFireDecision
InumaMainRunLoopNotificationEvaluateFire(
    InumaMainRunLoopNotificationFireInput input) {
  InumaMainRunLoopNotificationFireDecision decision = {0};
  if (!input.enabled) {
    return decision;
  }
  decision.evaluated = true;
  decision.state_current = input.platform_thread && input.owns_source &&
                           input.token_occupied &&
                           input.renderer_state_matches &&
                           input.texture_registered &&
                           input.registry_available && input.texture_matches &&
                           input.frame_available &&
                           input.frame_timestamp_matches;
  decision.fire = decision.state_current;
  decision.close_stale = input.token_occupied && !decision.state_current;
  return decision;
}

static inline bool InumaMainRunLoopNotificationShouldCloseForLifecycle(
    bool enabled, bool token_occupied) {
  return enabled && token_occupied;
}

#endif  // INUMA_MAIN_RUN_LOOP_NOTIFICATION_POLICY_H_
