// Exercises bounded renderer pressure, lifecycle, and cadence state scenarios.

#include "InumaRendererQueueSimulation.h"

#include <assert.h>

static uint64_t BuildThroughRepeatScheduleRequest(
    RepeatBoundarySimulation *simulation) {
  const uint64_t origin_ns = 1000000000;
  const uint64_t warm_copy_ns = origin_ns + kDisplaySixtyHzNs;
  SimulateSourceArrival(simulation, 1, origin_ns);
  assert(!SimulateRasterCopy(simulation, warm_copy_ns));
  assert(simulation->last_copied_frame == 1);

  SimulateSourceArrival(simulation, 2, warm_copy_ns + 1000000);
  SimulateSourceArrival(simulation, 3, warm_copy_ns + 2000000);
  const uint64_t predecessor_copy_ns = warm_copy_ns + kDisplaySixtyHzNs;
  assert(!SimulateRasterCopy(simulation, predecessor_copy_ns));
  AssertSlots(simulation, 3, 0, 0);

  SimulateSourceArrival(simulation, 4, predecessor_copy_ns + 1);
  const uint64_t repeat_ns = predecessor_copy_ns + 19500000;
  assert(SimulateRasterCopy(simulation, repeat_ns));
  assert(simulation->retry_schedule_requested);
  assert(simulation->repeat_predecessor_frames[0] == 2);
  assert(simulation->repeat_deferred_frames[0] == 3);
  return repeat_ns;
}
static void ScheduleAndDispatchRetry(RepeatBoundarySimulation *simulation,
                                     uint64_t scheduled_ns) {
  assert(SimulateScheduleRetry(simulation, scheduled_ns));
  assert(simulation->retry_platform_turn_pending);
  assert(SimulatePlatformTurnDispatch(simulation));
  assert(!simulation->retry_platform_turn_pending);
  assert(simulation->retry_dispatched);
}
static uint64_t BuildThroughGraceAdmission(
    RepeatBoundarySimulation *simulation) {
  const uint64_t repeat_ns =
      BuildThroughRepeatScheduleRequest(simulation);
  ScheduleAndDispatchRetry(simulation, repeat_ns + 1);
  SimulateSourceArrival(simulation, 5, repeat_ns + 100000);
  AssertSlots(simulation, 3, 4, 5);
  assert(simulation->grace_admits == 1);
  assert(simulation->grace_shifts == 0);
  assert(simulation->grace_drains == 0);
  assert(simulation->grace_clears == 0);
  return repeat_ns;
}
static uint64_t CopyRetryAndAssertShift(
    RepeatBoundarySimulation *simulation, uint64_t repeat_ns,
    uint64_t platform_turn_latency_ns,
    size_t stalled_display_opportunities) {
  const uint64_t admitted_ready_ns = simulation->grace_ready_ns;
  const uint64_t retry_fire_ns = repeat_ns + platform_turn_latency_ns;
  SimulatePlatformTurnFire(simulation, retry_fire_ns);
  assert(simulation->current_repeat_retry_fired);
  uint64_t retry_copy_ns = repeat_ns + kDisplaySixtyHzNs;
  while (retry_copy_ns < retry_fire_ns) {
    retry_copy_ns += kDisplaySixtyHzNs;
  }
  retry_copy_ns +=
      (uint64_t)stalled_display_opportunities * kDisplaySixtyHzNs;
  assert(!SimulateRasterCopy(simulation, retry_copy_ns));
  assert(simulation->last_copy_ns - repeat_ns >= kDisplaySixtyHzNs);
  assert(simulation->retry_copies == 1);
  AssertSlots(simulation, 4, 5, 0);
  assert(simulation->primary_ready_ns == admitted_ready_ns);
  assert(simulation->primary_from_grace);
  assert(simulation->grace_admits == 1);
  assert(simulation->grace_shifts == 1);
  assert(simulation->grace_drains == 0);
  return retry_copy_ns;
}
static uint64_t CopyFollowingFrameAndAssertDrain(
    RepeatBoundarySimulation *simulation, uint64_t raster_ns) {
  raster_ns += kDisplaySixtyHzNs;
  assert(SimulateRasterCopy(simulation, raster_ns));
  assert(simulation->retry_schedule_requested);
  assert(simulation->repeat_predecessor_frames[1] == 3);
  assert(simulation->repeat_deferred_frames[1] == 4);
  ScheduleAndDispatchRetry(simulation, raster_ns + 1);
  SimulatePlatformTurnFire(simulation, raster_ns + 1000000);
  raster_ns += kDisplaySixtyHzNs;
  assert(!SimulateRasterCopy(simulation, raster_ns));
  AssertSlots(simulation, 5, 0, 0);
  assert(simulation->current_from_grace);
  assert(simulation->grace_admits == 1);
  assert(simulation->grace_shifts == 1);
  assert(simulation->grace_drains == 1);
  assert(simulation->grace_clears == 0);
  return raster_ns;
}
static void TestRetryUsesRasterCadenceAndPreservesGraceReadyTime(void) {
  RepeatBoundarySimulation simulation;
  InitializeSimulation(&simulation);
  const uint64_t repeat_ns = BuildThroughGraceAdmission(&simulation);
  uint64_t raster_ns =
      CopyRetryAndAssertShift(&simulation, repeat_ns, 3000000, 1);
  raster_ns = CopyFollowingFrameAndAssertDrain(&simulation, raster_ns);
  DrainSimulation(&simulation, &raster_ns, kDisplaySixtyHzNs);
  AssertCopiedSequence(&simulation, 5);
}
static void TestChainedEmergencyGraceSequence(void) {
  RepeatBoundarySimulation simulation;
  InitializeSimulation(&simulation);
  const uint64_t repeat_ns = BuildThroughGraceAdmission(&simulation);
  uint64_t raster_ns =
      CopyRetryAndAssertShift(&simulation, repeat_ns, 3000000, 0);

  raster_ns += kDisplaySixtyHzNs;
  assert(SimulateRasterCopy(&simulation, raster_ns));
  ScheduleAndDispatchRetry(&simulation, raster_ns + 1);
  const uint64_t chained_ready_ns = raster_ns + 100000;
  SimulateSourceArrival(&simulation, 6, chained_ready_ns);
  AssertSlots(&simulation, 4, 5, 6);
  assert(simulation.grace_admits == 2);

  SimulatePlatformTurnFire(&simulation, raster_ns + 1000000);
  raster_ns += kDisplaySixtyHzNs;
  assert(!SimulateRasterCopy(&simulation, raster_ns));
  AssertSlots(&simulation, 5, 6, 0);
  assert(simulation.primary_from_grace);
  assert(simulation.primary_ready_ns == chained_ready_ns);
  assert(simulation.grace_shifts == 2);
  assert(simulation.grace_drains == 1);

  DrainSimulation(&simulation, &raster_ns, kDisplaySixtyHzNs);
  AssertCopiedSequence(&simulation, 6);
  assert(simulation.grace_admits == 2);
  assert(simulation.grace_shifts == 2);
  assert(simulation.grace_drains == 2);
}
static void TestGraceOccupiedRefusesWithoutOverwrite(void) {
  RepeatBoundarySimulation simulation;
  InitializeSimulation(&simulation);
  const uint64_t repeat_ns = BuildThroughGraceAdmission(&simulation);
  const uint64_t grace_frame = simulation.grace_frame;
  const uint64_t grace_ready_ns = simulation.grace_ready_ns;
  SimulateSourceArrival(&simulation, 6, repeat_ns + 200000);
  AssertSlots(&simulation, 3, 4, 5);
  assert(simulation.grace_frame == grace_frame);
  assert(simulation.grace_ready_ns == grace_ready_ns);
  assert(simulation.source_count == 6);
  assert(simulation.accepted_count == 5);
  assert(simulation.coalesced_frames == 1);
  assert(simulation.overflows == 1);
  assert(simulation.grace_occupied_refusals == 1);

  uint64_t raster_ns =
      CopyRetryAndAssertShift(&simulation, repeat_ns, 3000000, 0);
  raster_ns = CopyFollowingFrameAndAssertDrain(&simulation, raster_ns);
  DrainSimulation(&simulation, &raster_ns, kDisplaySixtyHzNs);
  AssertTerminal(&simulation);
  assert(simulation.copied_count == 5);
  for (size_t index = 0; index < simulation.copied_count; index++) {
    assert(simulation.copied_frames[index] == index + 1);
  }
  assert(!ContainsFrame(simulation.copied_frames, simulation.copied_count, 6));
}
static void TestLifecycleClearClassifications(void) {
  RepeatBoundarySimulation before_shift;
  InitializeSimulation(&before_shift);
  const uint64_t before_shift_repeat_ns =
      BuildThroughGraceAdmission(&before_shift);
  assert(before_shift.retry_dispatched);
  SimulateLifecycleClear(&before_shift, InumaRendererLifecycleTrackChange);
  assert(before_shift.retry_dispatched);
  SimulatePlatformTurnFire(&before_shift, before_shift_repeat_ns + 3000000);
  AssertTerminal(&before_shift);
  assert(before_shift.grace_admits == 1);
  assert(before_shift.grace_shifts == 0);
  assert(before_shift.grace_drains == 0);
  assert(before_shift.grace_clears == 1);
  assert(before_shift.retry_stale_fires == 1);
  assert(before_shift.retry_fires == 0);
  assert(before_shift.lifecycle_track_changes == 1);
  assert(before_shift.lifecycle_size_resets == 0);
  assert(before_shift.lifecycle_disposes == 0);

  RepeatBoundarySimulation after_shift;
  InitializeSimulation(&after_shift);
  const uint64_t after_shift_repeat_ns =
      BuildThroughGraceAdmission(&after_shift);
  (void)CopyRetryAndAssertShift(&after_shift, after_shift_repeat_ns, 3000000,
                                0);
  SimulateLifecycleClear(&after_shift, InumaRendererLifecycleSizeReset);
  AssertTerminal(&after_shift);
  assert(after_shift.grace_admits == 1);
  assert(after_shift.grace_shifts == 1);
  assert(after_shift.grace_drains == 0);
  assert(after_shift.grace_clears == 1);
  assert(after_shift.lifecycle_track_changes == 0);
  assert(after_shift.lifecycle_size_resets == 1);
  assert(after_shift.lifecycle_disposes == 0);

  RepeatBoundarySimulation after_promotion;
  InitializeSimulation(&after_promotion);
  const uint64_t after_promotion_repeat_ns =
      BuildThroughGraceAdmission(&after_promotion);
  uint64_t raster_ns =
      CopyRetryAndAssertShift(&after_promotion, after_promotion_repeat_ns,
                              3000000, 0);
  (void)CopyFollowingFrameAndAssertDrain(&after_promotion, raster_ns);
  SimulateLifecycleClear(&after_promotion, InumaRendererLifecycleDispose);
  AssertTerminal(&after_promotion);
  assert(after_promotion.grace_admits == 1);
  assert(after_promotion.grace_shifts == 1);
  assert(after_promotion.grace_drains == 1);
  assert(after_promotion.grace_clears == 0);
  assert(after_promotion.lifecycle_track_changes == 0);
  assert(after_promotion.lifecycle_size_resets == 0);
  assert(after_promotion.lifecycle_disposes == 1);
}
static void AssertOnlyLifecycleKindCounted(
    const RepeatBoundarySimulation *simulation,
    InumaRendererLifecycleKind lifecycle_kind) {
  assert(simulation->lifecycle_track_changes ==
         (lifecycle_kind == InumaRendererLifecycleTrackChange ? 1u : 0u));
  assert(simulation->lifecycle_size_resets ==
         (lifecycle_kind == InumaRendererLifecycleSizeReset ? 1u : 0u));
  assert(simulation->lifecycle_disposes ==
         (lifecycle_kind == InumaRendererLifecycleDispose ? 1u : 0u));
}

