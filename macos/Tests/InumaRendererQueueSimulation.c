// Implements production-ordered scalar renderer state transitions for tests.

#include "InumaRendererQueueSimulation.h"

#include "InumaEmergencyGracePolicy.h"
#include "InumaRepeatBoundaryPolicy.h"

#include <assert.h>

enum {
  kMinimumHoldNs = 19000000,
};

bool ContainsFrame(const uint64_t *frames, size_t count,
                          uint64_t frame) {
  for (size_t index = 0; index < count; index++) {
    if (frames[index] == frame) {
      return true;
    }
  }
  return false;
}

static void AppendUniqueFrame(uint64_t *frames, size_t *count,
                              size_t capacity, uint64_t frame) {
  assert(frame > 0);
  assert(*count < capacity);
  assert(!ContainsFrame(frames, *count, frame));
  frames[(*count)++] = frame;
}

size_t ActiveFrameCount(const RepeatBoundarySimulation *simulation) {
  return (simulation->current_available ? 1u : 0u) +
         (simulation->primary_frame != 0 ? 1u : 0u) +
         (simulation->grace_frame != 0 ? 1u : 0u);
}

uint64_t NewestHeldBufferFrame(
    const RepeatBoundarySimulation *simulation) {
  assert(simulation->held_buffer_count > 0);
  const size_t index =
      (simulation->held_buffer_head + simulation->held_buffer_count - 1) % 2;
  return simulation->held_buffer_frames[index];
}

static void ReleaseOldestHeldBuffer(RepeatBoundarySimulation *simulation,
                                    bool lifecycle) {
  assert(simulation->held_buffer_count > 0);
  const size_t index = simulation->held_buffer_head;
  assert(simulation->held_buffer_frames[index] > 0);
  simulation->held_buffer_frames[index] = 0;
  simulation->held_buffer_started_ns[index] = 0;
  simulation->held_buffer_head = (simulation->held_buffer_head + 1) % 2;
  simulation->held_buffer_count -= 1;
  if (lifecycle) {
    simulation->copied_buffer_lifecycle_releases += 1;
  } else {
    simulation->copied_buffer_second_next_releases += 1;
  }
}

static void RetainCopiedBufferGeneration(RepeatBoundarySimulation *simulation,
                                         uint64_t frame,
                                         uint64_t copied_ns) {
  // These two slots model retained CVPixelBuffer generations only. They are
  // not additional logical-frame owners in AssertUniqueOwnership.
  if (simulation->held_buffer_count == 2) {
    ReleaseOldestHeldBuffer(simulation, false);
  }
  const size_t index =
      (simulation->held_buffer_head + simulation->held_buffer_count) % 2;
  simulation->held_buffer_frames[index] = frame;
  simulation->held_buffer_started_ns[index] = copied_ns;
  simulation->held_buffer_count += 1;
  simulation->copied_buffer_holds += 1;
}

void ReleaseAllHeldBuffersForLifecycle(
    RepeatBoundarySimulation *simulation) {
  while (simulation->held_buffer_count > 0) {
    ReleaseOldestHeldBuffer(simulation, true);
  }
  simulation->held_buffer_head = 0;
}

static void AssertHeldBufferBalance(
    const RepeatBoundarySimulation *simulation) {
  assert(simulation->held_buffer_count <= 2);
  assert(simulation->copied_buffer_holds ==
         simulation->copied_buffer_second_next_releases +
             simulation->copied_buffer_lifecycle_releases +
             simulation->held_buffer_count);
  for (size_t held = 0; held < simulation->held_buffer_count; held++) {
    const size_t index = (simulation->held_buffer_head + held) % 2;
    assert(simulation->held_buffer_frames[index] > 0);
    assert(simulation->held_buffer_started_ns[index] > 0);
    assert(ContainsFrame(simulation->copied_frames,
                         simulation->copied_count,
                         simulation->held_buffer_frames[index]));
  }
}

