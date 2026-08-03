// Scalar-only renderer queue/retry/lifetime simulation contract for tests.

#ifndef INUMA_RENDERER_QUEUE_SIMULATION_H_
#define INUMA_RENDERER_QUEUE_SIMULATION_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum {
  kSourceThirtyHzNs = 33333333,
  kRasterThirtyHzNs = 33333333,
  kDisplaySixtyHzNs = 16666667,
};

typedef enum {
  InumaRendererLifecycleTrackChange = 0,
  InumaRendererLifecycleSizeReset = 1,
  InumaRendererLifecycleDispose = 2,
} InumaRendererLifecycleKind;

typedef struct {
  uint64_t current_frame;
  uint64_t primary_frame;
  uint64_t grace_frame;
  uint64_t current_renderer_identity;
  uint64_t primary_renderer_identity;
  uint64_t grace_renderer_identity;
  uint64_t current_ready_ns;
  uint64_t primary_ready_ns;
  uint64_t grace_ready_ns;
  uint64_t last_copied_frame;
  uint64_t last_copy_ns;
  uint64_t source_frames[64];
  uint64_t accepted_frames[64];
  uint64_t copied_frames[64];
  uint64_t cleared_frames[64];
  uint64_t repeat_predecessor_frames[64];
  uint64_t repeat_deferred_frames[64];
  uint64_t held_buffer_frames[2];
  uint64_t held_buffer_started_ns[2];
  size_t source_count;
  size_t accepted_count;
  size_t copied_count;
  size_t cleared_count;
  size_t held_buffer_head;
  size_t held_buffer_count;
  bool current_available;
  bool current_rescue_promoted;
  bool current_repeat_deferred;
  bool current_from_grace;
  bool current_repeat_retry_fired;
  bool primary_from_grace;
  bool retry_schedule_requested;
  bool retry_platform_turn_pending;
  bool retry_dispatched;
  bool texture_registered;
  uint64_t renderer_state_generation;
  uint64_t retry_requested_renderer_identity;
  uint64_t retry_requested_renderer_state_generation;
  uint64_t retry_owned_renderer_identity;
  uint64_t retry_owned_renderer_state_generation;
  uint64_t retry_dispatched_renderer_identity;
  uint64_t retry_dispatched_renderer_state_generation;
  uint64_t retry_scheduled_ns;
  uint64_t repeats;
  uint64_t retry_schedules;
  uint64_t retry_fires;
  uint64_t retry_stale_fires;
  uint64_t retry_copies;
  uint64_t retry_schedule_attempts;
  uint64_t retry_method_entry_stales;
  uint64_t retry_platform_turn_dispatches;
  uint64_t retry_platform_turn_predispatch_stales;
  uint64_t retry_fired_lifecycle_preemptions;
  uint64_t retry_raster_preemptions_before_fire;
  uint64_t normal_hold_repeats;
  uint64_t extended_repeats;
  uint64_t boundary_bypasses;
  uint64_t grace_admits;
  uint64_t grace_shifts;
  uint64_t grace_drains;
  uint64_t grace_clears;
  uint64_t grace_occupied_refusals;
  uint64_t coalesced_frames;
  uint64_t overflows;
  uint64_t copied_buffer_holds;
  uint64_t copied_buffer_second_next_releases;
  uint64_t copied_buffer_lifecycle_releases;
  uint64_t lifecycle_track_changes;
  uint64_t lifecycle_size_resets;
  uint64_t lifecycle_disposes;
} RepeatBoundarySimulation;

bool ContainsFrame(const uint64_t *frames, size_t count, uint64_t frame);
size_t ActiveFrameCount(const RepeatBoundarySimulation *simulation);
uint64_t NewestHeldBufferFrame(
    const RepeatBoundarySimulation *simulation);
void ReleaseAllHeldBuffersForLifecycle(
    RepeatBoundarySimulation *simulation);
void AssertUniqueOwnership(const RepeatBoundarySimulation *simulation);
void AssertSlots(const RepeatBoundarySimulation *simulation, uint64_t current,
                 uint64_t primary, uint64_t grace);
void SimulateSourceArrival(RepeatBoundarySimulation *simulation,
                           uint64_t frame, uint64_t ready_ns);
void SimulateSourceArrivalWithIdentity(
    RepeatBoundarySimulation *simulation, uint64_t frame,
    uint64_t renderer_identity, uint64_t ready_ns);
bool SimulateScheduleRetry(RepeatBoundarySimulation *simulation,
                           uint64_t scheduled_ns);
bool SimulatePlatformTurnDispatch(RepeatBoundarySimulation *simulation);
void SimulatePlatformTurnFire(RepeatBoundarySimulation *simulation,
                              uint64_t fired_ns);
bool SimulateRasterCopy(RepeatBoundarySimulation *simulation,
                        uint64_t raster_ns);
void DrainSimulation(RepeatBoundarySimulation *simulation,
                     uint64_t *raster_ns, uint64_t raster_period_ns);
void SimulateLifecycleClear(RepeatBoundarySimulation *simulation,
                            InumaRendererLifecycleKind kind);
void AssertTerminal(const RepeatBoundarySimulation *simulation);
void AssertCopiedSequence(const RepeatBoundarySimulation *simulation,
                          size_t expected_count);
void InitializeSimulation(RepeatBoundarySimulation *simulation);

void InumaRunRendererQueueSimulationScenarios(void);

#endif  // INUMA_RENDERER_QUEUE_SIMULATION_H_