static void RestoreSameRendererIdentityAfterLifecycle(
    RepeatBoundarySimulation *simulation, uint64_t renderer_identity,
    uint64_t ready_ns) {
  // A disposed texture is deliberately re-registered so the retry cannot be
  // rejected merely because registration stayed false. The new logical frame
  // reuses the old numeric renderer identity; only the generation separates
  // the two lifetimes and closes the ABA hole.
  simulation->texture_registered = true;
  SimulateSourceArrivalWithIdentity(simulation, 5, renderer_identity,
                                    ready_ns);
  assert(simulation->current_frame == 5);
  assert(simulation->current_renderer_identity == renderer_identity);
}

static void TestSameIdentityABAPredispatchInvalidations(void) {
  const InumaRendererLifecycleKind lifecycle_kinds[] = {
      InumaRendererLifecycleTrackChange,
      InumaRendererLifecycleSizeReset,
      InumaRendererLifecycleDispose,
  };
  for (size_t index = 0;
       index < sizeof(lifecycle_kinds) / sizeof(lifecycle_kinds[0]); index++) {
    RepeatBoundarySimulation simulation;
    InitializeSimulation(&simulation);
    const uint64_t repeat_ns =
        BuildThroughRepeatScheduleRequest(&simulation);
    const uint64_t original_generation =
        simulation.renderer_state_generation;
    const uint64_t renderer_identity =
        simulation.current_renderer_identity;
    assert(SimulateScheduleRetry(&simulation, repeat_ns + 1));
    assert(simulation.retry_schedules == 1);
    assert(simulation.retry_platform_turn_pending);
    assert(!simulation.retry_dispatched);

    SimulateLifecycleClear(&simulation, lifecycle_kinds[index]);
    assert(simulation.renderer_state_generation == original_generation + 1);
    RestoreSameRendererIdentityAfterLifecycle(
        &simulation, renderer_identity, repeat_ns + 1000000);
    assert(simulation.current_renderer_identity ==
           simulation.retry_owned_renderer_identity);
    assert(!SimulatePlatformTurnDispatch(&simulation));
    assert(!simulation.retry_platform_turn_pending);
    assert(!simulation.retry_dispatched);
    assert(simulation.retry_schedules == 1);
    assert(simulation.retry_platform_turn_dispatches == 0);
    assert(simulation.retry_platform_turn_predispatch_stales == 1);
    assert(simulation.retry_stale_fires == 1);
    assert(simulation.retry_fires == 0);
    assert(!SimulateRasterCopy(&simulation, repeat_ns + 30000000));
    AssertTerminal(&simulation);
    AssertOnlyLifecycleKindCounted(&simulation, lifecycle_kinds[index]);
  }
}

