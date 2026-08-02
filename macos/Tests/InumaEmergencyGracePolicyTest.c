#include "InumaEmergencyGracePolicy.h"
#include "InumaRepeatBoundaryPolicy.h"

#include <assert.h>
#include <stddef.h>

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

static void TestThreeFrameQueueGraceSequence(void) {
  InumaEmergencyGracePolicyInput first = EligibleInput();
  const InumaEmergencyGracePolicyDecision admitted =
      InumaEmergencyGraceEvaluate(first);
  assert(admitted.eligible);

  InumaEmergencyGracePolicyInput second = EligibleInput();
  second.grace_occupied = true;
  const InumaEmergencyGracePolicyDecision refused =
      InumaEmergencyGraceEvaluate(second);
  assert(!refused.eligible);
  assert(refused.refuse_reason == InumaEmergencyGraceRefuseReasonOccupied);
  assert(InumaEmergencyGraceShouldShift(true, 1));
  assert(InumaEmergencyGracePromotedFrameDrains(true));
}

static InumaRepeatBoundaryPolicyDecision RepeatBoundaryAt(uint64_t tenure_ns) {
  return InumaRepeatBoundaryEvaluate((InumaRepeatBoundaryPolicyInput){
      .enabled = true,
      .base_repeat_candidate = true,
      .predecessor_tenure_ns = tenure_ns,
      .normal_minimum_hold_ns = kMinimumHoldNs,
      .repeat_boundary_ns = 20000000,
  });
}

static void TestRepeatOnlyBoundary(void) {
  InumaRepeatBoundaryPolicyDecision decision = RepeatBoundaryAt(18999999);
  assert(decision.evaluated);
  assert(decision.repeat);
  assert(!decision.extends_normal_hold);

  decision = RepeatBoundaryAt(19000000);
  assert(decision.evaluated);
  assert(decision.repeat);
  assert(decision.extends_normal_hold);

  decision = RepeatBoundaryAt(19775916);
  assert(decision.evaluated);
  assert(decision.repeat);
  assert(decision.extends_normal_hold);

  decision = RepeatBoundaryAt(19999999);
  assert(decision.evaluated);
  assert(decision.repeat);
  assert(decision.extends_normal_hold);

  decision = RepeatBoundaryAt(20000000);
  assert(decision.evaluated);
  assert(!decision.repeat);
  assert(!decision.extends_normal_hold);
}

static void TestRepeatBoundaryDefaultOffAndBaseGuard(void) {
  InumaRepeatBoundaryPolicyInput input = {
      .enabled = false,
      .base_repeat_candidate = true,
      .predecessor_tenure_ns = 19775916,
      .normal_minimum_hold_ns = kMinimumHoldNs,
      .repeat_boundary_ns = 20000000,
  };
  InumaRepeatBoundaryPolicyDecision decision =
      InumaRepeatBoundaryEvaluate(input);
  assert(!decision.evaluated);
  assert(!decision.repeat);

  input.enabled = true;
  input.base_repeat_candidate = false;
  decision = InumaRepeatBoundaryEvaluate(input);
  assert(!decision.evaluated);
  assert(!decision.repeat);

  input.base_repeat_candidate = true;
  input.repeat_boundary_ns = 0;
  decision = InumaRepeatBoundaryEvaluate(input);
  assert(!decision.evaluated);
  assert(!decision.repeat);

  input.repeat_boundary_ns = 10000000;
  input.predecessor_tenure_ns = 18999999;
  decision = InumaRepeatBoundaryEvaluate(input);
  assert(decision.evaluated);
  assert(decision.repeat);
  assert(!decision.extends_normal_hold);
}

static void TestRepeatBoundaryThirtyAndSixtyHzPhaseSweep(void) {
  const uint64_t periods_ns[] = {33333333, 16666667};
  const int64_t jitters_ns[] = {-250000, 0, 250000};
  for (size_t cadence = 0;
       cadence < sizeof(periods_ns) / sizeof(periods_ns[0]); cadence++) {
    for (size_t jitter = 0;
         jitter < sizeof(jitters_ns) / sizeof(jitters_ns[0]); jitter++) {
      for (uint64_t phase_ns = 0; phase_ns < periods_ns[cadence];
           phase_ns += 250000) {
        int64_t shifted_phase = (int64_t)phase_ns + jitters_ns[jitter];
        while (shifted_phase < 0) {
          shifted_phase += 2000001;
        }
        const uint64_t tenure_ns =
            18500000 + (uint64_t)(shifted_phase % 2000001);
        const InumaRepeatBoundaryPolicyDecision decision =
            RepeatBoundaryAt(tenure_ns);
        assert(decision.evaluated);
        assert(decision.repeat == (tenure_ns < 20000000));
        assert(decision.extends_normal_hold ==
               (tenure_ns >= kMinimumHoldNs && tenure_ns < 20000000));
      }
    }
  }
}

int main(void) {
  TestExactEligibilityBoundary();
  TestDefaultOffIsQuiescent();
  TestStrictRefusalReasons();
  TestNoRefusalWithoutFullPrimaryQueue();
  TestBoundedFifoActions();
  TestThreeFrameQueueGraceSequence();
  TestRepeatOnlyBoundary();
  TestRepeatBoundaryDefaultOffAndBaseGuard();
  TestRepeatBoundaryThirtyAndSixtyHzPhaseSweep();
  return 0;
}