void AssertUniqueOwnership(
    const RepeatBoundarySimulation *simulation) {
  assert(simulation->current_available == (simulation->current_frame != 0));
  assert((simulation->current_frame == 0) ==
         (simulation->current_ready_ns == 0));
  assert((simulation->current_frame == 0) ==
         (simulation->current_renderer_identity == 0));
  assert((simulation->primary_frame == 0) ==
         (simulation->primary_ready_ns == 0));
  assert((simulation->primary_frame == 0) ==
         (simulation->primary_renderer_identity == 0));
  assert((simulation->grace_frame == 0) ==
         (simulation->grace_ready_ns == 0));
  assert((simulation->grace_frame == 0) ==
         (simulation->grace_renderer_identity == 0));
  assert(simulation->current_frame == 0 ||
         simulation->current_frame != simulation->primary_frame);
  assert(simulation->current_frame == 0 ||
         simulation->current_frame != simulation->grace_frame);
  assert(simulation->primary_frame == 0 ||
         simulation->primary_frame != simulation->grace_frame);
  assert(!simulation->primary_from_grace || simulation->primary_frame != 0);
  assert(!simulation->current_from_grace || simulation->current_available);
  const bool retry_request_still_current =
      simulation->retry_schedule_requested &&
      simulation->texture_registered &&
      simulation->retry_requested_renderer_state_generation ==
          simulation->renderer_state_generation;
  assert(!retry_request_still_current || simulation->current_available);
  assert(!retry_request_still_current ||
         simulation->current_repeat_deferred);
  assert(!retry_request_still_current ||
         simulation->retry_requested_renderer_identity ==
             simulation->current_renderer_identity);
  assert(!simulation->current_repeat_retry_fired ||
         simulation->current_available);
  assert(!simulation->current_repeat_retry_fired ||
         simulation->current_repeat_deferred);
  assert(!(simulation->retry_platform_turn_pending &&
           simulation->retry_dispatched));
  assert(simulation->retry_platform_turn_pending ==
         (simulation->retry_owned_renderer_identity != 0));
  assert(simulation->retry_platform_turn_pending ==
         (simulation->retry_owned_renderer_state_generation != 0));
  assert(simulation->retry_dispatched ==
         (simulation->retry_dispatched_renderer_identity != 0));
  assert(simulation->retry_dispatched ==
         (simulation->retry_dispatched_renderer_state_generation != 0));
  assert((simulation->retry_platform_turn_pending ||
          simulation->retry_dispatched) ==
         (simulation->retry_scheduled_ns != 0));
  assert(simulation->source_count ==
         simulation->accepted_count + simulation->coalesced_frames);
  assert(simulation->overflows <= simulation->coalesced_frames);
  assert(simulation->accepted_count ==
         simulation->copied_count + simulation->cleared_count +
             ActiveFrameCount(simulation));
  AssertHeldBufferBalance(simulation);

  for (size_t accepted = 0; accepted < simulation->accepted_count;
       accepted++) {
    const uint64_t frame = simulation->accepted_frames[accepted];
    size_t owners = 0;
    owners += simulation->current_frame == frame ? 1u : 0u;
    owners += simulation->primary_frame == frame ? 1u : 0u;
    owners += simulation->grace_frame == frame ? 1u : 0u;
    owners += ContainsFrame(simulation->copied_frames,
                            simulation->copied_count, frame)
                  ? 1u
                  : 0u;
    owners += ContainsFrame(simulation->cleared_frames,
                            simulation->cleared_count, frame)
                  ? 1u
                  : 0u;
    assert(owners == 1);
  }
}

void AssertSlots(const RepeatBoundarySimulation *simulation,
                        uint64_t current, uint64_t primary, uint64_t grace) {
  assert(simulation->current_frame == current);
  assert(simulation->primary_frame == primary);
  assert(simulation->grace_frame == grace);
  AssertUniqueOwnership(simulation);
}

static void RecordAcceptedFrame(RepeatBoundarySimulation *simulation,
                                uint64_t frame) {
  AppendUniqueFrame(simulation->accepted_frames, &simulation->accepted_count,
                    sizeof(simulation->accepted_frames) /
                        sizeof(simulation->accepted_frames[0]),
                    frame);
}