static void TestSameIdentityABAPostdispatchInvalidations(void) {
  const InumaRendererLifecycleKind lifecycle_kinds[] = {
      InumaRendererLifecycleTrackChange,
      InumaRendererLifecycleSizeReset,
      InumaRendererLifecycleDispose,
  };
  for (size_t index = 0;
       index < sizeof(lifecycle_kinds) / sizeof(lifecycle_kinds[0]); index++) {
    RepeatBoundarySimulation simulation;
    InitializeSimulation(&simulation);
    const uint64_t repeat_ns =
        BuildThroughRepeatScheduleRequest(&simulation);
    const uint64_t original_generation =
        simulation.renderer_state_generation;
    const uint64_t renderer_identity =
        simulation.current_renderer_identity;
    ScheduleAndDispatchRetry(&simulation, repeat_ns + 1);
    assert(simulation.retry_platform_turn_dispatches == 1);
    assert(simulation.retry_dispatched);

    SimulateLifecycleClear(&simulation, lifecycle_kinds[index]);
    assert(simulation.renderer_state_generation == original_generation + 1);
    RestoreSameRendererIdentityAfterLifecycle(
        &simulation, renderer_identity, repeat_ns + 1000000);
    assert(simulation.current_renderer_identity ==
           simulation.retry_dispatched_renderer_identity);
    SimulatePlatformTurnFire(&simulation, repeat_ns + 3000000);
    assert(!simulation.retry_dispatched);
    assert(simulation.retry_schedules == 1);
    assert(simulation.retry_platform_turn_dispatches == 1);
    assert(simulation.retry_platform_turn_predispatch_stales == 0);
    assert(simulation.retry_stale_fires == 1);
    assert(simulation.retry_fires == 0);
    assert(!SimulateRasterCopy(&simulation, repeat_ns + 30000000));
    AssertTerminal(&simulation);
    AssertOnlyLifecycleKindCounted(&simulation, lifecycle_kinds[index]);
  }
}

