// Entry point for the pure-C renderer policy and deterministic state suite.

#include "InumaEmergencyGracePolicy.h"
#include "InumaDirectFrameDisplayRetryPolicy.h"
#include "InumaFrameOwnershipPolicy.h"
#include "InumaMainRunLoopNotificationPolicy.h"
#include "InumaRepeatBoundaryPolicy.h"
#include "InumaRendererQueueSimulation.h"

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
      .current_frame_rescue_promoted = false,
      .current_frame_awaits_copy = true,
      .current_ready_monotonic_ns = 90000000,
      .primary_ready_monotonic_ns = 100000000,
      .checked_monotonic_ns = 100000000 + kMinimumHoldNs,
      .minimum_hold_ns = kMinimumHoldNs,
      .grace_occupied = false,
      .burst_armed = true,
  };
}

static void TestExactEligibilityBoundary(void) {
  InumaEmergencyGracePolicyInput input = EligibleInput();
  InumaEmergencyGracePolicyDecision decision =
      InumaEmergencyGraceEvaluate(input);
  assert(decision.queue_shape_valid);
  assert(decision.primary_old_enough);
  assert(decision.current_protection_valid);
  assert(!decision.admitted_via_overdue_copy);
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
  input.current_frame_awaits_copy = false;
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

  input = EligibleInput();
  input.burst_armed = false;
  assert(InumaEmergencyGraceEvaluate(input).refuse_reason ==
         InumaEmergencyGraceRefuseReasonBurstNotRearmed);
}

static void TestAnyOverdueCurrentCopyClosesPreRepeatArrivalRace(void) {
  InumaEmergencyGracePolicyInput input = EligibleInput();
  input.current_frame_repeat_deferred = false;
  input.current_frame_rescue_promoted = true;
  input.current_frame_awaits_copy = true;
  input.current_ready_monotonic_ns =
      input.checked_monotonic_ns - kMinimumHoldNs;
  InumaEmergencyGracePolicyDecision decision =
      InumaEmergencyGraceEvaluate(input);
  assert(decision.current_overdue_copy);
  assert(decision.current_protection_valid);
  assert(decision.eligible);
  assert(decision.admitted_via_overdue_copy);

  input.current_ready_monotonic_ns += 1;
  decision = InumaEmergencyGraceEvaluate(input);
  assert(!decision.current_overdue_copy);
  assert(!decision.eligible);
  assert(decision.refuse_reason ==
         InumaEmergencyGraceRefuseReasonNotRepeatDeferred);

  input.current_ready_monotonic_ns -= 1;
  input.current_frame_awaits_copy = false;
  assert(!InumaEmergencyGraceEvaluate(input).eligible);
  input.current_frame_awaits_copy = true;
  input.current_frame_rescue_promoted = false;
  decision = InumaEmergencyGraceEvaluate(input);
  assert(decision.current_overdue_copy);
  assert(decision.eligible);
  assert(decision.admitted_via_overdue_copy);
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
  assert(InumaEmergencyGraceShouldShift(true, 0));
  assert(!InumaEmergencyGraceShouldShift(false, 0));
  assert(!InumaEmergencyGraceShouldShift(true, 1));
  assert(!InumaEmergencyGraceShouldShift(true, 2));
  assert(InumaEmergencyGracePromotedFrameDrains(true));
  assert(!InumaEmergencyGracePromotedFrameDrains(false));
  assert(InumaEmergencyGraceShouldRearm(false, false, 0));
  assert(!InumaEmergencyGraceShouldRearm(true, false, 0));
  assert(!InumaEmergencyGraceShouldRearm(false, true, 1));
  assert(!InumaEmergencyGraceShouldRearm(false, false, 1));
}

static void TestThreeFrameQueueGraceSequence(void) {
  InumaEmergencyGracePolicyInput first = EligibleInput();
  const InumaEmergencyGracePolicyDecision admitted =
      InumaEmergencyGraceEvaluate(first);
  assert(admitted.eligible);

  InumaEmergencyGracePolicyInput second = EligibleInput();
  second.grace_occupied = true;
  second.burst_armed = false;
  const InumaEmergencyGracePolicyDecision refused =
      InumaEmergencyGraceEvaluate(second);
  assert(!refused.eligible);
  assert(refused.refuse_reason == InumaEmergencyGraceRefuseReasonOccupied);
  assert(InumaEmergencyGraceShouldShift(true, 0));
  assert(InumaEmergencyGracePromotedFrameDrains(true));

  second.grace_occupied = false;
  const InumaEmergencyGracePolicyDecision burstRefused =
      InumaEmergencyGraceEvaluate(second);
  assert(!burstRefused.eligible);
  assert(burstRefused.refuse_reason ==
         InumaEmergencyGraceRefuseReasonBurstNotRearmed);

  second.burst_armed = InumaEmergencyGraceShouldRearm(false, false, 0);
  assert(InumaEmergencyGraceEvaluate(second).eligible);
}