static void RecordSourceFrame(RepeatBoundarySimulation *simulation,
                              uint64_t frame) {
  AppendUniqueFrame(simulation->source_frames, &simulation->source_count,
                    sizeof(simulation->source_frames) /
                        sizeof(simulation->source_frames[0]),
                    frame);
}

static void RecordCopiedFrame(RepeatBoundarySimulation *simulation,
                              uint64_t frame) {
  AppendUniqueFrame(simulation->copied_frames, &simulation->copied_count,
                    sizeof(simulation->copied_frames) /
                        sizeof(simulation->copied_frames[0]),
                    frame);
}

static void RecordClearedFrame(RepeatBoundarySimulation *simulation,
                               uint64_t frame) {
  AppendUniqueFrame(simulation->cleared_frames, &simulation->cleared_count,
                    sizeof(simulation->cleared_frames) /
                        sizeof(simulation->cleared_frames[0]),
                    frame);
}

void SimulateSourceArrivalWithIdentity(
    RepeatBoundarySimulation *simulation, uint64_t frame,
    uint64_t renderer_identity, uint64_t ready_ns) {
  assert(frame > 0);
  assert(renderer_identity > 0);
  assert(ready_ns > 0);
  RecordSourceFrame(simulation, frame);
  const bool primary_queue_full =
      simulation->current_available && simulation->primary_frame != 0;
  if (!simulation->grace_burst_armed &&
      InumaEmergencyGraceShouldRearm(
          simulation->grace_frame != 0, primary_queue_full,
          simulation->primary_frame != 0 ? 1 : 0)) {
    simulation->grace_burst_armed = true;
    simulation->grace_burst_rearms += 1;
  }
  if (!simulation->current_available) {
    RecordAcceptedFrame(simulation, frame);
    simulation->current_frame = frame;
    simulation->current_renderer_identity = renderer_identity;
    simulation->current_ready_ns = ready_ns;
    simulation->current_available = true;
    simulation->current_rescue_promoted = false;
    simulation->current_from_grace = false;
    AssertUniqueOwnership(simulation);
    return;
  }
  const bool queue_has_capacity = simulation->last_copy_ns > 0 &&
                                  simulation->primary_frame == 0;
  if (queue_has_capacity) {
    RecordAcceptedFrame(simulation, frame);
    simulation->primary_frame = frame;
    simulation->primary_renderer_identity = renderer_identity;
    simulation->primary_ready_ns = ready_ns;
    simulation->primary_from_grace = false;
    AssertUniqueOwnership(simulation);
    return;
  }
  if (simulation->primary_frame != 0) {
    const InumaEmergencyGracePolicyDecision decision =
        InumaEmergencyGraceEvaluate((InumaEmergencyGracePolicyInput){
            .enabled = true,
            .primary_queue_full = true,
            .maximum_queued_frames = 1,
            .pending_frame_count = 1,
            .current_frame_repeat_deferred =
                simulation->current_repeat_deferred,
            .current_frame_rescue_promoted =
                simulation->current_rescue_promoted,
            .current_frame_awaits_copy = simulation->current_available,
            .current_ready_monotonic_ns = simulation->current_ready_ns,
            .primary_ready_monotonic_ns = simulation->primary_ready_ns,
            .checked_monotonic_ns = ready_ns,
            .minimum_hold_ns = kMinimumHoldNs,
            .grace_occupied = simulation->grace_frame != 0,
            .burst_armed = simulation->grace_burst_armed,
        });
    if (decision.eligible) {
      assert(simulation->grace_frame == 0);
      RecordAcceptedFrame(simulation, frame);
      simulation->grace_frame = frame;
      simulation->grace_renderer_identity = renderer_identity;
      simulation->grace_ready_ns = ready_ns;
      simulation->grace_burst_armed = false;
      simulation->grace_admits += 1;
      AssertUniqueOwnership(simulation);
      return;
    }
    if (decision.refuse_reason == InumaEmergencyGraceRefuseReasonOccupied) {
      simulation->grace_occupied_refusals += 1;
    } else if (decision.refuse_reason ==
               InumaEmergencyGraceRefuseReasonBurstNotRearmed) {
      simulation->grace_burst_not_rearmed_refusals += 1;
    }
    simulation->overflows += 1;
  }
  simulation->coalesced_frames += 1;
  AssertUniqueOwnership(simulation);
}