static void TestAsyncRetryLifecycleRaceClassifications(void) {
  const InumaRendererLifecycleKind lifecycle_kinds[] = {
      InumaRendererLifecycleTrackChange,
      InumaRendererLifecycleSizeReset,
      InumaRendererLifecycleDispose,
  };
  for (size_t index = 0;
       index < sizeof(lifecycle_kinds) / sizeof(lifecycle_kinds[0]); index++) {
    RepeatBoundarySimulation post_fire;
    InitializeSimulation(&post_fire);
    const uint64_t repeat_ns = BuildThroughGraceAdmission(&post_fire);
    SimulatePlatformTurnFire(&post_fire, repeat_ns + 3000000);
    assert(post_fire.current_repeat_retry_fired);
    SimulateLifecycleClear(&post_fire, lifecycle_kinds[index]);
    AssertTerminal(&post_fire);
    assert(post_fire.retry_fires == 1);
    assert(post_fire.retry_copies == 0);
    assert(post_fire.retry_fired_lifecycle_preemptions == 1);
    assert(post_fire.retry_stale_fires == 0);
  }

  RepeatBoundarySimulation raster_preempted;
  InitializeSimulation(&raster_preempted);
  const uint64_t raster_repeat_ns =
      BuildThroughGraceAdmission(&raster_preempted);
  uint64_t raster_ns = raster_repeat_ns + kDisplaySixtyHzNs;
  assert(!SimulateRasterCopy(&raster_preempted, raster_ns));
  assert(raster_preempted.retry_raster_preemptions_before_fire == 1);
  AssertSlots(&raster_preempted, 4, 5, 0);
  SimulatePlatformTurnFire(&raster_preempted, raster_ns + 1000000);
  assert(raster_preempted.retry_stale_fires == 1);
  DrainSimulation(&raster_preempted, &raster_ns, kDisplaySixtyHzNs);
  AssertCopiedSequence(&raster_preempted, 5);

  RepeatBoundarySimulation schedule_race;
  InitializeSimulation(&schedule_race);
  const uint64_t schedule_repeat_ns =
      BuildThroughRepeatScheduleRequest(&schedule_race);
  assert(schedule_race.retry_schedule_requested);
  SimulateLifecycleClear(&schedule_race,
                         InumaRendererLifecycleTrackChange);
  assert(!SimulateScheduleRetry(&schedule_race, schedule_repeat_ns + 1));
  AssertTerminal(&schedule_race);
  assert(schedule_race.retry_schedule_attempts == 1);
  // Lifecycle invalidated the request before scheduler method entry. The
  // renderer still owns one repeat schedule at entry and immediately closes
  // it as stale without creating a platform-turn owner.
  assert(schedule_race.retry_schedules == 1);
  assert(schedule_race.retry_method_entry_stales == 1);
  assert(schedule_race.retry_platform_turn_dispatches == 0);
  assert(schedule_race.retry_platform_turn_predispatch_stales == 0);
  assert(schedule_race.retry_stale_fires == 1);
  assert(schedule_race.retry_fires == 0);
}
static void TestRetryPlatformLatencyAndRasterStallSweep(void) {
  const uint64_t platform_turn_latencies_ns[] = {
      250000, 5000000, 18000000, 35000000,
  };
  const size_t stalled_display_opportunities[] = {0, 1, 3};
  for (size_t latency = 0;
       latency < sizeof(platform_turn_latencies_ns) /
                     sizeof(platform_turn_latencies_ns[0]);
       latency++) {
    for (size_t stalls = 0;
         stalls < sizeof(stalled_display_opportunities) /
                      sizeof(stalled_display_opportunities[0]);
         stalls++) {
      RepeatBoundarySimulation simulation;
      InitializeSimulation(&simulation);
      const uint64_t repeat_ns = BuildThroughGraceAdmission(&simulation);
      uint64_t raster_ns = CopyRetryAndAssertShift(
          &simulation, repeat_ns, platform_turn_latencies_ns[latency],
          stalled_display_opportunities[stalls]);
      assert(raster_ns - repeat_ns >=
             (stalled_display_opportunities[stalls] + 1) *
                 kDisplaySixtyHzNs);
      raster_ns = CopyFollowingFrameAndAssertDrain(&simulation, raster_ns);
      DrainSimulation(&simulation, &raster_ns, kDisplaySixtyHzNs);
      AssertCopiedSequence(&simulation, 5);
    }
  }
}
static void TestExactTenureStateCasesAtThirtyAndSixtyHzRaster(void) {
  const uint64_t raster_periods_ns[] = {kRasterThirtyHzNs,
                                        kDisplaySixtyHzNs};
  const uint64_t boundary_tenures_ns[] = {
      18750000, 19000000, 19775916, 19999999, 20000000, 20250000,
  };
  uint64_t normal_hold_repeats = 0;
  uint64_t extended_repeats = 0;
  uint64_t boundary_bypasses = 0;
  uint64_t grace_admits = 0;
  uint64_t grace_shifts = 0;
  uint64_t grace_drains = 0;
  for (size_t cadence = 0;
       cadence < sizeof(raster_periods_ns) /
                     sizeof(raster_periods_ns[0]);
       cadence++) {
    const uint64_t raster_period_ns = raster_periods_ns[cadence];
    for (size_t boundary = 0;
         boundary < sizeof(boundary_tenures_ns) /
                        sizeof(boundary_tenures_ns[0]);
         boundary++) {
        const uint64_t tenure_ns = boundary_tenures_ns[boundary];
        const uint64_t origin_ns = 2000000000;
        const uint64_t warm_copy_ns = origin_ns + raster_period_ns;
        RepeatBoundarySimulation simulation;
        InitializeSimulation(&simulation);
        SimulateSourceArrival(&simulation, 1, origin_ns);
        assert(!SimulateRasterCopy(&simulation, warm_copy_ns));
        SimulateSourceArrival(&simulation, 2, warm_copy_ns + 1000000);
        SimulateSourceArrival(&simulation, 3, warm_copy_ns + 2000000);
        const uint64_t predecessor_copy_ns =
            warm_copy_ns + raster_period_ns;
        assert(!SimulateRasterCopy(&simulation, predecessor_copy_ns));
        AssertSlots(&simulation, 3, 0, 0);
        SimulateSourceArrival(&simulation, 4, predecessor_copy_ns + 1);

        uint64_t raster_ns = predecessor_copy_ns + tenure_ns;
        const bool repeated = SimulateRasterCopy(&simulation, raster_ns);
        assert(repeated == (tenure_ns < 20000000));
        if (repeated) {
          // The platform-turn notification schedules a later raster request;
          // it does not synchronously copy. Exercise an arrival while the
          // deferred frame waits for the next 30/60 Hz raster boundary.
          ScheduleAndDispatchRetry(&simulation, raster_ns + 1);
          SimulateSourceArrival(&simulation, 5, raster_ns + 1000000);
          AssertSlots(&simulation, 3, 4, 5);
          const uint64_t grace_ready_ns = simulation.grace_ready_ns;
          SimulatePlatformTurnFire(&simulation, raster_ns + 2000000);
          raster_ns += raster_period_ns;
          assert(!SimulateRasterCopy(&simulation, raster_ns));
          AssertSlots(&simulation, 4, 5, 0);
          assert(simulation.primary_ready_ns == grace_ready_ns);
        }
        DrainSimulation(&simulation, &raster_ns, raster_period_ns);
        AssertCopiedSequence(&simulation, repeated ? 5 : 4);
        normal_hold_repeats += simulation.normal_hold_repeats;
        extended_repeats += simulation.extended_repeats;
        boundary_bypasses += simulation.boundary_bypasses;
        grace_admits += simulation.grace_admits;
        grace_shifts += simulation.grace_shifts;
        grace_drains += simulation.grace_drains;
        InitializeSimulation(&simulation);
        assert(simulation.copied_count == 0);
        assert(!simulation.current_available);
    }
  }
  assert(normal_hold_repeats > 0);
  assert(extended_repeats > 0);
  assert(boundary_bypasses > 0);
  assert(grace_admits > 0);
  assert(grace_admits == grace_shifts);
  assert(grace_shifts == grace_drains);
}