static void TestSustainedBurstCannotReopenAfterDrain(void) {
  InumaEmergencyGracePolicyInput input = EligibleInput();
  assert(InumaEmergencyGraceEvaluate(input).eligible);

  // Model a completed shift/drain while the primary queue is still full.
  // Releasing physical occupancy alone must not rearm the burst latch.
  input.grace_occupied = false;
  input.burst_armed = false;
  for (size_t arrival = 0; arrival < 100; arrival++) {
    const InumaEmergencyGracePolicyDecision decision =
        InumaEmergencyGraceEvaluate(input);
    assert(!decision.eligible);
    assert(decision.refuse_reason ==
           InumaEmergencyGraceRefuseReasonBurstNotRearmed);
  }

  assert(!InumaEmergencyGraceShouldRearm(false, true, 1));
  input.burst_armed = InumaEmergencyGraceShouldRearm(false, false, 0);
  assert(input.burst_armed);
  assert(InumaEmergencyGraceEvaluate(input).eligible);
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

static InumaDirectFrameDisplayRetryPolicyInput DirectRetryInput(void) {
  return (InumaDirectFrameDisplayRetryPolicyInput){
      .enabled = true,
      .owns_display_link = true,
      .renderer_state_matches = true,
      .texture_matches = true,
      .frame_available = true,
      .frame_timestamp_matches = true,
      .predecessor_hold_satisfied = true,
      .frame_ready_monotonic_ns = 100000000,
      .checked_monotonic_ns = 119000000,
      .minimum_retry_age_ns = 19000000,
  };
}

static void TestDirectRetryExactAgeBoundary(void) {
  InumaDirectFrameDisplayRetryPolicyInput input = DirectRetryInput();
  InumaDirectFrameDisplayRetryPolicyDecision decision =
      InumaDirectFrameDisplayRetryEvaluate(input);
  assert(decision.evaluated);
  assert(decision.state_current);
  assert(decision.timing_valid);
  assert(decision.fire);
  assert(!decision.defer);
  assert(!decision.stale);

  input.checked_monotonic_ns -= 1;
  decision = InumaDirectFrameDisplayRetryEvaluate(input);
  assert(decision.defer);
  assert(!decision.fire);
  assert(!decision.stale);

  input = DirectRetryInput();
  input.predecessor_hold_satisfied = false;
  decision = InumaDirectFrameDisplayRetryEvaluate(input);
  assert(decision.defer);
  assert(!decision.fire);
}

static void TestDirectRetryDefaultOffAndStrictOwnership(void) {
  InumaDirectFrameDisplayRetryPolicyInput input = DirectRetryInput();
  input.enabled = false;
  InumaDirectFrameDisplayRetryPolicyDecision decision =
      InumaDirectFrameDisplayRetryEvaluate(input);
  assert(!decision.evaluated);
  assert(!decision.fire);

  input = DirectRetryInput();
  input.frame_available = false;
  decision = InumaDirectFrameDisplayRetryEvaluate(input);
  assert(decision.evaluated);
  assert(decision.stale);
  assert(!decision.fire);

  input = DirectRetryInput();
  input.frame_timestamp_matches = false;
  decision = InumaDirectFrameDisplayRetryEvaluate(input);
  assert(decision.stale);

  input = DirectRetryInput();
  input.checked_monotonic_ns = input.frame_ready_monotonic_ns - 1;
  decision = InumaDirectFrameDisplayRetryEvaluate(input);
  assert(!decision.timing_valid);
  assert(decision.stale);
}

static void TestFrameOwnershipAcceptsZeroTimestampWithExactGeneration(void) {
  assert(InumaFrameOwnershipValuesMatch(1, 1, 0, 0));
  assert(InumaFrameOwnershipValuesMatch(42, 42, 1234, 1234));

  // Generation zero is the explicit unowned sentinel. Media timestamp zero
  // remains valid and cannot substitute for lifecycle ownership.
  assert(!InumaFrameOwnershipValuesMatch(0, 0, 0, 0));
  assert(!InumaFrameOwnershipValuesMatch(1, 0, 0, 0));
  assert(!InumaFrameOwnershipValuesMatch(2, 1, 0, 0));
  assert(!InumaFrameOwnershipValuesMatch(1, 1, 0, 1));
}

static void TestFrameGenerationIsMonotonicAndNeverZero(void) {
  assert(InumaNextFrameGeneration(0) == 1);
  assert(InumaNextFrameGeneration(1) == 2);
  assert(InumaNextFrameGeneration(UINT64_MAX - 1) == UINT64_MAX);
  assert(InumaNextFrameGeneration(UINT64_MAX) == 1);
}

static InumaMainRunLoopNotificationArmInput MainRunLoopArmInput(void) {
  return (InumaMainRunLoopNotificationArmInput){
      .enabled = true,
      .ordinary_normal_path = true,
      .source_registered = true,
      .texture_registered = true,
      .frame_available = true,
      .frame_ownership_valid = true,
      .token_occupied = false,
  };
}

static void TestMainRunLoopNotificationArmContract(void) {
  InumaMainRunLoopNotificationArmInput input = MainRunLoopArmInput();
  InumaMainRunLoopNotificationArmDecision decision =
      InumaMainRunLoopNotificationEvaluateArm(input);
  assert(decision.evaluated);
  assert(decision.arm);
  assert(decision.signal);
  assert(decision.wake);
  assert(decision.reason == InumaMainRunLoopNotificationArmReasonAccepted);

  input.enabled = false;
  decision = InumaMainRunLoopNotificationEvaluateArm(input);
  assert(!decision.evaluated);
  assert(!decision.arm);

  input = MainRunLoopArmInput();
  input.ordinary_normal_path = false;
  decision = InumaMainRunLoopNotificationEvaluateArm(input);
  assert(!decision.arm);
  assert(decision.reason ==
         InumaMainRunLoopNotificationArmReasonNonOrdinaryPath);

  input = MainRunLoopArmInput();
  input.source_registered = false;
  decision = InumaMainRunLoopNotificationEvaluateArm(input);
  assert(!decision.arm);
  assert(decision.reason ==
         InumaMainRunLoopNotificationArmReasonSourceUnavailable);

  input = MainRunLoopArmInput();
  input.frame_available = false;
  decision = InumaMainRunLoopNotificationEvaluateArm(input);
  assert(!decision.arm);
  assert(decision.reason ==
         InumaMainRunLoopNotificationArmReasonInvalidOwner);

  input = MainRunLoopArmInput();
  input.token_occupied = true;
  decision = InumaMainRunLoopNotificationEvaluateArm(input);
  assert(!decision.arm);
  assert(!decision.signal);
  assert(!decision.wake);
  assert(decision.reason ==
         InumaMainRunLoopNotificationArmReasonTokenOccupied);
}

static InumaMainRunLoopNotificationFireInput MainRunLoopFireInput(void) {
  return (InumaMainRunLoopNotificationFireInput){
      .enabled = true,
      .platform_thread = true,
      .owns_source = true,
      .token_occupied = true,
      .renderer_state_matches = true,
      .texture_registered = true,
      .registry_available = true,
      .texture_matches = true,
      .frame_available = true,
      .frame_ownership_matches = true,
  };
}

static void TestMainRunLoopNotificationFireAndLifecycleContract(void) {
  InumaMainRunLoopNotificationFireInput input = MainRunLoopFireInput();
  InumaMainRunLoopNotificationFireDecision decision =
      InumaMainRunLoopNotificationEvaluateFire(input);
  assert(decision.evaluated);
  assert(decision.state_current);
  assert(decision.fire);
  assert(!decision.close_stale);

  input.frame_ownership_matches = false;
  decision = InumaMainRunLoopNotificationEvaluateFire(input);
  assert(!decision.state_current);
  assert(!decision.fire);
  assert(decision.close_stale);

  input = MainRunLoopFireInput();
  input.platform_thread = false;
  decision = InumaMainRunLoopNotificationEvaluateFire(input);
  assert(!decision.fire);
  assert(decision.close_stale);

  input = MainRunLoopFireInput();
  input.registry_available = false;
  decision = InumaMainRunLoopNotificationEvaluateFire(input);
  assert(!decision.fire);
  assert(decision.close_stale);

  input = MainRunLoopFireInput();
  input.token_occupied = false;
  decision = InumaMainRunLoopNotificationEvaluateFire(input);
  assert(!decision.fire);
  assert(!decision.close_stale);

  input = MainRunLoopFireInput();
  input.enabled = false;
  decision = InumaMainRunLoopNotificationEvaluateFire(input);
  assert(!decision.evaluated);
  assert(!decision.fire);

  assert(InumaMainRunLoopNotificationShouldCloseForLifecycle(true, true));
  assert(!InumaMainRunLoopNotificationShouldCloseForLifecycle(false, true));
  assert(!InumaMainRunLoopNotificationShouldCloseForLifecycle(true, false));
}

static void TestMainRunLoopNotificationDeterministicSequences(void) {
  size_t arms = 0;
  size_t signals = 0;
  size_t wakes = 0;
  size_t callbacks = 0;
  size_t fires = 0;
  size_t stale_closes = 0;
  size_t lifecycle_closes = 0;
  bool token_occupied = false;

  // Ordinary source: one token, signal, wake, callback, and fire.
  InumaMainRunLoopNotificationArmInput arm = MainRunLoopArmInput();
  arm.token_occupied = token_occupied;
  InumaMainRunLoopNotificationArmDecision arm_decision =
      InumaMainRunLoopNotificationEvaluateArm(arm);
  assert(arm_decision.arm);
  token_occupied = true;
  arms += 1;
  signals += arm_decision.signal ? 1u : 0u;
  wakes += arm_decision.wake ? 1u : 0u;
  InumaMainRunLoopNotificationFireInput fire = MainRunLoopFireInput();
  fire.token_occupied = token_occupied;
  InumaMainRunLoopNotificationFireDecision fire_decision =
      InumaMainRunLoopNotificationEvaluateFire(fire);
  callbacks += 1;
  fires += fire_decision.fire ? 1u : 0u;
  token_occupied = false;

  // A second arm cannot overwrite the outstanding exact token. The single
  // signaled callback later closes stale after a foreign raster acquisition.
  arm = MainRunLoopArmInput();
  arm.token_occupied = token_occupied;
  arm_decision = InumaMainRunLoopNotificationEvaluateArm(arm);
  assert(arm_decision.arm);
  token_occupied = true;
  arms += 1;
  signals += 1;
  wakes += 1;
  arm.token_occupied = token_occupied;
  assert(InumaMainRunLoopNotificationEvaluateArm(arm).reason ==
         InumaMainRunLoopNotificationArmReasonTokenOccupied);
  fire = MainRunLoopFireInput();
  fire.token_occupied = token_occupied;
  fire.frame_available = false;
  fire_decision = InumaMainRunLoopNotificationEvaluateFire(fire);
  assert(fire_decision.close_stale);
  callbacks += 1;
  stale_closes += 1;
  token_occupied = false;

  // Promoted and raster-repeat paths are deliberately outside this first
  // candidate and keep their established platform-turn owner.
  arm = MainRunLoopArmInput();
  arm.ordinary_normal_path = false;
  assert(InumaMainRunLoopNotificationEvaluateArm(arm).reason ==
         InumaMainRunLoopNotificationArmReasonNonOrdinaryPath);
  assert(!InumaMainRunLoopNotificationEvaluateArm(arm).arm);

  // Lifecycle closes an armed token without a registrar fire.
  arm = MainRunLoopArmInput();
  arm_decision = InumaMainRunLoopNotificationEvaluateArm(arm);
  assert(arm_decision.arm);
  token_occupied = true;
  arms += 1;
  signals += 1;
  wakes += 1;
  if (InumaMainRunLoopNotificationShouldCloseForLifecycle(true,
                                                          token_occupied)) {
    lifecycle_closes += 1;
    token_occupied = false;
  }

  assert(!token_occupied);
  assert(arms == 3);
  assert(signals == arms);
  assert(wakes == arms);
  assert(callbacks == 2);
  assert(fires == 1);
  assert(stale_closes == 1);
  assert(lifecycle_closes == 1);
  assert(arms == fires + stale_closes + lifecycle_closes);
}

int main(void) {
  TestExactEligibilityBoundary();
  TestDefaultOffIsQuiescent();
  TestStrictRefusalReasons();
  TestAnyOverdueCurrentCopyClosesPreRepeatArrivalRace();
  TestNoRefusalWithoutFullPrimaryQueue();
  TestBoundedFifoActions();
  TestThreeFrameQueueGraceSequence();
  TestSustainedBurstCannotReopenAfterDrain();
  TestRepeatOnlyBoundary();
  TestRepeatBoundaryDefaultOffAndBaseGuard();
  TestDirectRetryExactAgeBoundary();
  TestDirectRetryDefaultOffAndStrictOwnership();
  TestFrameOwnershipAcceptsZeroTimestampWithExactGeneration();
  TestFrameGenerationIsMonotonicAndNeverZero();
  TestMainRunLoopNotificationArmContract();
  TestMainRunLoopNotificationFireAndLifecycleContract();
  TestMainRunLoopNotificationDeterministicSequences();
  InumaRunRendererQueueSimulationScenarios();
  return 0;
}