void SimulateSourceArrival(RepeatBoundarySimulation *simulation,
                           uint64_t frame, uint64_t ready_ns) {
  SimulateSourceArrivalWithIdentity(simulation, frame, frame, ready_ns);
}

bool SimulateScheduleRetry(RepeatBoundarySimulation *simulation,
                           uint64_t scheduled_ns) {
  assert(simulation->retry_schedule_requested);
  assert(!simulation->retry_platform_turn_pending);
  assert(!simulation->retry_dispatched);
  simulation->retry_schedule_attempts += 1;
  const bool notification_can_be_scheduled =
      simulation->texture_registered && simulation->current_available &&
      simulation->retry_requested_renderer_identity ==
          simulation->current_renderer_identity &&
      simulation->retry_requested_renderer_state_generation ==
          simulation->renderer_state_generation;
  simulation->retry_schedule_requested = false;
  simulation->retry_requested_renderer_identity = 0;
  simulation->retry_requested_renderer_state_generation = 0;
  // Production records the raster-repeat schedule/event at scheduler method
  // entry even if the first state recheck has already been invalidated.
  simulation->retry_schedules += 1;
  if (!notification_can_be_scheduled) {
    simulation->retry_method_entry_stales += 1;
    simulation->retry_stale_fires += 1;
    AssertUniqueOwnership(simulation);
    return false;
  }
  // Production records exactly one retry schedule/event at method entry.
  // The next platform-turn owner has not yet been dispatched and must recheck
  // the captured generation and renderer identity before queueing its block.
  simulation->retry_platform_turn_pending = true;
  simulation->retry_owned_renderer_identity =
      simulation->current_renderer_identity;
  simulation->retry_owned_renderer_state_generation =
      simulation->renderer_state_generation;
  simulation->retry_scheduled_ns = scheduled_ns;
  return true;
}

bool SimulatePlatformTurnDispatch(RepeatBoundarySimulation *simulation) {
  assert(simulation->retry_platform_turn_pending);
  assert(!simulation->retry_dispatched);
  const bool platform_turn_can_be_dispatched =
      simulation->texture_registered && simulation->current_available &&
      simulation->renderer_state_generation ==
          simulation->retry_owned_renderer_state_generation &&
      simulation->current_renderer_identity ==
          simulation->retry_owned_renderer_identity;
  simulation->retry_platform_turn_pending = false;
  if (!platform_turn_can_be_dispatched) {
    // The method-entry event is already owned. Production closes it as one
    // stale outcome when the platform-turn ownership recheck fails.
    simulation->retry_stale_fires += 1;
    simulation->retry_platform_turn_predispatch_stales += 1;
    simulation->retry_owned_renderer_identity = 0;
    simulation->retry_owned_renderer_state_generation = 0;
    simulation->retry_scheduled_ns = 0;
    AssertUniqueOwnership(simulation);
    return false;
  }
  simulation->retry_dispatched = true;
  simulation->retry_dispatched_renderer_identity =
      simulation->retry_owned_renderer_identity;
  simulation->retry_dispatched_renderer_state_generation =
      simulation->retry_owned_renderer_state_generation;
  simulation->retry_owned_renderer_identity = 0;
  simulation->retry_owned_renderer_state_generation = 0;
  simulation->retry_platform_turn_dispatches += 1;
  AssertUniqueOwnership(simulation);
  return true;
}

void SimulatePlatformTurnFire(RepeatBoundarySimulation *simulation,
                              uint64_t fired_ns) {
  assert(simulation->retry_dispatched);
  assert(fired_ns >= simulation->retry_scheduled_ns);
  const bool notification_is_current =
      simulation->texture_registered &&
      simulation->renderer_state_generation ==
          simulation->retry_dispatched_renderer_state_generation &&
      simulation->current_available &&
      simulation->current_renderer_identity ==
          simulation->retry_dispatched_renderer_identity;
  if (notification_is_current) {
    simulation->retry_fires += 1;
    if (simulation->current_repeat_deferred) {
      simulation->current_repeat_retry_fired = true;
    }
  } else {
    simulation->retry_stale_fires += 1;
  }
  simulation->retry_dispatched = false;
  simulation->retry_dispatched_renderer_identity = 0;
  simulation->retry_dispatched_renderer_state_generation = 0;
  simulation->retry_scheduled_ns = 0;
  AssertUniqueOwnership(simulation);
}