static int64_t DeterministicSourceJitterNs(size_t frame_index,
                                           uint64_t amplitude_ns) {
  switch (frame_index % 4) {
  case 0:
    return -(int64_t)amplitude_ns;
  case 2:
    return (int64_t)amplitude_ns;
  default:
    return 0;
  }
}

static uint64_t SourceReadyNs(uint64_t origin_ns, uint64_t phase_ns,
                              size_t frame_index,
                              uint64_t jitter_amplitude_ns) {
  const int64_t ideal_ns =
      (int64_t)(origin_ns + phase_ns +
                (uint64_t)frame_index * kSourceThirtyHzNs);
  const int64_t ready_ns =
      ideal_ns +
      DeterministicSourceJitterNs(frame_index, jitter_amplitude_ns);
  assert(ready_ns > 0);
  return (uint64_t)ready_ns;
}

static void TestQueueAcceptanceRequiresWarmCopy(void) {
  RepeatBoundarySimulation simulation;
  InitializeSimulation(&simulation);
  const uint64_t origin_ns = 2500000000;
  SimulateSourceArrival(&simulation, 1, origin_ns);
  SimulateSourceArrival(&simulation, 2, origin_ns + 1000000);
  AssertSlots(&simulation, 1, 0, 0);
  assert(simulation.last_copy_ns == 0);
  assert(simulation.source_count == 2);
  assert(simulation.accepted_count == 1);
  assert(simulation.coalesced_frames == 1);
  assert(simulation.overflows == 0);

  uint64_t raster_ns = origin_ns + kDisplaySixtyHzNs;
  assert(!SimulateRasterCopy(&simulation, raster_ns));
  SimulateSourceArrival(&simulation, 3, raster_ns + 1000000);
  SimulateSourceArrival(&simulation, 4, raster_ns + 2000000);
  AssertSlots(&simulation, 3, 4, 0);
  assert(simulation.last_copy_ns > 0);
  raster_ns += kDisplaySixtyHzNs;
  assert(!SimulateRasterCopy(&simulation, raster_ns));
  DrainSimulation(&simulation, &raster_ns, kDisplaySixtyHzNs);
  AssertTerminal(&simulation);
  assert(simulation.copied_count == 3);
  assert(simulation.copied_frames[0] == 1);
  assert(simulation.copied_frames[1] == 3);
  assert(simulation.copied_frames[2] == 4);
  assert(!ContainsFrame(simulation.copied_frames, simulation.copied_count, 2));
}

