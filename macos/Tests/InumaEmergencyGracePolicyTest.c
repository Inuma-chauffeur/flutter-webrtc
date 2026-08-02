#include "InumaEmergencyGracePolicy.h"

#include <assert.h>

enum {
  kMinimumHoldNs = 19000000,
};

static InumaEmergencyGracePolicyInput EligibleInput(void) {
  return (InumaEmergencyGracePolicyInput){
      .enabled = true,
      .primary_queue_full = true,
      .maximum_queued_frames = 1,
      .pending_frame_count = 1,
      .current_frame_repeat_deferred = true,
      .primary_ready_monotonic_ns = 100000000,
      .checked_monotonic_ns = 100000000 + kMinimumHoldNs,
      .minimum_hold_ns = kMinimumHoldNs,
      .grace_occupied = false,
  };
}

static void TestExactEligibilityBoundary(void) {
  InumaEmergencyGracePolicyInput input = EligibleInput();
  InumaEmergencyGracePolicyDecision decision =
      InumaEmergencyGraceEvaluate(input);
  assert(decision.queue_shape_valid);
  assert(decision.primary_old_enough);
  assert(decision.eligible);
  assert(decision.refuse_reason == InumaEmergencyGraceRefuseReasonNone);

  input.checked_monotonic_ns -= 1;
  decision = InumaEmergencyGraceEvaluate(input);
  assert(!decision.primary_old_enough);
  assert(!decision.eligible);
  assert(decision.refuse_reason ==
         InumaEmergencyGraceRefuseReasonPrimaryBelowMinimumAge);
}

static void TestDefaultOffIsQuiescent(void) {
  InumaEmergencyGracePolicyInput input = EligibleInput();
  input.enabled = false;
  const InumaEmergencyGracePolicyDecision decision =
      InumaEmergencyGraceEvaluate(input);
  assert(!decision.eligible);
  assert(decision.refuse_reason == InumaEmergencyGraceRefuseReasonNone);
}

static void TestStrictRefusalReasons(void) {
  InumaEmergencyGracePolicyInput input = EligibleInput();
  input.current_frame_repeat_deferred = false;
  assert(InumaEmergencyGraceEvaluate(input).refuse_reason ==
         InumaEmergencyGraceRefuseReasonNotRepeatDeferred);

  input = EligibleInput();
  input.grace_occupied = true;
  assert(InumaEmergencyGraceEvaluate(input).refuse_reason ==
         InumaEmergencyGraceRefuseReasonOccupied);

  input = EligibleInput();
  input.pending_frame_count = 0;
  assert(InumaEmergencyGraceEvaluate(input).refuse_reason ==
         InumaEmergencyGraceRefuseReasonQueueShape);

  input = EligibleInput();
  input.maximum_queued_frames = 2;
  assert(InumaEmergencyGraceEvaluate(input).refuse_reason ==
         InumaEmergencyGraceRefuseReasonQueueShape);
}

static void TestNoRefusalWithoutFullPrimaryQueue(void) {
  InumaEmergencyGracePolicyInput input = EligibleInput();
  input.primary_queue_full = false;
  const InumaEmergencyGracePolicyDecision decision =
      InumaEmergencyGraceEvaluate(input);
  assert(!decision.queue_shape_valid);
  assert(!decision.eligible);
  assert(decision.refuse_reason == InumaEmergencyGraceRefuseReasonNone);
}

static void TestBoundedFifoActions(void) {
  assert(InumaEmergencyGraceShouldShift(true, 1));
  assert(!InumaEmergencyGraceShouldShift(false, 1));
  assert(!InumaEmergencyGraceShouldShift(true, 0));
  assert(!InumaEmergencyGraceShouldShift(true, 2));
  assert(InumaEmergencyGracePromotedFrameDrains(true));
  assert(!InumaEmergencyGracePromotedFrameDrains(false));
}

int main(void) {
  TestExactEligibilityBoundary();
  TestDefaultOffIsQuiescent();
  TestStrictRefusalReasons();
  TestNoRefusalWithoutFullPrimaryQueue();
  TestBoundedFifoActions();
  return 0;
}