bool SimulateRasterCopy(RepeatBoundarySimulation *simulation,
                               uint64_t raster_ns) {
  if (!simulation->current_available) {
    return false;
  }
  const bool base_repeat_candidate =
      simulation->current_rescue_promoted && simulation->last_copy_ns > 0 &&
      raster_ns >= simulation->last_copy_ns;
  const uint64_t tenure_ns =
      base_repeat_candidate ? raster_ns - simulation->last_copy_ns : 0;
  const InumaRepeatBoundaryPolicyDecision decision =
      InumaRepeatBoundaryEvaluate((InumaRepeatBoundaryPolicyInput){
          .enabled = true,
          .base_repeat_candidate = base_repeat_candidate,
          .predecessor_tenure_ns = tenure_ns,
          .normal_minimum_hold_ns = kMinimumHoldNs,
          .repeat_boundary_ns = 20000000,
      });
  if (decision.evaluated) {
    if (decision.repeat) {
      const uint64_t predecessor_frame = simulation->last_copied_frame;
      const uint64_t deferred_frame = simulation->current_frame;
      assert(predecessor_frame > 0);
      assert(simulation->held_buffer_count > 0);
      assert(NewestHeldBufferFrame(simulation) == predecessor_frame);
      assert(!simulation->retry_schedule_requested);
      assert(!simulation->retry_platform_turn_pending);
      assert(!simulation->retry_dispatched);
      assert(!simulation->current_repeat_retry_fired);
      simulation->repeats += 1;
      simulation->repeat_predecessor_frames[simulation->repeats - 1] =
          predecessor_frame;
      simulation->repeat_deferred_frames[simulation->repeats - 1] =
          deferred_frame;
      simulation->normal_hold_repeats +=
          decision.extends_normal_hold ? 0 : 1;
      simulation->extended_repeats +=
          decision.extends_normal_hold ? 1 : 0;
      simulation->current_rescue_promoted = false;
      simulation->current_repeat_deferred = true;
      simulation->retry_schedule_requested = true;
      simulation->retry_requested_renderer_identity =
          simulation->current_renderer_identity;
      simulation->retry_requested_renderer_state_generation =
          simulation->renderer_state_generation;
      assert(simulation->last_copied_frame == predecessor_frame);
      assert(simulation->current_frame == deferred_frame);
      AssertUniqueOwnership(simulation);
      return true;
    }
    simulation->boundary_bypasses += 1;
  }

  assert(!simulation->retry_schedule_requested);
  if ((simulation->retry_platform_turn_pending &&
       simulation->retry_owned_renderer_identity ==
           simulation->current_renderer_identity) ||
      (simulation->retry_dispatched &&
       simulation->retry_dispatched_renderer_identity ==
           simulation->current_renderer_identity)) {
    simulation->retry_raster_preemptions_before_fire += 1;
  }
  if (simulation->current_repeat_retry_fired) {
    simulation->retry_copies += 1;
  }
  RetainCopiedBufferGeneration(simulation, simulation->current_frame,
                               raster_ns);
  RecordCopiedFrame(simulation, simulation->current_frame);
  simulation->last_copied_frame = simulation->current_frame;
  simulation->last_copy_ns = raster_ns;
  simulation->current_frame = 0;
  simulation->current_renderer_identity = 0;
  simulation->current_ready_ns = 0;
  simulation->current_available = false;
  simulation->current_rescue_promoted = false;
  simulation->current_repeat_deferred = false;
  simulation->current_repeat_retry_fired = false;
  simulation->current_from_grace = false;
  simulation->retry_requested_renderer_identity = 0;

  if (simulation->primary_frame != 0) {
    const uint64_t promoted_frame = simulation->primary_frame;
    const uint64_t promoted_renderer_identity =
        simulation->primary_renderer_identity;
    const uint64_t promoted_ready_ns = simulation->primary_ready_ns;
    const bool promoted_from_grace = simulation->primary_from_grace;
    simulation->primary_frame = 0;
    simulation->primary_renderer_identity = 0;
    simulation->primary_ready_ns = 0;
    simulation->primary_from_grace = false;
    if (simulation->grace_frame != 0) {
      assert(InumaEmergencyGraceShouldShift(true, 0));
      const uint64_t shifted_frame = simulation->grace_frame;
      const uint64_t shifted_renderer_identity =
          simulation->grace_renderer_identity;
      const uint64_t shifted_ready_ns = simulation->grace_ready_ns;
      simulation->primary_frame = simulation->grace_frame;
      simulation->primary_renderer_identity =
          simulation->grace_renderer_identity;
      simulation->primary_ready_ns = simulation->grace_ready_ns;
      simulation->primary_from_grace = true;
      simulation->grace_frame = 0;
      simulation->grace_renderer_identity = 0;
      simulation->grace_ready_ns = 0;
      simulation->grace_shifts += 1;
      assert(simulation->primary_frame == shifted_frame);
      assert(simulation->primary_renderer_identity ==
             shifted_renderer_identity);
      assert(simulation->primary_ready_ns == shifted_ready_ns);
    }
    simulation->current_frame = promoted_frame;
    simulation->current_renderer_identity = promoted_renderer_identity;
    simulation->current_ready_ns = promoted_ready_ns;
    simulation->current_available = true;
    simulation->current_rescue_promoted = true;
    simulation->current_from_grace = promoted_from_grace;
    if (InumaEmergencyGracePromotedFrameDrains(promoted_from_grace)) {
      simulation->grace_drains += 1;
    }
  } else {
    assert(simulation->grace_frame == 0);
  }
  AssertUniqueOwnership(simulation);
  return false;
}