static void TestTwoGenerationCopiedBufferHoldLifetime(void) {
  RepeatBoundarySimulation simulation;
  InitializeSimulation(&simulation);
  uint64_t raster_ns = 3500000000;
  for (uint64_t frame = 1; frame <= 4; frame++) {
    SimulateSourceArrival(&simulation, frame, raster_ns + 1000000);
    raster_ns += kDisplaySixtyHzNs;
    assert(!SimulateRasterCopy(&simulation, raster_ns));
    assert(NewestHeldBufferFrame(&simulation) == frame);
    assert(simulation.held_buffer_count == (frame < 2 ? frame : 2));
    assert(simulation.copied_buffer_second_next_releases ==
           (frame > 2 ? frame - 2 : 0));
  }
  assert(simulation.held_buffer_frames[simulation.held_buffer_head] == 3);
  assert(NewestHeldBufferFrame(&simulation) == 4);
  AssertCopiedSequence(&simulation, 4);
  ReleaseAllHeldBuffersForLifecycle(&simulation);
  assert(simulation.held_buffer_count == 0);
  assert(simulation.copied_buffer_holds == 4);
  assert(simulation.copied_buffer_second_next_releases == 2);
  assert(simulation.copied_buffer_lifecycle_releases == 2);
  AssertTerminal(&simulation);
}

static void TestSyntheticSchedulerStallStateProofThirtyHzSourceSixtyHzDisplay(
    void) {
  // Deterministic state proof for selected scheduler stalls. It does not claim
  // exhaustive Flutter-engine, Core Animation, GPU, or display-server timing.
  const uint64_t jitter_amplitudes_ns[] = {0, 250000};
  const size_t source_frame_count = 5;
  const uint64_t origin_ns = 4000000000;
  for (uint64_t phase_ns = 0; phase_ns < kDisplaySixtyHzNs;
       phase_ns += 4000000) {
    for (size_t jitter = 0;
         jitter < sizeof(jitter_amplitudes_ns) /
                      sizeof(jitter_amplitudes_ns[0]);
         jitter++) {
      RepeatBoundarySimulation simulation;
      InitializeSimulation(&simulation);
      size_t next_source_index = 0;
      uint64_t next_display_ns = origin_ns;
      uint64_t next_platform_fire_ns = UINT64_MAX;
      const uint64_t platform_latency_ns =
          jitter == 0 ? 1000000 : 20000000;
      bool initial_repeat_seen = false;
      bool pressure_grace_admitted = false;
      uint64_t skipped_display_opportunities = 0;
      size_t event_count = 0;

      while (next_source_index < source_frame_count ||
             ActiveFrameCount(&simulation) > 0 ||
             simulation.retry_schedule_requested ||
             simulation.retry_platform_turn_pending ||
             simulation.retry_dispatched ||
             simulation.current_repeat_retry_fired) {
        assert(event_count++ < 256);
        const uint64_t next_source_ns =
            next_source_index < source_frame_count
                ? SourceReadyNs(origin_ns, phase_ns, next_source_index,
                                jitter_amplitudes_ns[jitter])
                : UINT64_MAX;
        if (next_source_ns <= next_platform_fire_ns &&
            next_source_ns <= next_display_ns) {
          SimulateSourceArrival(&simulation, next_source_index + 1,
                                next_source_ns);
          next_source_index += 1;
          pressure_grace_admitted = simulation.grace_admits > 0;
        } else if (next_platform_fire_ns <= next_display_ns) {
          SimulatePlatformTurnFire(&simulation, next_platform_fire_ns);
          next_platform_fire_ns = UINT64_MAX;
        } else {
          bool request_raster = simulation.current_frame == 1;
          request_raster =
              request_raster ||
              (simulation.current_frame == 2 &&
               simulation.primary_frame == 3);
          request_raster =
              request_raster ||
              (!initial_repeat_seen && simulation.current_frame == 3 &&
               simulation.current_rescue_promoted);
          request_raster =
              request_raster ||
              (pressure_grace_admitted &&
               !simulation.retry_schedule_requested &&
               !simulation.retry_platform_turn_pending &&
               !simulation.retry_dispatched &&
               (!simulation.current_repeat_deferred ||
                simulation.current_repeat_retry_fired));
          if (request_raster && simulation.current_available) {
            const bool repeated =
                SimulateRasterCopy(&simulation, next_display_ns);
            if (repeated) {
              initial_repeat_seen = true;
              ScheduleAndDispatchRetry(&simulation, next_display_ns + 1);
              next_platform_fire_ns =
                  next_display_ns + platform_latency_ns;
            }
          } else if (simulation.current_available) {
            skipped_display_opportunities += 1;
          }
          next_display_ns += kDisplaySixtyHzNs;
        }
        AssertUniqueOwnership(&simulation);
      }

      AssertCopiedSequence(&simulation, source_frame_count);
      assert(simulation.accepted_count == source_frame_count);
      assert(simulation.coalesced_frames == 0);
      assert(simulation.overflows == 0);
      assert(simulation.repeats > 0);
      assert(simulation.retry_schedules == simulation.repeats);
      assert(simulation.retry_fires == simulation.repeats);
      assert(simulation.retry_stale_fires == 0);
      assert(simulation.grace_admits == 1);
      assert(simulation.grace_shifts == 1);
      assert(simulation.grace_drains == 1);
      assert(skipped_display_opportunities >= 3);
    }
  }
}