void DrainSimulation(RepeatBoundarySimulation *simulation,
                            uint64_t *raster_ns,
                            uint64_t raster_period_ns) {
  assert(raster_period_ns > 0);
  for (size_t step = 0;
       step < 32 &&
       (simulation->current_available || simulation->primary_frame != 0 ||
        simulation->grace_frame != 0 ||
        simulation->retry_schedule_requested ||
        simulation->retry_platform_turn_pending ||
        simulation->retry_dispatched ||
        simulation->current_repeat_retry_fired);
       step++) {
    if (simulation->retry_schedule_requested) {
      SimulateScheduleRetry(simulation, *raster_ns + 1);
    }
    if (simulation->retry_platform_turn_pending) {
      SimulatePlatformTurnDispatch(simulation);
    }
    if (simulation->retry_dispatched) {
      SimulatePlatformTurnFire(simulation, *raster_ns + 1000000);
    }
    if (!simulation->current_available) {
      continue;
    }
    *raster_ns += raster_period_ns;
    (void)SimulateRasterCopy(simulation, *raster_ns);
  }
  assert(!simulation->current_available);
  assert(simulation->primary_frame == 0);
  assert(simulation->grace_frame == 0);
  assert(!simulation->retry_schedule_requested);
  assert(!simulation->retry_platform_turn_pending);
  assert(!simulation->retry_dispatched);
  assert(!simulation->current_repeat_retry_fired);
}