static void TestThirtyHzSourceSixtyHzDisplayPhaseAndJitterSweep(void) {
  const uint64_t jitter_amplitudes_ns[] = {0, 250000, 750000};
  const size_t source_frame_count = 24;
  const uint64_t origin_ns = 3000000000;
  for (uint64_t phase_ns = 0; phase_ns < kDisplaySixtyHzNs;
       phase_ns += 500000) {
    for (size_t jitter = 0;
         jitter < sizeof(jitter_amplitudes_ns) /
                      sizeof(jitter_amplitudes_ns[0]);
         jitter++) {
      RepeatBoundarySimulation simulation;
      InitializeSimulation(&simulation);
      size_t next_source_index = 0;
      uint64_t next_display_ns = origin_ns;
      uint64_t previous_source_ns = 0;
      uint64_t previous_display_ns = 0;
      size_t event_count = 0;

      while (next_source_index < source_frame_count ||
             ActiveFrameCount(&simulation) > 0 ||
             simulation.retry_schedule_requested ||
             simulation.retry_platform_turn_pending ||
             simulation.retry_dispatched ||
             simulation.current_repeat_retry_fired) {
        assert(event_count++ < source_frame_count * 5);
        const uint64_t next_source_ns =
            next_source_index < source_frame_count
                ? SourceReadyNs(origin_ns, phase_ns, next_source_index,
                                jitter_amplitudes_ns[jitter])
                : UINT64_MAX;
        if (next_source_ns <= next_display_ns) {
          assert(previous_source_ns == 0 ||
                 next_source_ns > previous_source_ns);
          SimulateSourceArrival(&simulation, next_source_index + 1,
                                next_source_ns);
          previous_source_ns = next_source_ns;
          next_source_index += 1;
        } else {
          assert(previous_display_ns == 0 ||
                 next_display_ns - previous_display_ns ==
                     kDisplaySixtyHzNs);
          (void)SimulateRasterCopy(&simulation, next_display_ns);
          previous_display_ns = next_display_ns;
          next_display_ns += kDisplaySixtyHzNs;
        }
        AssertUniqueOwnership(&simulation);
      }

      AssertCopiedSequence(&simulation, source_frame_count);
      assert(simulation.accepted_count == source_frame_count);
      assert(simulation.repeats == 0);
      assert(simulation.retry_schedules == 0);
      assert(simulation.grace_admits == 0);
      assert(simulation.overflows == 0);
    }
  }
}


void InumaRunRendererQueueSimulationScenarios(void) {
  TestRetryUsesRasterCadenceAndPreservesGraceReadyTime();
  TestChainedEmergencyGraceSequence();
  TestGraceOccupiedRefusesWithoutOverwrite();
  TestLifecycleClearClassifications();
  TestSameIdentityABAPredispatchInvalidations();
  TestSameIdentityABAPostdispatchInvalidations();
  TestAsyncRetryLifecycleRaceClassifications();
  TestRetryPlatformLatencyAndRasterStallSweep();
  TestExactTenureStateCasesAtThirtyAndSixtyHzRaster();
  TestQueueAcceptanceRequiresWarmCopy();
  TestTwoGenerationCopiedBufferHoldLifetime();
  TestSyntheticSchedulerStallStateProofThirtyHzSourceSixtyHzDisplay();
  TestThirtyHzSourceSixtyHzDisplayPhaseAndJitterSweep();
}