void SimulateLifecycleClear(RepeatBoundarySimulation *simulation,
                            InumaRendererLifecycleKind kind) {
  // An owned retry may still be awaiting the platform-turn recheck or may
  // already have a dispatched closure. Lifecycle cleanup invalidates either
  // captured generation; the corresponding phase must later close exactly
  // one stale outcome.
  // This state proof closes renderer logical ownership and the renderer's own
  // retained-buffer holds; it does not claim Flutter-engine or GPU ownership.
  if (simulation->current_repeat_retry_fired) {
    simulation->retry_fired_lifecycle_preemptions += 1;
    simulation->current_repeat_retry_fired = false;
  }
  if (simulation->current_available) {
    RecordClearedFrame(simulation, simulation->current_frame);
  }
  simulation->current_frame = 0;
  simulation->current_renderer_identity = 0;
  simulation->current_ready_ns = 0;
  simulation->current_available = false;
  simulation->current_rescue_promoted = false;
  simulation->current_repeat_deferred = false;
  // A grace-origin frame is counted as drained once it reaches current. The
  // production lifecycle clear metric counts only grace-owned queue slots.
  simulation->current_from_grace = false;
  if (simulation->primary_frame != 0) {
    RecordClearedFrame(simulation, simulation->primary_frame);
    simulation->grace_clears += simulation->primary_from_grace ? 1u : 0u;
  }
  simulation->primary_frame = 0;
  simulation->primary_renderer_identity = 0;
  simulation->primary_ready_ns = 0;
  simulation->primary_from_grace = false;
  if (simulation->grace_frame != 0) {
    RecordClearedFrame(simulation, simulation->grace_frame);
    simulation->grace_clears += 1;
  }
  simulation->grace_frame = 0;
  simulation->grace_renderer_identity = 0;
  simulation->grace_ready_ns = 0;
  simulation->renderer_state_generation += 1;
  simulation->grace_burst_armed = true;
  switch (kind) {
  case InumaRendererLifecycleTrackChange:
    simulation->lifecycle_track_changes += 1;
    break;
  case InumaRendererLifecycleSizeReset:
    simulation->lifecycle_size_resets += 1;
    break;
  case InumaRendererLifecycleDispose:
    simulation->lifecycle_disposes += 1;
    simulation->texture_registered = false;
    break;
  }
  ReleaseAllHeldBuffersForLifecycle(simulation);
  AssertUniqueOwnership(simulation);
}

void AssertTerminal(const RepeatBoundarySimulation *simulation) {
  AssertUniqueOwnership(simulation);
  assert(simulation->accepted_count ==
         simulation->copied_count + simulation->cleared_count);
  assert(simulation->repeats == simulation->retry_schedules);
  assert(simulation->retry_schedule_attempts == simulation->repeats);
  assert(simulation->retry_schedules ==
         simulation->retry_fires + simulation->retry_stale_fires);
  assert(simulation->retry_schedules ==
         simulation->retry_method_entry_stales +
             simulation->retry_platform_turn_dispatches +
             simulation->retry_platform_turn_predispatch_stales);
  assert(simulation->retry_platform_turn_predispatch_stales <=
         simulation->retry_stale_fires);
  assert(simulation->retry_method_entry_stales <=
         simulation->retry_stale_fires -
             simulation->retry_platform_turn_predispatch_stales);
  assert(simulation->retry_platform_turn_dispatches >=
         simulation->retry_fires);
  assert(simulation->retry_stale_fires ==
         simulation->retry_method_entry_stales +
             simulation->retry_platform_turn_predispatch_stales +
             (simulation->retry_platform_turn_dispatches -
              simulation->retry_fires));
  assert(simulation->retry_fires ==
         simulation->retry_copies +
             simulation->retry_fired_lifecycle_preemptions);
  assert(simulation->grace_admits ==
         simulation->grace_drains + simulation->grace_clears);
  assert(!simulation->current_available);
  assert(simulation->primary_frame == 0);
  assert(simulation->grace_frame == 0);
  assert(!simulation->retry_schedule_requested);
  assert(!simulation->retry_platform_turn_pending);
  assert(!simulation->retry_dispatched);
  assert(!simulation->current_repeat_retry_fired);
  AssertHeldBufferBalance(simulation);
}

void AssertCopiedSequence(const RepeatBoundarySimulation *simulation,
                                 size_t expected_count) {
  AssertTerminal(simulation);
  assert(simulation->copied_count == expected_count);
  assert(simulation->cleared_count == 0);
  for (size_t index = 0; index < expected_count; index++) {
    assert(simulation->copied_frames[index] == index + 1);
  }
  assert(simulation->overflows == 0);
}

void InitializeSimulation(RepeatBoundarySimulation *simulation) {
  *simulation = (RepeatBoundarySimulation){0};
  simulation->texture_registered = true;
  simulation->renderer_state_generation = 1;
  simulation->grace_burst_armed = true;
}
