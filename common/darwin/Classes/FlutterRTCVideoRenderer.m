#import "FlutterRTCVideoRenderer.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CGImage.h>
#import <TargetConditionals.h>
#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCYUVHelper.h>
#import <WebRTC/RTCYUVPlanarBuffer.h>
#import <WebRTC/RTCTracing.h>
#import <WebRTC/WebRTC.h>

#import <objc/runtime.h>
#include <math.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#import "FlutterWebRTCPlugin.h"
#import <os/lock.h>

#if TARGET_OS_OSX
#include "InumaDecoderBoundaryTrace.h"
#include "InumaDirectFrameDisplayRetryPolicy.h"
#include "InumaEmergencyGracePolicy.h"
#include "InumaFrameOwnershipPolicy.h"
#include "InumaMainRunLoopNotificationPolicy.h"
#include "InumaLowLatencyVideoPlayoutConfiguration.h"
#include "InumaPrerendererSmoothingConfiguration.h"
#include "InumaRepeatBoundaryPolicy.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/CADisplayLink.h>
#include <pthread/qos.h>
#include <sys/qos.h>

enum {
  // Covers a 30 FPS, 30-minute proof plus 20% startup/teardown headroom.
  kInumaTextureTraceCapacity = 65536,
  kInumaStockBGRAPoolMinimumBufferCount = 4,
  kInumaPendingTextureFrameCapacity = 1,
  kInumaCopiedBufferHoldCapacity = 2,
  // Use the same lower bound as the retained predecessor.  The 16 ms v37
  // boundary fired on ordinary one-refresh jitter and created a second raster
  // feedback phase; 19 ms leaves that common path to the normal notification
  // while preserving a bounded retry for the measured overdue tail.
  kInumaDirectFrameDisplayRetryMinimumAgeNs = 19 * NSEC_PER_MSEC,
};

typedef NS_ENUM(NSUInteger, InumaMacOSPixelMode) {
  InumaMacOSPixelModeStockBGRA = 0,
  InumaMacOSPixelModeNativeNV12 = 1,
};

typedef NS_ENUM(NSUInteger, InumaRenderQoSPolicy) {
  InumaRenderQoSPolicyInherit = 0,
  InumaRenderQoSPolicyUserInteractive = 1,
};

typedef NS_ENUM(NSUInteger, InumaRescueNotificationPhase) {
  InumaRescueNotificationPhaseDisplayLink = 0,
  InumaRescueNotificationPhasePlatformTurn = 1,
};

typedef NS_ENUM(uint8_t, InumaDirectFrameDisplayRetryOutcome) {
  InumaDirectFrameDisplayRetryOutcomePending = 0,
  InumaDirectFrameDisplayRetryOutcomeFired = 1,
  InumaDirectFrameDisplayRetryOutcomeStale = 2,
  InumaDirectFrameDisplayRetryOutcomeCancelled = 3,
};

typedef struct {
  qos_class_t before;
  qos_class_t after;
  bool apply_attempted;
  bool apply_succeeded;
} InumaRenderQoSObservation;

typedef struct {
  CVPixelBufferRef pixel_buffer;
  int64_t frame_timestamp_ns;
  uint64_t frame_generation;
  uint64_t ready_monotonic_ns;
  uint64_t emergency_grace_admitted_monotonic_ns;
  bool from_emergency_grace;
} InumaPendingTextureFrame;

typedef struct {
  bool enabled;
  uint64_t render_frames;
  uint64_t render_qos_sync_handoffs;
  uint64_t render_qos_work_item_creation_failures;
  uint64_t render_qos_owned_queue_entries;
  uint64_t render_qos_calling_thread_entries;
  uint64_t accepted_frames;
  uint64_t coalesced_frames;
  uint64_t frame_generation_assignments;
  uint64_t zero_timestamp_render_frames;
  uint64_t zero_timestamp_accepted_frames;
  uint64_t copy_calls;
  uint64_t copy_hits;
  uint64_t copy_misses;
  uint64_t source_cv_pixel_buffer_frames;
  uint64_t source_i420_frames;
  uint64_t source_nv12_frames;
  uint64_t source_bgra_frames;
  uint64_t source_other_pixel_format_frames;
  uint64_t native_nv12_frames;
  uint64_t native_nv12_fallback_frames;
  uint64_t texture_hold_applied;
  uint64_t stale_texture_notifications;
  uint64_t queued_frames;
  uint64_t queue_promotions;
  uint64_t queue_overflows;
  uint64_t queue_cleared_frames;
  uint64_t queue_max_depth;
  uint64_t rescue_hold_bypasses;
  uint64_t rescue_hold_preservations;
  uint64_t rescue_display_link_schedules;
  uint64_t rescue_display_link_fires;
  uint64_t rescue_display_link_cancellations;
  uint64_t rescue_display_link_fallbacks;
  uint64_t rescue_display_link_stale_fires;
  uint64_t rescue_display_link_callbacks;
  uint64_t rescue_display_link_deferrals;
  uint64_t direct_frame_display_retry_schedules;
  uint64_t direct_frame_display_retry_callbacks;
  uint64_t direct_frame_display_retry_deferrals;
  uint64_t direct_frame_display_retry_fires;
  uint64_t direct_frame_display_retry_cancellations;
  uint64_t direct_frame_display_retry_stale_fires;
  uint64_t direct_frame_display_retry_create_failures;
  uint64_t direct_frame_display_retry_link_creations;
  uint64_t direct_frame_display_retry_link_reuses;
  uint64_t direct_frame_display_retry_link_arms;
  uint64_t direct_frame_display_retry_link_pauses;
  uint64_t direct_frame_display_retry_link_invalidations;
  uint64_t direct_frame_display_retry_link_abandoned_creations;
  uint64_t direct_frame_display_retry_notifications;
  uint64_t main_run_loop_notification_source_create_attempts;
  uint64_t main_run_loop_notification_source_creations;
  uint64_t main_run_loop_notification_source_create_failures;
  uint64_t main_run_loop_notification_source_registrations;
  uint64_t main_run_loop_notification_source_registration_failures;
  uint64_t main_run_loop_notification_source_signals;
  uint64_t main_run_loop_notification_run_loop_wakes;
  uint64_t main_run_loop_notification_callbacks;
  uint64_t main_run_loop_notification_current_fires;
  uint64_t main_run_loop_notification_stale_closes;
  uint64_t main_run_loop_notification_empty_callbacks;
  uint64_t main_run_loop_notification_occupied_refusals;
  uint64_t main_run_loop_notification_invalid_owner_refusals;
  uint64_t main_run_loop_notification_source_unavailable_fallbacks;
  uint64_t main_run_loop_notification_successor_rearms;
  uint64_t main_run_loop_notification_lifecycle_closes;
  uint64_t main_run_loop_notification_source_removals;
  uint64_t main_run_loop_notification_source_invalidations;
  uint64_t main_run_loop_notification_off_main_callbacks;
  uint64_t texture_notification_platform_turn_schedules;
  uint64_t texture_notification_platform_turn_fires;
  uint64_t texture_notification_platform_turn_last_schedule_offset_ns;
  uint64_t texture_notification_platform_turn_last_fire_offset_ns;
  uint64_t render_qos_observations;
  uint64_t render_qos_apply_attempts;
  uint64_t render_qos_apply_successes;
  uint64_t render_qos_apply_failures;
  uint64_t render_qos_before_unspecified;
  uint64_t render_qos_before_background;
  uint64_t render_qos_before_utility;
  uint64_t render_qos_before_default;
  uint64_t render_qos_before_user_initiated;
  uint64_t render_qos_before_user_interactive;
  uint64_t render_qos_after_user_interactive;
  uint64_t render_qos_after_not_user_interactive;
  uint64_t strict_hold_timer_created;
  uint64_t strict_hold_timer_fired;
  uint64_t strict_hold_timer_cancelled;
  uint64_t strict_hold_timer_create_failures;
  uint64_t strict_hold_timer_coalesced_existing;
  uint64_t strict_hold_timer_stale_before_ownership;
  uint64_t stock_bgra_pool_create_failures;
  uint64_t stock_bgra_pool_buffer_requests;
  uint64_t stock_bgra_pool_buffer_failures;
  uint64_t copied_buffer_holds;
  uint64_t copied_buffer_second_next_copy_releases;
  uint64_t copied_buffer_lifecycle_releases;
  uint64_t raster_repeat_guard_eligible_copy_calls;
  uint64_t raster_repeat_guard_repeats;
  uint64_t raster_repeat_guard_missing_predecessor;
  uint64_t raster_repeat_guard_retry_unavailable;
  uint64_t raster_repeat_platform_retry_schedules;
  uint64_t raster_repeat_platform_retry_fires;
  uint64_t raster_repeat_platform_retry_stale_fires;
  uint64_t raster_repeat_boundary_evaluations;
  uint64_t raster_repeat_boundary_applies;
  uint64_t raster_repeat_boundary_extended_applies;
  uint64_t raster_repeat_boundary_bypasses;
  uint64_t emergency_grace_eligible_frames;
  uint64_t emergency_grace_admits;
  uint64_t emergency_grace_admit_repeat_deferred;
  uint64_t emergency_grace_admit_overdue_copy;
  uint64_t emergency_grace_shifts;
  uint64_t emergency_grace_drains;
  uint64_t emergency_grace_refuses;
  uint64_t emergency_grace_clears;
  uint64_t emergency_grace_would_have_overflows;
  uint64_t emergency_grace_max_occupancy;
  uint64_t emergency_grace_refuse_not_repeat_deferred;
  uint64_t emergency_grace_refuse_primary_below_minimum_age;
  uint64_t emergency_grace_refuse_occupied;
  uint64_t emergency_grace_refuse_queue_shape;
  uint64_t emergency_grace_refuse_conversion_failure;
  uint64_t emergency_grace_refuse_burst_not_rearmed;
  uint64_t emergency_grace_burst_rearms;
  uint64_t sample_capacity_exhaustions;
  uint64_t conversion_samples[kInumaTextureTraceCapacity];
  uint64_t render_lock_wait_samples[kInumaTextureTraceCapacity];
  uint64_t copy_lock_wait_samples[kInumaTextureTraceCapacity];
  uint64_t copy_ready_age_samples[kInumaTextureTraceCapacity];
  uint64_t texture_notify_dispatch_samples[kInumaTextureTraceCapacity];
  uint64_t texture_notify_samples[kInumaTextureTraceCapacity];
  uint64_t texture_hold_delay_samples[kInumaTextureTraceCapacity];
  int64_t texture_hold_frame_timestamp_ns_samples[kInumaTextureTraceCapacity];
  uint64_t texture_hold_frame_generation_samples[kInumaTextureTraceCapacity];
  uint64_t texture_notify_event_offset_samples[kInumaTextureTraceCapacity];
  int64_t texture_notify_frame_timestamp_ns_samples[kInumaTextureTraceCapacity];
  uint64_t texture_notify_frame_generation_samples[kInumaTextureTraceCapacity];
  uint64_t texture_notify_scheduled_delay_samples[kInumaTextureTraceCapacity];
  uint64_t texture_notify_deadline_lateness_samples[kInumaTextureTraceCapacity];
  uint64_t queue_wait_samples[kInumaTextureTraceCapacity];
  uint64_t queue_enqueue_event_offset_samples[kInumaTextureTraceCapacity];
  int64_t queue_enqueue_frame_timestamp_ns_samples[kInumaTextureTraceCapacity];
  uint64_t queue_enqueue_frame_generation_samples[kInumaTextureTraceCapacity];
  uint64_t queue_promote_event_offset_samples[kInumaTextureTraceCapacity];
  int64_t queue_promote_frame_timestamp_ns_samples[kInumaTextureTraceCapacity];
  uint64_t queue_promote_frame_generation_samples[kInumaTextureTraceCapacity];
  int64_t rescue_hold_bypass_frame_timestamp_ns_samples
      [kInumaTextureTraceCapacity];
  uint64_t rescue_hold_bypass_frame_generation_samples
      [kInumaTextureTraceCapacity];
  int64_t rescue_hold_preservation_frame_timestamp_ns_samples
      [kInumaTextureTraceCapacity];
  uint64_t rescue_hold_preservation_frame_generation_samples
      [kInumaTextureTraceCapacity];
  uint64_t rescue_display_link_schedule_offset_samples
      [kInumaTextureTraceCapacity];
  uint64_t rescue_display_link_fire_offset_samples[kInumaTextureTraceCapacity];
  uint64_t rescue_display_link_presentation_ack_samples
      [kInumaTextureTraceCapacity];
  uint64_t rescue_display_link_callback_count_samples
      [kInumaTextureTraceCapacity];
  int64_t rescue_display_link_frame_timestamp_ns_samples
      [kInumaTextureTraceCapacity];
  uint64_t rescue_display_link_frame_generation_samples
      [kInumaTextureTraceCapacity];
  uint64_t direct_frame_display_retry_schedule_offset_samples
      [kInumaTextureTraceCapacity];
  uint64_t direct_frame_display_retry_callback_offset_samples
      [kInumaTextureTraceCapacity];
  uint64_t direct_frame_display_retry_callback_count_samples
      [kInumaTextureTraceCapacity];
  uint64_t direct_frame_display_retry_notification_offset_samples
      [kInumaTextureTraceCapacity];
  int64_t direct_frame_display_retry_frame_timestamp_ns_samples
      [kInumaTextureTraceCapacity];
  uint64_t direct_frame_display_retry_frame_generation_samples
      [kInumaTextureTraceCapacity];
  uint8_t direct_frame_display_retry_outcome_samples
      [kInumaTextureTraceCapacity];
  uint64_t main_run_loop_notification_arm_offset_samples
      [kInumaTextureTraceCapacity];
  uint64_t main_run_loop_notification_callback_offset_samples
      [kInumaTextureTraceCapacity];
  uint64_t main_run_loop_notification_callback_duration_samples
      [kInumaTextureTraceCapacity];
  int64_t main_run_loop_notification_frame_timestamp_ns_samples
      [kInumaTextureTraceCapacity];
  uint64_t main_run_loop_notification_frame_generation_samples
      [kInumaTextureTraceCapacity];
  uint8_t main_run_loop_notification_outcome_samples
      [kInumaTextureTraceCapacity];
  uint64_t strict_hold_timer_deadline_offset_samples
      [kInumaTextureTraceCapacity];
  uint64_t strict_hold_timer_fire_offset_samples[kInumaTextureTraceCapacity];
  int64_t strict_hold_timer_frame_timestamp_ns_samples
      [kInumaTextureTraceCapacity];
  uint64_t strict_hold_timer_frame_generation_samples
      [kInumaTextureTraceCapacity];
  uint64_t render_event_offset_samples[kInumaTextureTraceCapacity];
  int64_t render_frame_timestamp_ns_samples[kInumaTextureTraceCapacity];
  uint64_t render_frame_generation_samples[kInumaTextureTraceCapacity];
  uint8_t render_outcome_samples[kInumaTextureTraceCapacity];
  uint64_t coalesced_pending_age_samples[kInumaTextureTraceCapacity];
  uint64_t copy_event_offset_samples[kInumaTextureTraceCapacity];
  int64_t copy_frame_timestamp_ns_samples[kInumaTextureTraceCapacity];
  uint64_t copy_frame_generation_samples[kInumaTextureTraceCapacity];
  uint64_t raster_repeat_event_offset_samples[kInumaTextureTraceCapacity];
  int64_t raster_repeat_predecessor_frame_timestamp_ns_samples
      [kInumaTextureTraceCapacity];
  uint64_t raster_repeat_predecessor_frame_generation_samples
      [kInumaTextureTraceCapacity];
  int64_t raster_repeat_deferred_frame_timestamp_ns_samples
      [kInumaTextureTraceCapacity];
  uint64_t raster_repeat_deferred_frame_generation_samples
      [kInumaTextureTraceCapacity];
  uint64_t raster_repeat_predecessor_tenure_samples
      [kInumaTextureTraceCapacity];
  uint64_t raster_repeat_boundary_event_offset_samples
      [kInumaTextureTraceCapacity];
  int64_t raster_repeat_boundary_predecessor_frame_timestamp_ns_samples
      [kInumaTextureTraceCapacity];
  uint64_t raster_repeat_boundary_predecessor_frame_generation_samples
      [kInumaTextureTraceCapacity];
  int64_t raster_repeat_boundary_successor_frame_timestamp_ns_samples
      [kInumaTextureTraceCapacity];
  uint64_t raster_repeat_boundary_successor_frame_generation_samples
      [kInumaTextureTraceCapacity];
  uint64_t raster_repeat_boundary_predecessor_tenure_samples
      [kInumaTextureTraceCapacity];
  uint8_t raster_repeat_boundary_outcome_samples[kInumaTextureTraceCapacity];
  uint64_t raster_repeat_platform_retry_schedule_offset_samples
      [kInumaTextureTraceCapacity];
  uint64_t raster_repeat_platform_retry_fire_offset_samples
      [kInumaTextureTraceCapacity];
  int64_t raster_repeat_platform_retry_frame_timestamp_ns_samples
      [kInumaTextureTraceCapacity];
  uint64_t raster_repeat_platform_retry_frame_generation_samples
      [kInumaTextureTraceCapacity];
  uint64_t copied_buffer_second_next_copy_hold_samples
      [kInumaTextureTraceCapacity];
  uint64_t emergency_grace_admit_event_offset_samples
      [kInumaTextureTraceCapacity];
  int64_t emergency_grace_admit_frame_timestamp_ns_samples
      [kInumaTextureTraceCapacity];
  uint64_t emergency_grace_admit_frame_generation_samples
      [kInumaTextureTraceCapacity];
  int64_t emergency_grace_admit_current_frame_timestamp_ns_samples
      [kInumaTextureTraceCapacity];
  uint64_t emergency_grace_admit_current_frame_generation_samples
      [kInumaTextureTraceCapacity];
  int64_t emergency_grace_admit_primary_frame_timestamp_ns_samples
      [kInumaTextureTraceCapacity];
  uint64_t emergency_grace_admit_primary_frame_generation_samples
      [kInumaTextureTraceCapacity];
  uint64_t emergency_grace_admit_primary_age_samples
      [kInumaTextureTraceCapacity];
  uint8_t emergency_grace_admit_retry_fired_samples
      [kInumaTextureTraceCapacity];
  uint8_t emergency_grace_admit_overdue_copy_samples
      [kInumaTextureTraceCapacity];
  uint64_t emergency_grace_shift_event_offset_samples
      [kInumaTextureTraceCapacity];
  int64_t emergency_grace_shift_frame_timestamp_ns_samples
      [kInumaTextureTraceCapacity];
  uint64_t emergency_grace_shift_frame_generation_samples
      [kInumaTextureTraceCapacity];
  uint64_t emergency_grace_drain_event_offset_samples
      [kInumaTextureTraceCapacity];
  int64_t emergency_grace_drain_frame_timestamp_ns_samples
      [kInumaTextureTraceCapacity];
  uint64_t emergency_grace_drain_frame_generation_samples
      [kInumaTextureTraceCapacity];
  uint64_t emergency_grace_residence_samples[kInumaTextureTraceCapacity];
  uint64_t emergency_grace_refuse_event_offset_samples
      [kInumaTextureTraceCapacity];
  int64_t emergency_grace_refuse_frame_timestamp_ns_samples
      [kInumaTextureTraceCapacity];
  uint64_t emergency_grace_refuse_frame_generation_samples
      [kInumaTextureTraceCapacity];
  uint8_t emergency_grace_refuse_reason_samples[kInumaTextureTraceCapacity];
  uint64_t emergency_grace_refuse_current_age_samples
      [kInumaTextureTraceCapacity];
  uint64_t emergency_grace_refuse_primary_age_samples
      [kInumaTextureTraceCapacity];
  uint8_t emergency_grace_refuse_current_rescue_promoted_samples
      [kInumaTextureTraceCapacity];
  uint8_t emergency_grace_refuse_current_awaits_copy_samples
      [kInumaTextureTraceCapacity];
  NSUInteger conversion_count;
  NSUInteger render_lock_wait_count;
  NSUInteger copy_lock_wait_count;
  NSUInteger copy_ready_age_count;
  NSUInteger texture_notify_dispatch_count;
  NSUInteger texture_notify_count;
  NSUInteger texture_hold_delay_count;
  NSUInteger texture_notify_event_count;
  NSUInteger queue_wait_count;
  NSUInteger queue_enqueue_event_count;
  NSUInteger queue_promote_event_count;
  NSUInteger rescue_hold_bypass_count;
  NSUInteger rescue_hold_preservation_count;
  NSUInteger rescue_display_link_event_count;
  NSUInteger direct_frame_display_retry_event_count;
  NSUInteger main_run_loop_notification_event_count;
  NSUInteger strict_hold_timer_event_count;
  NSUInteger render_event_count;
  NSUInteger coalesced_pending_age_count;
  NSUInteger copy_event_count;
  NSUInteger raster_repeat_event_count;
  NSUInteger raster_repeat_boundary_event_count;
  NSUInteger raster_repeat_platform_retry_event_count;
  NSUInteger copied_buffer_second_next_copy_hold_count;
  NSUInteger emergency_grace_admit_event_count;
  NSUInteger emergency_grace_shift_event_count;
  NSUInteger emergency_grace_drain_event_count;
  NSUInteger emergency_grace_refuse_event_count;
} InumaTextureTrace;

static uint64_t InumaMonotonicNanoseconds(void) {
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static uint64_t InumaUptimeNanoseconds(void) {
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static uint64_t InumaDisplayLinkTimestampNanoseconds(
    CADisplayLink *displayLink) API_AVAILABLE(macos(14.0)) {
  const CFTimeInterval timestamp = displayLink.timestamp;
  if (!isfinite(timestamp) || timestamp <= 0.0 ||
      timestamp >= ((CFTimeInterval)UINT64_MAX / 1000000000.0)) {
    return 0;
  }
  return (uint64_t)(timestamp * 1000000000.0);
}

static bool InumaAppendTraceSample(uint64_t *samples, NSUInteger *count,
                                   uint64_t value,
                                   uint64_t *capacityExhaustions) {
  if (*count >= kInumaTextureTraceCapacity) {
    *capacityExhaustions += 1;
    return false;
  }
  samples[*count] = value;
  *count += 1;
  return true;
}

static NSUInteger InumaReserveTraceSample(NSUInteger *count,
                                          uint64_t *capacityExhaustions) {
  if (*count >= kInumaTextureTraceCapacity) {
    *capacityExhaustions += 1;
    return NSNotFound;
  }
  const NSUInteger index = *count;
  *count += 1;
  return index;
}

static void InumaRecordEmergencyGraceRefusalLocked(
    InumaTextureTrace *trace, uint64_t eventAt, uint64_t traceStartedAt,
    int64_t frameTimestampNs, uint64_t frameGeneration,
    InumaEmergencyGraceRefuseReason reason,
    uint64_t currentAgeNs, uint64_t primaryAgeNs,
    bool currentRescuePromoted, bool currentAwaitsCopy) {
  trace->emergency_grace_refuses += 1;
  switch (reason) {
  case InumaEmergencyGraceRefuseReasonNotRepeatDeferred:
    trace->emergency_grace_refuse_not_repeat_deferred += 1;
    break;
  case InumaEmergencyGraceRefuseReasonPrimaryBelowMinimumAge:
    trace->emergency_grace_refuse_primary_below_minimum_age += 1;
    break;
  case InumaEmergencyGraceRefuseReasonOccupied:
    trace->emergency_grace_refuse_occupied += 1;
    break;
  case InumaEmergencyGraceRefuseReasonConversionFailure:
    trace->emergency_grace_refuse_conversion_failure += 1;
    break;
  case InumaEmergencyGraceRefuseReasonBurstNotRearmed:
    trace->emergency_grace_refuse_burst_not_rearmed += 1;
    break;
  case InumaEmergencyGraceRefuseReasonQueueShape:
  case InumaEmergencyGraceRefuseReasonNone:
  default:
    trace->emergency_grace_refuse_queue_shape += 1;
    break;
  }
  const NSUInteger refuseIndex = InumaReserveTraceSample(
      &trace->emergency_grace_refuse_event_count,
      &trace->sample_capacity_exhaustions);
  if (refuseIndex == NSNotFound) {
    return;
  }
  trace->emergency_grace_refuse_event_offset_samples[refuseIndex] =
      traceStartedAt > 0 && eventAt >= traceStartedAt
          ? eventAt - traceStartedAt
          : 0;
  trace->emergency_grace_refuse_frame_timestamp_ns_samples[refuseIndex] =
      frameTimestampNs;
  trace->emergency_grace_refuse_frame_generation_samples[refuseIndex] =
      frameGeneration;
  trace->emergency_grace_refuse_reason_samples[refuseIndex] = reason;
  trace->emergency_grace_refuse_current_age_samples[refuseIndex] =
      currentAgeNs;
  trace->emergency_grace_refuse_primary_age_samples[refuseIndex] =
      primaryAgeNs;
  trace->emergency_grace_refuse_current_rescue_promoted_samples[refuseIndex] =
      currentRescuePromoted ? 1 : 0;
  trace->emergency_grace_refuse_current_awaits_copy_samples[refuseIndex] =
      currentAwaitsCopy ? 1 : 0;
}

static void InumaCopyTextureTraceLocked(InumaTextureTrace *destination,
                                        const InumaTextureTrace *source) {
  // Copy scalar state once, then only each populated sample prefix. Copying the
  // full capacity-safe structure under the renderer lock would make the
  // observer itself a source of strict-hold timer lateness.
  memcpy(destination, source, offsetof(InumaTextureTrace, conversion_samples));

#define INUMA_COPY_TRACE_ARRAY(field, count_field)                         \
  do {                                                                    \
    destination->count_field = source->count_field;                       \
    memcpy(destination->field, source->field,                             \
           source->count_field * sizeof(source->field[0]));               \
  } while (0)

  INUMA_COPY_TRACE_ARRAY(conversion_samples, conversion_count);
  INUMA_COPY_TRACE_ARRAY(render_lock_wait_samples, render_lock_wait_count);
  INUMA_COPY_TRACE_ARRAY(copy_lock_wait_samples, copy_lock_wait_count);
  INUMA_COPY_TRACE_ARRAY(copy_ready_age_samples, copy_ready_age_count);
  INUMA_COPY_TRACE_ARRAY(texture_notify_dispatch_samples,
                         texture_notify_dispatch_count);
  INUMA_COPY_TRACE_ARRAY(texture_notify_samples, texture_notify_count);
  INUMA_COPY_TRACE_ARRAY(texture_hold_delay_samples, texture_hold_delay_count);
  INUMA_COPY_TRACE_ARRAY(texture_hold_frame_timestamp_ns_samples,
                         texture_hold_delay_count);
  INUMA_COPY_TRACE_ARRAY(texture_hold_frame_generation_samples,
                         texture_hold_delay_count);
  INUMA_COPY_TRACE_ARRAY(texture_notify_event_offset_samples,
                         texture_notify_event_count);
  INUMA_COPY_TRACE_ARRAY(texture_notify_frame_timestamp_ns_samples,
                         texture_notify_event_count);
  INUMA_COPY_TRACE_ARRAY(texture_notify_frame_generation_samples,
                         texture_notify_event_count);
  INUMA_COPY_TRACE_ARRAY(texture_notify_scheduled_delay_samples,
                         texture_notify_event_count);
  INUMA_COPY_TRACE_ARRAY(texture_notify_deadline_lateness_samples,
                         texture_notify_event_count);
  INUMA_COPY_TRACE_ARRAY(queue_wait_samples, queue_wait_count);
  INUMA_COPY_TRACE_ARRAY(queue_enqueue_event_offset_samples,
                         queue_enqueue_event_count);
  INUMA_COPY_TRACE_ARRAY(queue_enqueue_frame_timestamp_ns_samples,
                         queue_enqueue_event_count);
  INUMA_COPY_TRACE_ARRAY(queue_enqueue_frame_generation_samples,
                         queue_enqueue_event_count);
  INUMA_COPY_TRACE_ARRAY(queue_promote_event_offset_samples,
                         queue_promote_event_count);
  INUMA_COPY_TRACE_ARRAY(queue_promote_frame_timestamp_ns_samples,
                         queue_promote_event_count);
  INUMA_COPY_TRACE_ARRAY(queue_promote_frame_generation_samples,
                         queue_promote_event_count);
  INUMA_COPY_TRACE_ARRAY(rescue_hold_bypass_frame_timestamp_ns_samples,
                         rescue_hold_bypass_count);
  INUMA_COPY_TRACE_ARRAY(rescue_hold_bypass_frame_generation_samples,
                         rescue_hold_bypass_count);
  INUMA_COPY_TRACE_ARRAY(rescue_hold_preservation_frame_timestamp_ns_samples,
                         rescue_hold_preservation_count);
  INUMA_COPY_TRACE_ARRAY(rescue_hold_preservation_frame_generation_samples,
                         rescue_hold_preservation_count);
  INUMA_COPY_TRACE_ARRAY(rescue_display_link_schedule_offset_samples,
                         rescue_display_link_event_count);
  INUMA_COPY_TRACE_ARRAY(rescue_display_link_fire_offset_samples,
                         rescue_display_link_event_count);
  INUMA_COPY_TRACE_ARRAY(rescue_display_link_presentation_ack_samples,
                         rescue_display_link_event_count);
  INUMA_COPY_TRACE_ARRAY(rescue_display_link_callback_count_samples,
                         rescue_display_link_event_count);
  INUMA_COPY_TRACE_ARRAY(rescue_display_link_frame_timestamp_ns_samples,
                         rescue_display_link_event_count);
  INUMA_COPY_TRACE_ARRAY(rescue_display_link_frame_generation_samples,
                         rescue_display_link_event_count);
  INUMA_COPY_TRACE_ARRAY(direct_frame_display_retry_schedule_offset_samples,
                         direct_frame_display_retry_event_count);
  INUMA_COPY_TRACE_ARRAY(direct_frame_display_retry_callback_offset_samples,
                         direct_frame_display_retry_event_count);
  INUMA_COPY_TRACE_ARRAY(direct_frame_display_retry_callback_count_samples,
                         direct_frame_display_retry_event_count);
  INUMA_COPY_TRACE_ARRAY(
      direct_frame_display_retry_notification_offset_samples,
      direct_frame_display_retry_event_count);
  INUMA_COPY_TRACE_ARRAY(direct_frame_display_retry_frame_timestamp_ns_samples,
                         direct_frame_display_retry_event_count);
  INUMA_COPY_TRACE_ARRAY(direct_frame_display_retry_frame_generation_samples,
                         direct_frame_display_retry_event_count);
  INUMA_COPY_TRACE_ARRAY(direct_frame_display_retry_outcome_samples,
                         direct_frame_display_retry_event_count);
  INUMA_COPY_TRACE_ARRAY(main_run_loop_notification_arm_offset_samples,
                         main_run_loop_notification_event_count);
  INUMA_COPY_TRACE_ARRAY(main_run_loop_notification_callback_offset_samples,
                         main_run_loop_notification_event_count);
  INUMA_COPY_TRACE_ARRAY(
      main_run_loop_notification_callback_duration_samples,
      main_run_loop_notification_event_count);
  INUMA_COPY_TRACE_ARRAY(
      main_run_loop_notification_frame_timestamp_ns_samples,
      main_run_loop_notification_event_count);
  INUMA_COPY_TRACE_ARRAY(
      main_run_loop_notification_frame_generation_samples,
      main_run_loop_notification_event_count);
  INUMA_COPY_TRACE_ARRAY(main_run_loop_notification_outcome_samples,
                         main_run_loop_notification_event_count);
  INUMA_COPY_TRACE_ARRAY(strict_hold_timer_deadline_offset_samples,
                         strict_hold_timer_event_count);
  INUMA_COPY_TRACE_ARRAY(strict_hold_timer_fire_offset_samples,
                         strict_hold_timer_event_count);
  INUMA_COPY_TRACE_ARRAY(strict_hold_timer_frame_timestamp_ns_samples,
                         strict_hold_timer_event_count);
  INUMA_COPY_TRACE_ARRAY(strict_hold_timer_frame_generation_samples,
                         strict_hold_timer_event_count);
  INUMA_COPY_TRACE_ARRAY(render_event_offset_samples, render_event_count);
  INUMA_COPY_TRACE_ARRAY(render_frame_timestamp_ns_samples,
                         render_event_count);
  INUMA_COPY_TRACE_ARRAY(render_frame_generation_samples, render_event_count);
  INUMA_COPY_TRACE_ARRAY(render_outcome_samples, render_event_count);
  INUMA_COPY_TRACE_ARRAY(coalesced_pending_age_samples,
                         coalesced_pending_age_count);
  INUMA_COPY_TRACE_ARRAY(copy_event_offset_samples, copy_event_count);
  INUMA_COPY_TRACE_ARRAY(copy_frame_timestamp_ns_samples, copy_event_count);
  INUMA_COPY_TRACE_ARRAY(copy_frame_generation_samples, copy_event_count);
  INUMA_COPY_TRACE_ARRAY(raster_repeat_event_offset_samples,
                         raster_repeat_event_count);
  INUMA_COPY_TRACE_ARRAY(
      raster_repeat_predecessor_frame_timestamp_ns_samples,
      raster_repeat_event_count);
  INUMA_COPY_TRACE_ARRAY(
      raster_repeat_predecessor_frame_generation_samples,
      raster_repeat_event_count);
  INUMA_COPY_TRACE_ARRAY(raster_repeat_deferred_frame_timestamp_ns_samples,
                         raster_repeat_event_count);
  INUMA_COPY_TRACE_ARRAY(raster_repeat_deferred_frame_generation_samples,
                         raster_repeat_event_count);
  INUMA_COPY_TRACE_ARRAY(raster_repeat_predecessor_tenure_samples,
                         raster_repeat_event_count);
  INUMA_COPY_TRACE_ARRAY(raster_repeat_boundary_event_offset_samples,
                         raster_repeat_boundary_event_count);
  INUMA_COPY_TRACE_ARRAY(
      raster_repeat_boundary_predecessor_frame_timestamp_ns_samples,
      raster_repeat_boundary_event_count);
  INUMA_COPY_TRACE_ARRAY(
      raster_repeat_boundary_predecessor_frame_generation_samples,
      raster_repeat_boundary_event_count);
  INUMA_COPY_TRACE_ARRAY(
      raster_repeat_boundary_successor_frame_timestamp_ns_samples,
      raster_repeat_boundary_event_count);
  INUMA_COPY_TRACE_ARRAY(
      raster_repeat_boundary_successor_frame_generation_samples,
      raster_repeat_boundary_event_count);
  INUMA_COPY_TRACE_ARRAY(raster_repeat_boundary_predecessor_tenure_samples,
                         raster_repeat_boundary_event_count);
  INUMA_COPY_TRACE_ARRAY(raster_repeat_boundary_outcome_samples,
                         raster_repeat_boundary_event_count);
  INUMA_COPY_TRACE_ARRAY(
      raster_repeat_platform_retry_schedule_offset_samples,
      raster_repeat_platform_retry_event_count);
  INUMA_COPY_TRACE_ARRAY(raster_repeat_platform_retry_fire_offset_samples,
                         raster_repeat_platform_retry_event_count);
  INUMA_COPY_TRACE_ARRAY(
      raster_repeat_platform_retry_frame_timestamp_ns_samples,
      raster_repeat_platform_retry_event_count);
  INUMA_COPY_TRACE_ARRAY(
      raster_repeat_platform_retry_frame_generation_samples,
      raster_repeat_platform_retry_event_count);
  INUMA_COPY_TRACE_ARRAY(copied_buffer_second_next_copy_hold_samples,
                         copied_buffer_second_next_copy_hold_count);
  INUMA_COPY_TRACE_ARRAY(emergency_grace_admit_event_offset_samples,
                         emergency_grace_admit_event_count);
  INUMA_COPY_TRACE_ARRAY(emergency_grace_admit_frame_timestamp_ns_samples,
                         emergency_grace_admit_event_count);
  INUMA_COPY_TRACE_ARRAY(emergency_grace_admit_frame_generation_samples,
                         emergency_grace_admit_event_count);
  INUMA_COPY_TRACE_ARRAY(
      emergency_grace_admit_current_frame_timestamp_ns_samples,
      emergency_grace_admit_event_count);
  INUMA_COPY_TRACE_ARRAY(
      emergency_grace_admit_current_frame_generation_samples,
      emergency_grace_admit_event_count);
  INUMA_COPY_TRACE_ARRAY(
      emergency_grace_admit_primary_frame_timestamp_ns_samples,
      emergency_grace_admit_event_count);
  INUMA_COPY_TRACE_ARRAY(
      emergency_grace_admit_primary_frame_generation_samples,
      emergency_grace_admit_event_count);
  INUMA_COPY_TRACE_ARRAY(emergency_grace_admit_primary_age_samples,
                         emergency_grace_admit_event_count);
  INUMA_COPY_TRACE_ARRAY(emergency_grace_admit_retry_fired_samples,
                         emergency_grace_admit_event_count);
  INUMA_COPY_TRACE_ARRAY(emergency_grace_admit_overdue_copy_samples,
                         emergency_grace_admit_event_count);
  INUMA_COPY_TRACE_ARRAY(emergency_grace_shift_event_offset_samples,
                         emergency_grace_shift_event_count);
  INUMA_COPY_TRACE_ARRAY(emergency_grace_shift_frame_timestamp_ns_samples,
                         emergency_grace_shift_event_count);
  INUMA_COPY_TRACE_ARRAY(emergency_grace_shift_frame_generation_samples,
                         emergency_grace_shift_event_count);
  INUMA_COPY_TRACE_ARRAY(emergency_grace_drain_event_offset_samples,
                         emergency_grace_drain_event_count);
  INUMA_COPY_TRACE_ARRAY(emergency_grace_drain_frame_timestamp_ns_samples,
                         emergency_grace_drain_event_count);
  INUMA_COPY_TRACE_ARRAY(emergency_grace_drain_frame_generation_samples,
                         emergency_grace_drain_event_count);
  INUMA_COPY_TRACE_ARRAY(emergency_grace_residence_samples,
                         emergency_grace_drain_event_count);
  INUMA_COPY_TRACE_ARRAY(emergency_grace_refuse_event_offset_samples,
                         emergency_grace_refuse_event_count);
  INUMA_COPY_TRACE_ARRAY(emergency_grace_refuse_frame_timestamp_ns_samples,
                         emergency_grace_refuse_event_count);
  INUMA_COPY_TRACE_ARRAY(emergency_grace_refuse_frame_generation_samples,
                         emergency_grace_refuse_event_count);
  INUMA_COPY_TRACE_ARRAY(emergency_grace_refuse_reason_samples,
                         emergency_grace_refuse_event_count);
  INUMA_COPY_TRACE_ARRAY(emergency_grace_refuse_current_age_samples,
                         emergency_grace_refuse_event_count);
  INUMA_COPY_TRACE_ARRAY(emergency_grace_refuse_primary_age_samples,
                         emergency_grace_refuse_event_count);
  INUMA_COPY_TRACE_ARRAY(
      emergency_grace_refuse_current_rescue_promoted_samples,
      emergency_grace_refuse_event_count);
  INUMA_COPY_TRACE_ARRAY(emergency_grace_refuse_current_awaits_copy_samples,
                         emergency_grace_refuse_event_count);

#undef INUMA_COPY_TRACE_ARRAY
}

static NSArray<NSNumber *> *InumaTraceSampleArray(const uint64_t *samples,
                                                  NSUInteger count) {
  NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithCapacity:count];
  for (NSUInteger index = 0; index < count; index++) {
    [values addObject:@(samples[index])];
  }
  return values;
}

static NSArray<NSNumber *> *InumaTraceByteSampleArray(const uint8_t *samples,
                                                      NSUInteger count) {
  NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithCapacity:count];
  for (NSUInteger index = 0; index < count; index++) {
    [values addObject:@(samples[index])];
  }
  return values;
}

static NSArray<NSNumber *> *InumaTraceSignedSampleArray(const int64_t *samples,
                                                       NSUInteger count) {
  NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithCapacity:count];
  for (NSUInteger index = 0; index < count; index++) {
    [values addObject:@(samples[index])];
  }
  return values;
}

static InumaMacOSPixelMode
InumaPixelModeFromEnvironment(NSDictionary<NSString *, NSString *> *env) {
  NSString *value = [env[@"INUMA_FLUTTER_WEBRTC_MACOS_PIXEL_MODE"]
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  if ([value isEqualToString:@"native_nv12"]) {
    return InumaMacOSPixelModeNativeNV12;
  }
  return InumaMacOSPixelModeStockBGRA;
}

static uint64_t InumaTextureMinimumHoldNanosecondsFromEnvironment(
    NSDictionary<NSString *, NSString *> *env) {
  NSString *value =
      [env[@"INUMA_FLUTTER_WEBRTC_MACOS_MIN_TEXTURE_HOLD_MS"]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  const double milliseconds = value.doubleValue;
  if (milliseconds <= 0.0 || milliseconds > 100.0) {
    return 0;
  }
  return (uint64_t)(milliseconds * (double)NSEC_PER_MSEC);
}

static NSUInteger InumaMaxQueuedTextureFramesFromEnvironment(
    NSDictionary<NSString *, NSString *> *env) {
  NSString *value =
      [env[@"INUMA_FLUTTER_WEBRTC_MACOS_MAX_QUEUED_TEXTURE_FRAMES"]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  const NSInteger frames = value.integerValue;
  if (frames <= 0 || frames > kInumaPendingTextureFrameCapacity) {
    return 0;
  }
  return (NSUInteger)frames;
}

static bool InumaRasterRepeatGuardEnabledFromEnvironment(
    NSDictionary<NSString *, NSString *> *env) {
  NSString *value =
      [env[@"INUMA_FLUTTER_WEBRTC_MACOS_RASTER_REPEAT_GUARD"]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return [value isEqualToString:@"enabled"];
}

static uint64_t InumaRasterRepeatBoundaryNanosecondsFromEnvironment(
    NSDictionary<NSString *, NSString *> *env) {
  NSString *value =
      [env[@"INUMA_FLUTTER_WEBRTC_MACOS_RASTER_REPEAT_BOUNDARY_MS"]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  const double milliseconds = value.doubleValue;
  if (milliseconds <= 0.0 || milliseconds > 100.0) {
    return 0;
  }
  return (uint64_t)(milliseconds * (double)NSEC_PER_MSEC);
}

static bool InumaEmergencyGraceEnabledFromEnvironment(
    NSDictionary<NSString *, NSString *> *env) {
  NSString *value =
      [env[@"INUMA_FLUTTER_WEBRTC_MACOS_EMERGENCY_GRACE_SLOT"]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return [value isEqualToString:@"enabled"];
}

static bool InumaDirectFrameDisplayRetryEnabledFromEnvironment(
    NSDictionary<NSString *, NSString *> *env) {
  NSString *value =
      [env[@"INUMA_FLUTTER_WEBRTC_MACOS_DIRECT_FRAME_DISPLAY_RETRY"]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return [value isEqualToString:@"enabled"];
}

static bool InumaMainRunLoopNotificationEnabledFromEnvironment(
    NSDictionary<NSString *, NSString *> *env) {
  NSString *value =
      [env[@"INUMA_FLUTTER_WEBRTC_MACOS_MAIN_RUN_LOOP_NOTIFICATION_SOURCE"]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return [value isEqualToString:@"enabled"];
}

static InumaRenderQoSPolicy InumaRenderQoSPolicyFromEnvironment(
    NSDictionary<NSString *, NSString *> *env) {
  NSString *value =
      [env[@"INUMA_FLUTTER_WEBRTC_MACOS_RENDER_QOS"]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([value isEqualToString:@"user_interactive"]) {
    return InumaRenderQoSPolicyUserInteractive;
  }
  return InumaRenderQoSPolicyInherit;
}

static NSString *InumaRenderQoSPolicyName(InumaRenderQoSPolicy policy) {
  return policy == InumaRenderQoSPolicyUserInteractive
             ? @"user_interactive"
             : @"inherit";
}

static InumaRescueNotificationPhase
InumaRescueNotificationPhaseFromEnvironment(
    NSDictionary<NSString *, NSString *> *env) {
  NSString *value =
      [env[@"INUMA_FLUTTER_WEBRTC_MACOS_RESCUE_NOTIFICATION_PHASE"]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([value isEqualToString:@"platform_turn"]) {
    return InumaRescueNotificationPhasePlatformTurn;
  }
  return InumaRescueNotificationPhaseDisplayLink;
}

static NSString *
InumaRescueNotificationPhaseName(InumaRescueNotificationPhase phase) {
  return phase == InumaRescueNotificationPhasePlatformTurn
             ? @"platform_turn"
             : @"display_link";
}

static InumaRenderQoSObservation
InumaObserveRenderQoS(InumaRenderQoSPolicy policy) {
  static _Thread_local bool initialized = false;
  static _Thread_local InumaRenderQoSPolicy initializedPolicy =
      InumaRenderQoSPolicyInherit;
  static _Thread_local InumaRenderQoSObservation observation;
  if (!initialized || initializedPolicy != policy) {
    const qos_class_t before = qos_class_self();
    bool attempted = false;
    bool succeeded = false;
    if (policy == InumaRenderQoSPolicyUserInteractive &&
        before != QOS_CLASS_USER_INTERACTIVE) {
      attempted = true;
      succeeded =
          pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) == 0;
    }
    observation = (InumaRenderQoSObservation){
        .before = before,
        .after = qos_class_self(),
        .apply_attempted = attempted,
        .apply_succeeded = succeeded,
    };
    initializedPolicy = policy;
    initialized = true;
    return observation;
  }
  return (InumaRenderQoSObservation){
      .before = observation.after,
      .after = observation.after,
      .apply_attempted = false,
      .apply_succeeded = false,
  };
}

static void InumaRecordRenderQoSObservationLocked(
    InumaTextureTrace *trace, InumaRenderQoSObservation observation) {
  trace->render_qos_observations += 1;
  switch (observation.before) {
  case QOS_CLASS_BACKGROUND:
    trace->render_qos_before_background += 1;
    break;
  case QOS_CLASS_UTILITY:
    trace->render_qos_before_utility += 1;
    break;
  case QOS_CLASS_DEFAULT:
    trace->render_qos_before_default += 1;
    break;
  case QOS_CLASS_USER_INITIATED:
    trace->render_qos_before_user_initiated += 1;
    break;
  case QOS_CLASS_USER_INTERACTIVE:
    trace->render_qos_before_user_interactive += 1;
    break;
  case QOS_CLASS_UNSPECIFIED:
  default:
    trace->render_qos_before_unspecified += 1;
    break;
  }
  if (observation.apply_attempted) {
    trace->render_qos_apply_attempts += 1;
    if (observation.apply_succeeded &&
        observation.after == QOS_CLASS_USER_INTERACTIVE) {
      trace->render_qos_apply_successes += 1;
    } else {
      trace->render_qos_apply_failures += 1;
    }
  }
  if (observation.after == QOS_CLASS_USER_INTERACTIVE) {
    trace->render_qos_after_user_interactive += 1;
  } else {
    trace->render_qos_after_not_user_interactive += 1;
  }
}

@interface FlutterRTCVideoRenderer ()
- (void)inumaRecordSourceBuffer:(id<RTCVideoFrameBuffer>)buffer;
- (CVPixelBufferRef)inumaCreatePixelBufferFromFrame:(RTCVideoFrame *)frame;
- (CVPixelBufferRef)inumaRetainNativeNV12BufferFromFrame:
    (RTCVideoFrame *)frame;
- (CVPixelBufferRef)inumaCreateFreshStockBGRABuffer;
- (void)inumaScheduleTextureNotificationForTextureId:(int64_t)textureId
                                    frameTimestampNs:(int64_t)frameTimestampNs
                                     frameGeneration:(uint64_t)frameGeneration
                             rendererStateGeneration:
                                 (uint64_t)rendererStateGeneration
                                   bypassMinimumHold:(bool)bypassMinimumHold
                                  recordRescueBypass:(bool)recordRescueBypass
                            recordRasterRepeatRetry:
                                (bool)recordRasterRepeatRetry;
- (void)inumaScheduleDisplayLinkedRescueForTextureId:(int64_t)textureId
                                    frameTimestampNs:
                                        (int64_t)frameTimestampNs
                                     frameGeneration:
                                         (uint64_t)frameGeneration
                             rendererStateGeneration:
                                 (uint64_t)rendererStateGeneration
                            predecessorCopyUptimeNs:
                                (uint64_t)predecessorCopyUptimeNs;
- (void)inumaRescueDisplayLinkDidFire:(CADisplayLink *)displayLink
    API_AVAILABLE(macos(14.0));
- (void)inumaScheduleDirectFrameDisplayRetryForTextureId:(int64_t)textureId
                                        frameTimestampNs:
                                            (int64_t)frameTimestampNs
                                         frameGeneration:
                                             (uint64_t)frameGeneration
                                 rendererStateGeneration:
                                     (uint64_t)rendererStateGeneration;
- (void)inumaDirectFrameDisplayRetryDidFire:(CADisplayLink *)displayLink
    API_AVAILABLE(macos(14.0));
- (void)inumaCreateMainRunLoopNotificationSource;
- (BOOL)inumaArmMainRunLoopNotificationForTextureId:(int64_t)textureId
                                    frameTimestampNs:
                                        (int64_t)frameTimestampNs
                                     frameGeneration:
                                         (uint64_t)frameGeneration
                             rendererStateGeneration:
                                 (uint64_t)rendererStateGeneration
                                      successorRearm:(bool)successorRearm;
- (void)inumaMainRunLoopNotificationSourceDidFire;
- (void)inumaCloseMainRunLoopNotificationTokenLockedForLifecycle;
- (CFRunLoopSourceRef)inumaDetachMainRunLoopNotificationSourceLocked;
- (void)inumaInvalidateMainRunLoopNotificationSource:
    (CFRunLoopSourceRef)source;
- (void)inumaCancelTextureHoldTimerLocked;
- (void)inumaCancelRescueDisplayLinkLocked;
- (void)inumaCancelDirectFrameDisplayRetryLocked;
- (void)inumaInvalidateDirectFrameDisplayRetryLinkLocked;
- (void)inumaRetainCopiedBufferHoldLocked:(CVPixelBufferRef)pixelBuffer
                                 copiedAt:(uint64_t)copiedAt;
- (void)inumaReleaseOldestCopiedBufferHoldLockedAt:(uint64_t)releasedAt
                                          lifecycle:(bool)lifecycle;
- (void)inumaReleaseAllCopiedBufferHoldsLockedAt:(uint64_t)releasedAt;
- (void)inumaClearPendingTextureFramesLocked;
- (void)inumaResetStockBGRAPixelBufferPoolForSize:(CGSize)size;
- (void)inumaWriteTextureTrace;
@end

static const void *kInumaRenderQoSQueueSpecificKey =
    &kInumaRenderQoSQueueSpecificKey;

static const void *InumaMainRunLoopNotificationRetainOwner(
    const void *info) {
  return (__bridge_retained const void *)((__bridge id)info);
}

static void InumaMainRunLoopNotificationReleaseOwner(const void *info) {
  __unused id owner = (__bridge_transfer id)info;
}

static void InumaMainRunLoopNotificationPerform(void *info) {
  @autoreleasepool {
    FlutterRTCVideoRenderer *renderer =
        (__bridge FlutterRTCVideoRenderer *)info;
    [renderer inumaMainRunLoopNotificationSourceDidFire];
  }
}
#endif

@implementation FlutterRTCVideoRenderer {
  CGSize _frameSize;
  CGSize _renderSize;
  CVPixelBufferRef _pixelBufferRef;
  RTCVideoRotation _rotation;
  FlutterEventChannel *_eventChannel;
  bool _isFirstFrameRendered;
  bool _frameAvailable;
  os_unfair_lock _lock;
#if TARGET_OS_OSX
  NSString *_inumaTracePath;
  InumaMacOSPixelMode _inumaPixelMode;
  InumaRenderQoSPolicy _inumaRenderQoSPolicy;
  InumaRescueNotificationPhase _inumaRescueNotificationPhase;
  InumaTextureTrace _inumaTrace;
  uint64_t _inumaTraceStartedMonotonicNs;
  uint64_t _inumaFrameReadyMonotonicNs;
  uint64_t _inumaLastCopyMonotonicNs;
  uint64_t _inumaRendererStateGeneration;
  uint64_t _inumaFrameGenerationCounter;
  uint64_t _inumaCurrentFrameGeneration;
  int64_t _inumaLastCopiedFrameTimestampNs;
  uint64_t _inumaLastCopiedFrameGeneration;
  uint64_t _inumaMinimumTextureHoldNs;
  bool _inumaRasterRepeatGuardEnabled;
  uint64_t _inumaRasterRepeatBoundaryNs;
  bool _inumaCurrentFrameWasRescuePromoted;
  bool _inumaEmergencyGraceEnabled;
  bool _inumaDirectFrameDisplayRetryEnabled;
  bool _inumaMainRunLoopNotificationEnabled;
  bool _inumaCurrentNormalNotificationRequired;
  bool _inumaEmergencyGraceBurstArmed;
  bool _inumaCurrentFrameRepeatDeferred;
  bool _inumaCurrentRepeatRetryFired;
  NSUInteger _inumaMaxQueuedTextureFrames;
  NSUInteger _inumaPendingTextureFrameHead;
  NSUInteger _inumaPendingTextureFrameCount;
  InumaPendingTextureFrame
      _inumaPendingTextureFrames[kInumaPendingTextureFrameCapacity];
  InumaPendingTextureFrame _inumaEmergencyGraceTextureFrame;
  int64_t _inumaFrameTimestampNs;
  CVPixelBufferRef
      _inumaCopiedBufferHoldRefs[kInumaCopiedBufferHoldCapacity];
  uint64_t
      _inumaCopiedBufferHoldStartedMonotonicNs
          [kInumaCopiedBufferHoldCapacity];
  NSUInteger _inumaCopiedBufferHoldHead;
  NSUInteger _inumaCopiedBufferHoldCount;
  CVPixelBufferPoolRef _inumaStockBGRAPixelBufferPool;
  dispatch_queue_t _inumaRenderQoSQueue;
  dispatch_queue_t _inumaTraceQueue;
  dispatch_source_t _inumaTraceTimer;
  dispatch_source_t _inumaTextureHoldTimer;
  CADisplayLink *_inumaRescueDisplayLink;
  CADisplayLink *_inumaDirectFrameDisplayRetryLink;
  CFRunLoopSourceRef _inumaMainRunLoopNotificationSource;
  bool _inumaMainRunLoopNotificationTokenOccupied;
  int64_t _inumaMainRunLoopNotificationTextureId;
  int64_t _inumaMainRunLoopNotificationFrameTimestampNs;
  uint64_t _inumaMainRunLoopNotificationFrameGeneration;
  uint64_t _inumaMainRunLoopNotificationRendererStateGeneration;
  uint64_t _inumaMainRunLoopNotificationArmedMonotonicNs;
  NSUInteger _inumaMainRunLoopNotificationEventIndex;
  bool _inumaDirectFrameDisplayRetryActive;
  uint64_t _inumaTraceSnapshotCount;
  uint64_t _inumaTraceSnapshotLockHoldMaxNs;
  int64_t _inumaRescueDisplayLinkFrameTimestampNs;
  uint64_t _inumaRescueDisplayLinkFrameGeneration;
  uint64_t _inumaRescueDisplayLinkRendererStateGeneration;
  uint64_t _inumaRescuePredecessorCopyUptimeNs;
  NSUInteger _inumaRescueDisplayLinkEventIndex;
  int64_t _inumaDirectFrameDisplayRetryFrameTimestampNs;
  uint64_t _inumaDirectFrameDisplayRetryFrameGeneration;
  uint64_t _inumaDirectFrameDisplayRetryRendererStateGeneration;
  uint64_t _inumaDirectFrameDisplayRetryFrameReadyMonotonicNs;
  uint64_t _inumaDirectFrameDisplayRetryScheduledMonotonicNs;
  NSUInteger _inumaDirectFrameDisplayRetryEventIndex;
#endif
}

@synthesize textureId = _textureId;
@synthesize registry = _registry;
@synthesize eventSink = _eventSink;
@synthesize videoTrack = _videoTrack;

- (instancetype)initWithTextureRegistry:(id<FlutterTextureRegistry>)registry
                              messenger:(NSObject<FlutterBinaryMessenger> *)
                                            messenger {
  self = [super init];
  if (self) {
    _lock = OS_UNFAIR_LOCK_INIT;
    _isFirstFrameRendered = false;
    _frameAvailable = false;
    _frameSize = CGSizeZero;
    _renderSize = CGSizeZero;
    _rotation = -1;
    _registry = registry;
    _pixelBufferRef = nil;
    _eventSink = nil;
    _rotation = -1;
    _textureId = [registry registerTexture:self];
#if TARGET_OS_OSX
    NSDictionary<NSString *, NSString *> *environment =
        NSProcessInfo.processInfo.environment;
    _inumaTracePath =
        [environment[@"INUMA_FLUTTER_WEBRTC_TEXTURE_TRACE_PATH"] copy];
    _inumaTrace.enabled = _inumaTracePath.length > 0;
    _inumaPixelMode = InumaPixelModeFromEnvironment(environment);
    _inumaRenderQoSPolicy =
        InumaRenderQoSPolicyFromEnvironment(environment);
    if (_inumaRenderQoSPolicy == InumaRenderQoSPolicyUserInteractive) {
      dispatch_queue_attr_t renderQoSQueueAttributes =
          dispatch_queue_attr_make_with_qos_class(
              DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
      _inumaRenderQoSQueue = dispatch_queue_create(
          "dev.inuma.flutter-webrtc.render-user-interactive",
          renderQoSQueueAttributes);
      dispatch_queue_set_specific(
          _inumaRenderQoSQueue, kInumaRenderQoSQueueSpecificKey,
          (__bridge void *)self, NULL);
    }
    _inumaRescueNotificationPhase =
        InumaRescueNotificationPhaseFromEnvironment(environment);
    _inumaMinimumTextureHoldNs =
        InumaTextureMinimumHoldNanosecondsFromEnvironment(environment);
    _inumaRasterRepeatGuardEnabled =
        InumaRasterRepeatGuardEnabledFromEnvironment(environment);
    _inumaRasterRepeatBoundaryNs =
        InumaRasterRepeatBoundaryNanosecondsFromEnvironment(environment);
    _inumaEmergencyGraceEnabled =
        InumaEmergencyGraceEnabledFromEnvironment(environment);
    _inumaDirectFrameDisplayRetryEnabled =
        InumaDirectFrameDisplayRetryEnabledFromEnvironment(environment);
    _inumaMainRunLoopNotificationEnabled =
        InumaMainRunLoopNotificationEnabledFromEnvironment(environment);
    _inumaMaxQueuedTextureFrames =
        InumaMaxQueuedTextureFramesFromEnvironment(environment);
    _inumaPendingTextureFrameHead = 0;
    _inumaPendingTextureFrameCount = 0;
    _inumaTraceStartedMonotonicNs =
        _inumaTrace.enabled ? InumaMonotonicNanoseconds() : 0;
    _inumaFrameReadyMonotonicNs = 0;
    _inumaLastCopyMonotonicNs = 0;
    _inumaRendererStateGeneration = 1;
    _inumaFrameGenerationCounter = 0;
    _inumaCurrentFrameGeneration = 0;
    _inumaLastCopiedFrameTimestampNs = 0;
    _inumaLastCopiedFrameGeneration = 0;
    _inumaCurrentFrameWasRescuePromoted = false;
    _inumaCurrentFrameRepeatDeferred = false;
    _inumaCurrentRepeatRetryFired = false;
    _inumaCurrentNormalNotificationRequired = false;
    _inumaEmergencyGraceTextureFrame = (InumaPendingTextureFrame){0};
    _inumaEmergencyGraceBurstArmed = true;
    _inumaFrameTimestampNs = 0;
    _inumaCopiedBufferHoldHead = 0;
    _inumaCopiedBufferHoldCount = 0;
    _inumaTextureHoldTimer = nil;
    _inumaRescueDisplayLink = nil;
    _inumaDirectFrameDisplayRetryLink = nil;
    _inumaMainRunLoopNotificationSource = NULL;
    _inumaMainRunLoopNotificationTokenOccupied = false;
    _inumaMainRunLoopNotificationTextureId = -1;
    _inumaMainRunLoopNotificationFrameTimestampNs = 0;
    _inumaMainRunLoopNotificationFrameGeneration = 0;
    _inumaMainRunLoopNotificationRendererStateGeneration = 0;
    _inumaMainRunLoopNotificationArmedMonotonicNs = 0;
    _inumaMainRunLoopNotificationEventIndex = NSNotFound;
    _inumaDirectFrameDisplayRetryActive = false;
    _inumaTraceSnapshotCount = 0;
    _inumaTraceSnapshotLockHoldMaxNs = 0;
    _inumaRescueDisplayLinkFrameTimestampNs = 0;
    _inumaRescueDisplayLinkFrameGeneration = 0;
    _inumaRescueDisplayLinkRendererStateGeneration = 0;
    _inumaRescuePredecessorCopyUptimeNs = 0;
    _inumaRescueDisplayLinkEventIndex = NSNotFound;
    _inumaDirectFrameDisplayRetryFrameTimestampNs = 0;
    _inumaDirectFrameDisplayRetryFrameGeneration = 0;
    _inumaDirectFrameDisplayRetryRendererStateGeneration = 0;
    _inumaDirectFrameDisplayRetryFrameReadyMonotonicNs = 0;
    _inumaDirectFrameDisplayRetryScheduledMonotonicNs = 0;
    _inumaDirectFrameDisplayRetryEventIndex = NSNotFound;
    _inumaStockBGRAPixelBufferPool = nil;
    if (_inumaTrace.enabled) {
      _inumaTraceQueue = dispatch_queue_create(
          "dev.inuma.flutter-webrtc.texture-trace", DISPATCH_QUEUE_SERIAL);
      _inumaTraceTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0,
                                                0, _inumaTraceQueue);
      dispatch_source_set_timer(
          _inumaTraceTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
          5 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
      __weak FlutterRTCVideoRenderer *weakSelf = self;
      dispatch_source_set_event_handler(_inumaTraceTimer, ^{
        [weakSelf inumaWriteTextureTrace];
      });
      dispatch_resume(_inumaTraceTimer);
    }
    if (_inumaMainRunLoopNotificationEnabled) {
      if (NSThread.isMainThread) {
        [self inumaCreateMainRunLoopNotificationSource];
      } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
          [self inumaCreateMainRunLoopNotificationSource];
        });
      }
    }
#endif
    /*Create Event Channel.*/
    _eventChannel = [FlutterEventChannel
        eventChannelWithName:[NSString
                                 stringWithFormat:@"FlutterWebRTC/Texture%lld",
                                                  _textureId]
             binaryMessenger:messenger];
    [_eventChannel setStreamHandler:self];
  }
  return self;
}

- (CVPixelBufferRef)copyPixelBuffer {
  CVPixelBufferRef buffer = nil;
#if TARGET_OS_OSX
  const uint64_t started =
      _inumaTrace.enabled ? InumaMonotonicNanoseconds() : 0;
  bool notifyPromotedFrame = false;
  int64_t promotedTextureId = -1;
  int64_t promotedFrameTimestampNs = 0;
  uint64_t promotedFrameGeneration = 0;
  uint64_t promotedRendererStateGeneration = 0;
  uint64_t promotedPredecessorCopyUptimeNs = 0;
  bool retryRasterRepeatedFrame = false;
  int64_t repeatedFrameTextureId = -1;
  int64_t repeatedDeferredFrameTimestampNs = 0;
  uint64_t repeatedFrameGeneration = 0;
  uint64_t repeatedRendererStateGeneration = 0;
#endif
  os_unfair_lock_lock(&_lock);
#if TARGET_OS_OSX
  const uint64_t locked = _inumaTrace.enabled ? InumaMonotonicNanoseconds() : 0;
  if (_inumaTrace.enabled) {
    _inumaTrace.copy_calls += 1;
    InumaAppendTraceSample(
        _inumaTrace.copy_lock_wait_samples,
        &_inumaTrace.copy_lock_wait_count, locked - started,
        &_inumaTrace.sample_capacity_exhaustions);
  }
  const uint64_t repeatCheckedAt = InumaMonotonicNanoseconds();
  // A rescue notification can reach Flutter's raster thread before Core
  // Animation has had one full minimum-tenure opportunity for the predecessor.
  // Return the retained predecessor once and leave the promoted frame pending;
  // the serialized platform-turn owner schedules its one permitted retry.
  const bool baseRepeatCandidate =
      _inumaRasterRepeatGuardEnabled && _frameAvailable &&
      _inumaCurrentFrameWasRescuePromoted &&
      _inumaMinimumTextureHoldNs > 0 && _inumaLastCopyMonotonicNs > 0 &&
      repeatCheckedAt >= _inumaLastCopyMonotonicNs;
  const uint64_t predecessorTenureNs =
      baseRepeatCandidate ? repeatCheckedAt - _inumaLastCopyMonotonicNs : 0;
  const InumaRepeatBoundaryPolicyDecision repeatBoundaryDecision =
      InumaRepeatBoundaryEvaluate((InumaRepeatBoundaryPolicyInput){
          .enabled = _inumaRasterRepeatBoundaryNs > 0,
          .base_repeat_candidate = baseRepeatCandidate,
          .predecessor_tenure_ns = predecessorTenureNs,
          .normal_minimum_hold_ns = _inumaMinimumTextureHoldNs,
          .repeat_boundary_ns = _inumaRasterRepeatBoundaryNs,
      });
  const bool repeatGuardEligible =
      repeatBoundaryDecision.evaluated
          ? repeatBoundaryDecision.repeat
          : baseRepeatCandidate &&
                predecessorTenureNs < _inumaMinimumTextureHoldNs;
  if (_inumaTrace.enabled && repeatBoundaryDecision.evaluated) {
    _inumaTrace.raster_repeat_boundary_evaluations += 1;
    if (repeatBoundaryDecision.repeat) {
      _inumaTrace.raster_repeat_boundary_applies += 1;
      if (repeatBoundaryDecision.extends_normal_hold) {
        _inumaTrace.raster_repeat_boundary_extended_applies += 1;
      }
    } else {
      _inumaTrace.raster_repeat_boundary_bypasses += 1;
    }
    const NSUInteger boundaryIndex = InumaReserveTraceSample(
        &_inumaTrace.raster_repeat_boundary_event_count,
        &_inumaTrace.sample_capacity_exhaustions);
    if (boundaryIndex != NSNotFound) {
      _inumaTrace.raster_repeat_boundary_event_offset_samples[boundaryIndex] =
          repeatCheckedAt - _inumaTraceStartedMonotonicNs;
      _inumaTrace
          .raster_repeat_boundary_predecessor_frame_timestamp_ns_samples
              [boundaryIndex] = _inumaLastCopiedFrameTimestampNs;
      _inumaTrace
          .raster_repeat_boundary_predecessor_frame_generation_samples
              [boundaryIndex] = _inumaLastCopiedFrameGeneration;
      _inumaTrace
          .raster_repeat_boundary_successor_frame_timestamp_ns_samples
              [boundaryIndex] = _inumaFrameTimestampNs;
      _inumaTrace
          .raster_repeat_boundary_successor_frame_generation_samples
              [boundaryIndex] = _inumaCurrentFrameGeneration;
      _inumaTrace
          .raster_repeat_boundary_predecessor_tenure_samples[boundaryIndex] =
          predecessorTenureNs;
      _inumaTrace.raster_repeat_boundary_outcome_samples[boundaryIndex] =
          repeatBoundaryDecision.extends_normal_hold
              ? 2
              : (repeatBoundaryDecision.repeat ? 1 : 0);
    }
  }
  if (repeatGuardEligible) {
    if (_inumaTrace.enabled) {
      _inumaTrace.raster_repeat_guard_eligible_copy_calls += 1;
    }
    if (_inumaCopiedBufferHoldCount > 0) {
      const NSUInteger newestHoldIndex =
          (_inumaCopiedBufferHoldHead + _inumaCopiedBufferHoldCount - 1) %
          kInumaCopiedBufferHoldCapacity;
      CVPixelBufferRef predecessor =
          _inumaCopiedBufferHoldRefs[newestHoldIndex];
      if (predecessor != nil) {
        buffer = CVBufferRetain(predecessor);
        _inumaCurrentFrameWasRescuePromoted = false;
        _inumaCurrentFrameRepeatDeferred = true;
        _inumaCurrentRepeatRetryFired = false;
        retryRasterRepeatedFrame = _textureId != -1;
        repeatedFrameTextureId = _textureId;
        repeatedDeferredFrameTimestampNs = _inumaFrameTimestampNs;
        repeatedFrameGeneration = _inumaCurrentFrameGeneration;
        repeatedRendererStateGeneration = _inumaRendererStateGeneration;
        if (_inumaTrace.enabled) {
          _inumaTrace.copy_hits += 1;
          _inumaTrace.raster_repeat_guard_repeats += 1;
          if (!retryRasterRepeatedFrame) {
            _inumaTrace.raster_repeat_guard_retry_unavailable += 1;
          }
          const NSUInteger repeatIndex = InumaReserveTraceSample(
              &_inumaTrace.raster_repeat_event_count,
              &_inumaTrace.sample_capacity_exhaustions);
          if (repeatIndex != NSNotFound) {
            _inumaTrace.raster_repeat_event_offset_samples[repeatIndex] =
                repeatCheckedAt - _inumaTraceStartedMonotonicNs;
            _inumaTrace
                .raster_repeat_predecessor_frame_timestamp_ns_samples
                    [repeatIndex] = _inumaLastCopiedFrameTimestampNs;
            _inumaTrace
                .raster_repeat_predecessor_frame_generation_samples
                    [repeatIndex] = _inumaLastCopiedFrameGeneration;
            _inumaTrace.raster_repeat_deferred_frame_timestamp_ns_samples
                [repeatIndex] = _inumaFrameTimestampNs;
            _inumaTrace.raster_repeat_deferred_frame_generation_samples
                [repeatIndex] = _inumaCurrentFrameGeneration;
            _inumaTrace.raster_repeat_predecessor_tenure_samples[repeatIndex] =
                repeatCheckedAt - _inumaLastCopyMonotonicNs;
          }
        }
      }
    }
    if (buffer == nil && _inumaTrace.enabled) {
      _inumaTrace.raster_repeat_guard_missing_predecessor += 1;
    }
  }
#endif
  if (buffer == nil && _pixelBufferRef != nil && _frameAvailable) {
    buffer = CVBufferRetain(_pixelBufferRef);
#if TARGET_OS_OSX
    [self inumaCancelDirectFrameDisplayRetryLocked];
#endif
    _frameAvailable = false;
#if TARGET_OS_OSX
    _inumaCurrentNormalNotificationRequired = false;
    const uint64_t copiedAt = InumaMonotonicNanoseconds();
    const uint64_t copiedAtUptimeNs = InumaUptimeNanoseconds();
    // A display-acknowledged rescue may request the next raster copy after
    // only one refresh. Flutter can release that CVPixelBuffer before Core
    // Animation is finished with its IOSurface, so retain two copy
    // generations. This preserves the accepted v18 low-backlog scheduler
    // without allowing the recyclable pool to overwrite either predecessor.
    [self inumaRetainCopiedBufferHoldLocked:_pixelBufferRef
                                  copiedAt:copiedAt];
    _inumaLastCopyMonotonicNs = copiedAt;
    _inumaLastCopiedFrameTimestampNs = _inumaFrameTimestampNs;
    _inumaLastCopiedFrameGeneration = _inumaCurrentFrameGeneration;
    _inumaCurrentFrameWasRescuePromoted = false;
    _inumaCurrentFrameRepeatDeferred = false;
    _inumaCurrentRepeatRetryFired = false;
    if (_inumaTrace.enabled) {
      _inumaTrace.copy_hits += 1;
      if (_inumaFrameReadyMonotonicNs > 0 &&
          locked >= _inumaFrameReadyMonotonicNs) {
        InumaAppendTraceSample(
            _inumaTrace.copy_ready_age_samples,
            &_inumaTrace.copy_ready_age_count,
            locked - _inumaFrameReadyMonotonicNs,
            &_inumaTrace.sample_capacity_exhaustions);
      }
      if (_inumaTraceStartedMonotonicNs > 0 &&
          locked >= _inumaTraceStartedMonotonicNs) {
        const NSUInteger copyEventIndex = InumaReserveTraceSample(
            &_inumaTrace.copy_event_count,
            &_inumaTrace.sample_capacity_exhaustions);
        if (copyEventIndex != NSNotFound) {
          _inumaTrace.copy_event_offset_samples[copyEventIndex] =
              locked - _inumaTraceStartedMonotonicNs;
          _inumaTrace.copy_frame_timestamp_ns_samples[copyEventIndex] =
              _inumaFrameTimestampNs;
          _inumaTrace.copy_frame_generation_samples[copyEventIndex] =
              _inumaCurrentFrameGeneration;
        }
      }
    }
    if (_inumaPendingTextureFrameCount > 0) {
      InumaPendingTextureFrame promoted =
          _inumaPendingTextureFrames[_inumaPendingTextureFrameHead];
      _inumaPendingTextureFrames[_inumaPendingTextureFrameHead] =
          (InumaPendingTextureFrame){0};
      _inumaPendingTextureFrameHead =
          (_inumaPendingTextureFrameHead + 1) %
          kInumaPendingTextureFrameCapacity;
      _inumaPendingTextureFrameCount -= 1;

      if (InumaEmergencyGraceShouldShift(
              _inumaEmergencyGraceTextureFrame.pixel_buffer != nil,
              _inumaPendingTextureFrameCount)) {
        const InumaPendingTextureFrame shifted =
            _inumaEmergencyGraceTextureFrame;
        _inumaEmergencyGraceTextureFrame = (InumaPendingTextureFrame){0};
        const NSUInteger queueIndex =
            (_inumaPendingTextureFrameHead +
             _inumaPendingTextureFrameCount) %
            kInumaPendingTextureFrameCapacity;
        _inumaPendingTextureFrames[queueIndex] = shifted;
        _inumaPendingTextureFrameCount += 1;
        if (_inumaTrace.enabled) {
          _inumaTrace.emergency_grace_shifts += 1;
          const NSUInteger shiftIndex = InumaReserveTraceSample(
              &_inumaTrace.emergency_grace_shift_event_count,
              &_inumaTrace.sample_capacity_exhaustions);
          if (shiftIndex != NSNotFound) {
            _inumaTrace
                .emergency_grace_shift_event_offset_samples[shiftIndex] =
                copiedAt - _inumaTraceStartedMonotonicNs;
            _inumaTrace
                .emergency_grace_shift_frame_timestamp_ns_samples
                    [shiftIndex] = shifted.frame_timestamp_ns;
            _inumaTrace.emergency_grace_shift_frame_generation_samples
                [shiftIndex] = shifted.frame_generation;
          }
        }
      }

      CVPixelBufferRef previousBuffer = _pixelBufferRef;
      _pixelBufferRef = promoted.pixel_buffer;
      _frameAvailable = true;
      _inumaFrameReadyMonotonicNs = promoted.ready_monotonic_ns;
      _inumaFrameTimestampNs = promoted.frame_timestamp_ns;
      _inumaCurrentFrameGeneration = promoted.frame_generation;
      _inumaCurrentFrameWasRescuePromoted = true;
      _inumaCurrentNormalNotificationRequired = false;
      if (previousBuffer != nil) {
        CVBufferRelease(previousBuffer);
      }
      notifyPromotedFrame = _textureId != -1;
      promotedTextureId = _textureId;
      promotedFrameTimestampNs = promoted.frame_timestamp_ns;
      promotedFrameGeneration = _inumaCurrentFrameGeneration;
      promotedRendererStateGeneration = _inumaRendererStateGeneration;
      promotedPredecessorCopyUptimeNs = copiedAtUptimeNs;
      if (_inumaTrace.enabled) {
        _inumaTrace.queue_promotions += 1;
        if (InumaEmergencyGracePromotedFrameDrains(
                promoted.from_emergency_grace)) {
          _inumaTrace.emergency_grace_drains += 1;
          const NSUInteger drainIndex = InumaReserveTraceSample(
              &_inumaTrace.emergency_grace_drain_event_count,
              &_inumaTrace.sample_capacity_exhaustions);
          if (drainIndex != NSNotFound) {
            _inumaTrace
                .emergency_grace_drain_event_offset_samples[drainIndex] =
                copiedAt - _inumaTraceStartedMonotonicNs;
            _inumaTrace
                .emergency_grace_drain_frame_timestamp_ns_samples
                    [drainIndex] = promoted.frame_timestamp_ns;
            _inumaTrace.emergency_grace_drain_frame_generation_samples
                [drainIndex] = promoted.frame_generation;
            _inumaTrace.emergency_grace_residence_samples[drainIndex] =
                promoted.emergency_grace_admitted_monotonic_ns > 0 &&
                        copiedAt >=
                            promoted.emergency_grace_admitted_monotonic_ns
                    ? copiedAt -
                          promoted.emergency_grace_admitted_monotonic_ns
                    : 0;
          }
        }
        if (_inumaRescueNotificationPhase ==
            InumaRescueNotificationPhaseDisplayLink) {
          _inumaTrace.rescue_hold_preservations += 1;
          const NSUInteger preservationIndex = InumaReserveTraceSample(
              &_inumaTrace.rescue_hold_preservation_count,
              &_inumaTrace.sample_capacity_exhaustions);
          if (preservationIndex != NSNotFound) {
            _inumaTrace
                .rescue_hold_preservation_frame_timestamp_ns_samples
                    [preservationIndex] = promoted.frame_timestamp_ns;
            _inumaTrace
                .rescue_hold_preservation_frame_generation_samples
                    [preservationIndex] = promoted.frame_generation;
          }
        }
        if (copiedAt >= promoted.ready_monotonic_ns) {
          InumaAppendTraceSample(
              _inumaTrace.queue_wait_samples,
              &_inumaTrace.queue_wait_count,
              copiedAt - promoted.ready_monotonic_ns,
              &_inumaTrace.sample_capacity_exhaustions);
        }
        if (_inumaTraceStartedMonotonicNs > 0 &&
            copiedAt >= _inumaTraceStartedMonotonicNs) {
          const NSUInteger promoteIndex = InumaReserveTraceSample(
              &_inumaTrace.queue_promote_event_count,
              &_inumaTrace.sample_capacity_exhaustions);
          if (promoteIndex != NSNotFound) {
            _inumaTrace.queue_promote_event_offset_samples[promoteIndex] =
                copiedAt - _inumaTraceStartedMonotonicNs;
            _inumaTrace.queue_promote_frame_timestamp_ns_samples
                [promoteIndex] = promoted.frame_timestamp_ns;
            _inumaTrace.queue_promote_frame_generation_samples[promoteIndex] =
                promoted.frame_generation;
          }
        }
      }
    }
#endif
#if TARGET_OS_OSX
  } else if (buffer == nil && _inumaTrace.enabled) {
    _inumaTrace.copy_misses += 1;
#endif
  }
  os_unfair_lock_unlock(&_lock);
#if TARGET_OS_OSX
  if (retryRasterRepeatedFrame) {
    // copyPixelBuffer is already the raster boundary. Queue one platform turn
    // after returning the predecessor so Flutter can schedule the deferred
    // current frame for the next raster cycle without paying another
    // display-link phase and occupying the one-slot queue for two refreshes.
    [self inumaScheduleTextureNotificationForTextureId:
              repeatedFrameTextureId
                                          frameTimestampNs:
                                              repeatedDeferredFrameTimestampNs
                                           frameGeneration:
                                               repeatedFrameGeneration
                                   rendererStateGeneration:
                                       repeatedRendererStateGeneration
                                         bypassMinimumHold:true
                                        recordRescueBypass:false
                                  recordRasterRepeatRetry:true];
  }
  if (notifyPromotedFrame) {
    if (_inumaRescueNotificationPhase ==
        InumaRescueNotificationPhasePlatformTurn) {
      // copyPixelBuffer has already committed the predecessor and promoted the
      // queued frame under the renderer lock. Notify that still-current frame
      // on one serialized platform turn instead of waiting for a display-link
      // timestamp that describes the previous display refresh. The existing
      // repeat guard remains the only early-copy protection.
      [self inumaScheduleTextureNotificationForTextureId:promotedTextureId
                                        frameTimestampNs:
                                            promotedFrameTimestampNs
                                         frameGeneration:
                                             promotedFrameGeneration
                                 rendererStateGeneration:
                                     promotedRendererStateGeneration
                                       bypassMinimumHold:true
                                      recordRescueBypass:true
                                recordRasterRepeatRetry:false];
    } else {
      [self inumaScheduleDisplayLinkedRescueForTextureId:promotedTextureId
                                        frameTimestampNs:
                                            promotedFrameTimestampNs
                                         frameGeneration:
                                             promotedFrameGeneration
                                 rendererStateGeneration:
                                     promotedRendererStateGeneration
                                predecessorCopyUptimeNs:
                                    promotedPredecessorCopyUptimeNs];
    }
  }
#endif
  return buffer;
}

- (void)dispose {
#if TARGET_OS_OSX
  CFRunLoopSourceRef mainRunLoopNotificationSource = NULL;
  if (_inumaTraceTimer != nil) {
    dispatch_source_cancel(_inumaTraceTimer);
    _inumaTraceTimer = nil;
  }
#endif
  os_unfair_lock_lock(&_lock);
#if TARGET_OS_OSX
  _inumaRendererStateGeneration += 1;
  [self inumaCancelTextureHoldTimerLocked];
  [self inumaCancelRescueDisplayLinkLocked];
  [self inumaCancelDirectFrameDisplayRetryLocked];
  [self inumaInvalidateDirectFrameDisplayRetryLinkLocked];
  mainRunLoopNotificationSource =
      [self inumaDetachMainRunLoopNotificationSourceLocked];
#endif
  [_registry unregisterTexture:_textureId];
  _textureId = -1;
  if (_pixelBufferRef) {
    CVBufferRelease(_pixelBufferRef);
    _pixelBufferRef = nil;
  }
#if TARGET_OS_OSX
  [self inumaClearPendingTextureFramesLocked];
  [self inumaReleaseAllCopiedBufferHoldsLockedAt:
            InumaMonotonicNanoseconds()];
  _inumaFrameReadyMonotonicNs = 0;
  _inumaLastCopyMonotonicNs = 0;
  _inumaLastCopiedFrameTimestampNs = 0;
  _inumaLastCopiedFrameGeneration = 0;
  _inumaFrameTimestampNs = 0;
  _inumaCurrentFrameGeneration = 0;
  _inumaCurrentFrameWasRescuePromoted = false;
  _inumaCurrentFrameRepeatDeferred = false;
  _inumaCurrentRepeatRetryFired = false;
  _inumaCurrentNormalNotificationRequired = false;
  if (_inumaStockBGRAPixelBufferPool) {
    CVPixelBufferPoolRelease(_inumaStockBGRAPixelBufferPool);
    _inumaStockBGRAPixelBufferPool = nil;
  }
#endif
  _frameAvailable = false;
  os_unfair_lock_unlock(&_lock);
#if TARGET_OS_OSX
  [self inumaInvalidateMainRunLoopNotificationSource:
            mainRunLoopNotificationSource];
  [self inumaWriteTextureTrace];
#endif
}

- (void)setVideoTrack:(RTCVideoTrack *)videoTrack {
  RTCVideoTrack *oldValue = self.videoTrack;
  if (oldValue != videoTrack) {
    os_unfair_lock_lock(&_lock);
    _videoTrack = videoTrack;
#if TARGET_OS_OSX
    _inumaRendererStateGeneration += 1;
    [self inumaCloseMainRunLoopNotificationTokenLockedForLifecycle];
    [self inumaCancelTextureHoldTimerLocked];
    [self inumaCancelRescueDisplayLinkLocked];
    [self inumaCancelDirectFrameDisplayRetryLocked];
    [self inumaClearPendingTextureFramesLocked];
    [self inumaReleaseAllCopiedBufferHoldsLockedAt:
              InumaMonotonicNanoseconds()];
    _inumaFrameReadyMonotonicNs = 0;
    _inumaLastCopyMonotonicNs = 0;
    _inumaLastCopiedFrameTimestampNs = 0;
    _inumaLastCopiedFrameGeneration = 0;
    _inumaFrameTimestampNs = 0;
    _inumaCurrentFrameGeneration = 0;
    _inumaCurrentFrameWasRescuePromoted = false;
    _inumaCurrentFrameRepeatDeferred = false;
    _inumaCurrentRepeatRetryFired = false;
    _inumaCurrentNormalNotificationRequired = false;
#endif
    _frameAvailable = false;
    os_unfair_lock_unlock(&_lock);
    _isFirstFrameRendered = false;
    if (oldValue) {
      [oldValue removeRenderer:self];
    }
    _frameSize = CGSizeZero;
    _renderSize = CGSizeZero;
    _rotation = -1;
    if (videoTrack) {
      [videoTrack addRenderer:self];
    }
  }
}

- (void)inumaScheduleDirectFrameDisplayRetryForTextureId:(int64_t)textureId
                                        frameTimestampNs:
                                            (int64_t)frameTimestampNs
                                         frameGeneration:
                                             (uint64_t)frameGeneration
                                 rendererStateGeneration:
                                     (uint64_t)rendererStateGeneration {
  const uint64_t scheduledAt = InumaMonotonicNanoseconds();
  __weak FlutterRTCVideoRenderer *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    FlutterRTCVideoRenderer *strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    if (@available(macOS 14.0, *)) {
      CADisplayLink *displayLink = nil;
      bool createdDisplayLink = false;
      os_unfair_lock_lock(&strongSelf->_lock);
      const bool retryMayStillBeCurrent =
          strongSelf->_inumaDirectFrameDisplayRetryEnabled &&
          strongSelf->_inumaRendererStateGeneration ==
              rendererStateGeneration &&
          strongSelf->_textureId == textureId &&
          strongSelf->_frameAvailable &&
          !strongSelf->_inumaCurrentFrameWasRescuePromoted &&
          InumaFrameOwnershipValuesMatch(
              strongSelf->_inumaCurrentFrameGeneration, frameGeneration,
              strongSelf->_inumaFrameTimestampNs, frameTimestampNs) &&
          strongSelf->_inumaFrameReadyMonotonicNs > 0 &&
          !strongSelf->_inumaDirectFrameDisplayRetryActive;
      if (retryMayStillBeCurrent) {
        displayLink = strongSelf->_inumaDirectFrameDisplayRetryLink;
      }
      os_unfair_lock_unlock(&strongSelf->_lock);
      if (!retryMayStillBeCurrent) {
        return;
      }

      if (displayLink == nil) {
        NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
        displayLink =
            [screen displayLinkWithTarget:strongSelf
                                selector:@selector(
                                             inumaDirectFrameDisplayRetryDidFire:)];
        if (displayLink != nil) {
          // A renderer owns one run-loop object for its lifetime. Pausing is
          // thread-safe and suppresses callbacks, so ordinary frame copies do
          // not create/invalidate one CADisplayLink per decoded frame.
          displayLink.paused = YES;
          [displayLink addToRunLoop:NSRunLoop.mainRunLoop
                           forMode:NSRunLoopCommonModes];
          createdDisplayLink = true;
        }
      }
      os_unfair_lock_lock(&strongSelf->_lock);
      const bool retryIsCurrent =
          strongSelf->_inumaDirectFrameDisplayRetryEnabled &&
          displayLink != nil &&
          strongSelf->_inumaRendererStateGeneration ==
              rendererStateGeneration &&
          strongSelf->_textureId == textureId &&
          strongSelf->_frameAvailable &&
          !strongSelf->_inumaCurrentFrameWasRescuePromoted &&
          InumaFrameOwnershipValuesMatch(
              strongSelf->_inumaCurrentFrameGeneration, frameGeneration,
              strongSelf->_inumaFrameTimestampNs, frameTimestampNs) &&
          strongSelf->_inumaFrameReadyMonotonicNs > 0 &&
          !strongSelf->_inumaDirectFrameDisplayRetryActive &&
          (strongSelf->_inumaDirectFrameDisplayRetryLink == nil ||
           strongSelf->_inumaDirectFrameDisplayRetryLink == displayLink);
      if (retryIsCurrent) {
        if (strongSelf->_inumaDirectFrameDisplayRetryLink == nil) {
          strongSelf->_inumaDirectFrameDisplayRetryLink = displayLink;
          if (strongSelf->_inumaTrace.enabled) {
            strongSelf->_inumaTrace
                .direct_frame_display_retry_link_creations += 1;
          }
        } else if (strongSelf->_inumaTrace.enabled) {
          strongSelf->_inumaTrace.direct_frame_display_retry_link_reuses += 1;
        }
        strongSelf->_inumaDirectFrameDisplayRetryActive = true;
        strongSelf->_inumaDirectFrameDisplayRetryFrameTimestampNs =
            frameTimestampNs;
        strongSelf->_inumaDirectFrameDisplayRetryFrameGeneration =
            frameGeneration;
        strongSelf->_inumaDirectFrameDisplayRetryRendererStateGeneration =
            rendererStateGeneration;
        strongSelf->_inumaDirectFrameDisplayRetryFrameReadyMonotonicNs =
            strongSelf->_inumaFrameReadyMonotonicNs;
        strongSelf->_inumaDirectFrameDisplayRetryScheduledMonotonicNs =
            scheduledAt;
        strongSelf->_inumaDirectFrameDisplayRetryEventIndex = NSNotFound;
        if (strongSelf->_inumaTrace.enabled) {
          strongSelf->_inumaTrace.direct_frame_display_retry_schedules += 1;
          strongSelf->_inumaTrace.direct_frame_display_retry_link_arms += 1;
          if (strongSelf->_inumaTraceStartedMonotonicNs > 0 &&
              scheduledAt >= strongSelf->_inumaTraceStartedMonotonicNs) {
            const NSUInteger eventIndex = InumaReserveTraceSample(
                &strongSelf->_inumaTrace
                     .direct_frame_display_retry_event_count,
                &strongSelf->_inumaTrace.sample_capacity_exhaustions);
            if (eventIndex != NSNotFound) {
              strongSelf->_inumaTrace
                  .direct_frame_display_retry_schedule_offset_samples
                      [eventIndex] =
                  scheduledAt - strongSelf->_inumaTraceStartedMonotonicNs;
              strongSelf->_inumaTrace
                  .direct_frame_display_retry_frame_timestamp_ns_samples
                      [eventIndex] = frameTimestampNs;
              strongSelf->_inumaTrace
                  .direct_frame_display_retry_frame_generation_samples
                      [eventIndex] = frameGeneration;
              strongSelf->_inumaTrace
                  .direct_frame_display_retry_outcome_samples[eventIndex] =
                  InumaDirectFrameDisplayRetryOutcomePending;
              strongSelf->_inumaDirectFrameDisplayRetryEventIndex =
                  eventIndex;
            }
          }
        }
        // isPaused is thread-safe. Set it while ownership is locked so a
        // concurrent raster copy cannot pause the link and then be undone by
        // a late unpause from this arm operation.
        displayLink.paused = NO;
      } else if (displayLink == nil &&
                 strongSelf->_inumaDirectFrameDisplayRetryEnabled &&
                 strongSelf->_inumaRendererStateGeneration ==
                     rendererStateGeneration &&
                 strongSelf->_textureId == textureId &&
                 strongSelf->_frameAvailable &&
                 InumaFrameOwnershipValuesMatch(
                     strongSelf->_inumaCurrentFrameGeneration,
                     frameGeneration, strongSelf->_inumaFrameTimestampNs,
                     frameTimestampNs) &&
                 strongSelf->_inumaTrace.enabled) {
        strongSelf->_inumaTrace.direct_frame_display_retry_create_failures +=
            1;
      }
      if (!retryIsCurrent && createdDisplayLink &&
          strongSelf->_inumaTrace.enabled) {
        strongSelf->_inumaTrace
            .direct_frame_display_retry_link_abandoned_creations += 1;
      }
      os_unfair_lock_unlock(&strongSelf->_lock);
      if (!retryIsCurrent && createdDisplayLink) {
        [displayLink invalidate];
      }
      return;
    }

    os_unfair_lock_lock(&strongSelf->_lock);
    const bool creationWasRequired =
        strongSelf->_inumaDirectFrameDisplayRetryEnabled &&
        strongSelf->_inumaRendererStateGeneration ==
            rendererStateGeneration &&
        strongSelf->_textureId == textureId && strongSelf->_frameAvailable &&
        InumaFrameOwnershipValuesMatch(
            strongSelf->_inumaCurrentFrameGeneration, frameGeneration,
            strongSelf->_inumaFrameTimestampNs, frameTimestampNs);
    if (creationWasRequired && strongSelf->_inumaTrace.enabled) {
      strongSelf->_inumaTrace.direct_frame_display_retry_create_failures += 1;
    }
    os_unfair_lock_unlock(&strongSelf->_lock);
  });
}

- (void)inumaDirectFrameDisplayRetryDidFire:(CADisplayLink *)displayLink
    API_AVAILABLE(macos(14.0)) {
  const uint64_t checkedAt = InumaMonotonicNanoseconds();
  int64_t textureId = -1;
  int64_t frameTimestampNs = 0;
  uint64_t frameGeneration = 0;
  id<FlutterTextureRegistry> registry = nil;
  bool shouldDefer = false;
  bool shouldFire = false;
  bool ownsDisplayLink = false;
  uint64_t scheduledAt = 0;
  NSUInteger eventIndex = NSNotFound;
  os_unfair_lock_lock(&_lock);
  ownsDisplayLink = _inumaDirectFrameDisplayRetryLink == displayLink &&
                    _inumaDirectFrameDisplayRetryActive;
  if (ownsDisplayLink) {
    textureId = _textureId;
    frameTimestampNs = _inumaDirectFrameDisplayRetryFrameTimestampNs;
    frameGeneration = _inumaDirectFrameDisplayRetryFrameGeneration;
    registry = _registry;
    scheduledAt = _inumaDirectFrameDisplayRetryScheduledMonotonicNs;
    eventIndex = _inumaDirectFrameDisplayRetryEventIndex;
    const bool predecessorHoldSatisfied =
        _inumaLastCopyMonotonicNs == 0 ||
        (checkedAt >= _inumaLastCopyMonotonicNs &&
         checkedAt - _inumaLastCopyMonotonicNs >=
             _inumaMinimumTextureHoldNs);
    const InumaDirectFrameDisplayRetryPolicyDecision decision =
        InumaDirectFrameDisplayRetryEvaluate(
            (InumaDirectFrameDisplayRetryPolicyInput){
                .enabled = _inumaDirectFrameDisplayRetryEnabled,
                .owns_display_link = ownsDisplayLink,
                .renderer_state_matches =
                    _inumaRendererStateGeneration ==
                    _inumaDirectFrameDisplayRetryRendererStateGeneration,
                .texture_matches = textureId != -1 && registry != nil,
                .frame_available = _frameAvailable,
                .frame_timestamp_matches =
                    InumaFrameOwnershipValuesMatch(
                        _inumaCurrentFrameGeneration, frameGeneration,
                        _inumaFrameTimestampNs, frameTimestampNs),
                .predecessor_hold_satisfied = predecessorHoldSatisfied,
                .frame_ready_monotonic_ns =
                    _inumaDirectFrameDisplayRetryFrameReadyMonotonicNs,
                .checked_monotonic_ns = checkedAt,
                .minimum_retry_age_ns =
                    kInumaDirectFrameDisplayRetryMinimumAgeNs,
            });
    shouldDefer = decision.defer;
    shouldFire = decision.fire;
    if (_inumaTrace.enabled) {
      _inumaTrace.direct_frame_display_retry_callbacks += 1;
      if (eventIndex != NSNotFound &&
          eventIndex < _inumaTrace.direct_frame_display_retry_event_count) {
        _inumaTrace
            .direct_frame_display_retry_callback_count_samples[eventIndex] +=
            1;
      }
      if (shouldDefer) {
        _inumaTrace.direct_frame_display_retry_deferrals += 1;
      } else {
        if (eventIndex != NSNotFound &&
            eventIndex < _inumaTrace.direct_frame_display_retry_event_count &&
            _inumaTraceStartedMonotonicNs > 0 &&
            checkedAt >= _inumaTraceStartedMonotonicNs) {
          _inumaTrace.direct_frame_display_retry_callback_offset_samples
              [eventIndex] = checkedAt - _inumaTraceStartedMonotonicNs;
          _inumaTrace.direct_frame_display_retry_outcome_samples[eventIndex] =
              shouldFire ? InumaDirectFrameDisplayRetryOutcomeFired
                         : InumaDirectFrameDisplayRetryOutcomeStale;
        }
        if (shouldFire) {
          _inumaTrace.direct_frame_display_retry_fires += 1;
          _inumaTrace.direct_frame_display_retry_notifications += 1;
          if (eventIndex != NSNotFound &&
              eventIndex < _inumaTrace.direct_frame_display_retry_event_count &&
              _inumaTraceStartedMonotonicNs > 0 &&
              checkedAt >= _inumaTraceStartedMonotonicNs) {
            _inumaTrace
                .direct_frame_display_retry_notification_offset_samples
                    [eventIndex] =
                checkedAt - _inumaTraceStartedMonotonicNs;
          }
          const NSUInteger notifyEventIndex = InumaReserveTraceSample(
              &_inumaTrace.texture_notify_event_count,
              &_inumaTrace.sample_capacity_exhaustions);
          if (notifyEventIndex != NSNotFound &&
              _inumaTraceStartedMonotonicNs > 0 &&
              checkedAt >= _inumaTraceStartedMonotonicNs) {
            _inumaTrace.texture_notify_event_offset_samples[notifyEventIndex] =
                checkedAt - _inumaTraceStartedMonotonicNs;
            _inumaTrace
                .texture_notify_frame_timestamp_ns_samples[notifyEventIndex] =
                frameTimestampNs;
            _inumaTrace
                .texture_notify_frame_generation_samples[notifyEventIndex] =
                frameGeneration;
            _inumaTrace
                .texture_notify_scheduled_delay_samples[notifyEventIndex] = 0;
            const uint64_t plannedDeadline =
                _inumaDirectFrameDisplayRetryFrameReadyMonotonicNs +
                kInumaDirectFrameDisplayRetryMinimumAgeNs;
            _inumaTrace
                .texture_notify_deadline_lateness_samples[notifyEventIndex] =
                checkedAt >= plannedDeadline ? checkedAt - plannedDeadline : 0;
          }
        } else {
          _inumaTrace.direct_frame_display_retry_stale_fires += 1;
        }
      }
    }
    if (!shouldDefer) {
      _inumaDirectFrameDisplayRetryActive = false;
      _inumaDirectFrameDisplayRetryFrameTimestampNs = 0;
      _inumaDirectFrameDisplayRetryFrameGeneration = 0;
      _inumaDirectFrameDisplayRetryRendererStateGeneration = 0;
      _inumaDirectFrameDisplayRetryFrameReadyMonotonicNs = 0;
      _inumaDirectFrameDisplayRetryScheduledMonotonicNs = 0;
      _inumaDirectFrameDisplayRetryEventIndex = NSNotFound;
      displayLink.paused = YES;
      if (_inumaTrace.enabled) {
        _inumaTrace.direct_frame_display_retry_link_pauses += 1;
      }
    }
  }
  os_unfair_lock_unlock(&_lock);
  if (!ownsDisplayLink || shouldDefer) {
    return;
  }
  if (shouldFire && registry != nil) {
    // This is the only retry call. Its exact notification event was committed
    // under the same ownership lock before the registry call, so the retained
    // trace can join retry fire -> platform notification -> raster copy.
    [registry textureFrameAvailable:textureId];
    if (_inumaTrace.enabled) {
      const uint64_t notifyEnded = InumaMonotonicNanoseconds();
      os_unfair_lock_lock(&_lock);
      if (scheduledAt > 0 && checkedAt >= scheduledAt) {
        InumaAppendTraceSample(
            _inumaTrace.texture_notify_dispatch_samples,
            &_inumaTrace.texture_notify_dispatch_count,
            checkedAt - scheduledAt,
            &_inumaTrace.sample_capacity_exhaustions);
      }
      InumaAppendTraceSample(
          _inumaTrace.texture_notify_samples,
          &_inumaTrace.texture_notify_count, notifyEnded - checkedAt,
          &_inumaTrace.sample_capacity_exhaustions);
      os_unfair_lock_unlock(&_lock);
    }
  }
}

- (id<RTCI420Buffer>)correctRotation:(const id<RTCI420Buffer>)src
                        withRotation:(RTCVideoRotation)rotation {
  int rotated_width = src.width;
  int rotated_height = src.height;

  if (rotation == RTCVideoRotation_90 || rotation == RTCVideoRotation_270) {
    int temp = rotated_width;
    rotated_width = rotated_height;
    rotated_height = temp;
  }

  id<RTCI420Buffer> buffer =
      [[RTCI420Buffer alloc] initWithWidth:rotated_width height:rotated_height];

  [RTCYUVHelper I420Rotate:src.dataY
                srcStrideY:src.strideY
                      srcU:src.dataU
                srcStrideU:src.strideU
                      srcV:src.dataV
                srcStrideV:src.strideV
                      dstY:(uint8_t *)buffer.dataY
                dstStrideY:buffer.strideY
                      dstU:(uint8_t *)buffer.dataU
                dstStrideU:buffer.strideU
                      dstV:(uint8_t *)buffer.dataV
                dstStrideV:buffer.strideV
                     width:src.width
                    height:src.height
                      mode:rotation];

  return buffer;
}

- (void)copyI420ToCVPixelBuffer:(CVPixelBufferRef)outputPixelBuffer
                      withFrame:(RTCVideoFrame *)frame {
  id<RTCI420Buffer> i420Buffer = [self correctRotation:[frame.buffer toI420]
                                          withRotation:frame.rotation];
  CVPixelBufferLockBaseAddress(outputPixelBuffer, 0);

  const OSType pixelFormat = CVPixelBufferGetPixelFormatType(outputPixelBuffer);
  if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
      pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
    // NV12
    uint8_t *dstY = CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 0);
    const size_t dstYStride =
        CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 0);
    uint8_t *dstUV = CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 1);
    const size_t dstUVStride =
        CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 1);

    [RTCYUVHelper I420ToNV12:i420Buffer.dataY
                  srcStrideY:i420Buffer.strideY
                        srcU:i420Buffer.dataU
                  srcStrideU:i420Buffer.strideU
                        srcV:i420Buffer.dataV
                  srcStrideV:i420Buffer.strideV
                        dstY:dstY
                  dstStrideY:(int)dstYStride
                       dstUV:dstUV
                 dstStrideUV:(int)dstUVStride
                       width:i420Buffer.width
                      height:i420Buffer.height];

  } else {
    uint8_t *dst = CVPixelBufferGetBaseAddress(outputPixelBuffer);
    const size_t bytesPerRow = CVPixelBufferGetBytesPerRow(outputPixelBuffer);

    if (pixelFormat == kCVPixelFormatType_32BGRA) {
      // Corresponds to libyuv::FOURCC_ARGB

      [RTCYUVHelper I420ToARGB:i420Buffer.dataY
                    srcStrideY:i420Buffer.strideY
                          srcU:i420Buffer.dataU
                    srcStrideU:i420Buffer.strideU
                          srcV:i420Buffer.dataV
                    srcStrideV:i420Buffer.strideV
                       dstARGB:dst
                 dstStrideARGB:(int)bytesPerRow
                         width:i420Buffer.width
                        height:i420Buffer.height];

    } else if (pixelFormat == kCVPixelFormatType_32ARGB) {
      // Corresponds to libyuv::FOURCC_BGRA
      [RTCYUVHelper I420ToBGRA:i420Buffer.dataY
                    srcStrideY:i420Buffer.strideY
                          srcU:i420Buffer.dataU
                    srcStrideU:i420Buffer.strideU
                          srcV:i420Buffer.dataV
                    srcStrideV:i420Buffer.strideV
                       dstBGRA:dst
                 dstStrideBGRA:(int)bytesPerRow
                         width:i420Buffer.width
                        height:i420Buffer.height];
    }
  }

  CVPixelBufferUnlockBaseAddress(outputPixelBuffer, 0);
}

#pragma mark - RTCVideoRenderer methods
- (void)renderFrame:(RTCVideoFrame *)frame {

#if TARGET_OS_OSX
  const bool inumaExecutingOnOwnedRenderQoSQueue =
      _inumaRenderQoSQueue != nil &&
      dispatch_get_specific(kInumaRenderQoSQueueSpecificKey) ==
          (__bridge void *)self;
  if (_inumaRenderQoSPolicy == InumaRenderQoSPolicyUserInteractive &&
      _inumaRenderQoSQueue != nil &&
      !inumaExecutingOnOwnedRenderQoSQueue) {
    if (_inumaTrace.enabled) {
      os_unfair_lock_lock(&_lock);
      _inumaTrace.render_qos_sync_handoffs += 1;
      os_unfair_lock_unlock(&_lock);
    }
    // VideoToolbox owns its asynchronous decompression callback thread. Keep
    // that system callback unmodified and synchronously hand the frame to one
    // app-owned serial queue. The explicit work-item class is enforced even
    // when dispatch_sync borrows the caller thread. A synchronous handoff
    // admits exactly one frame and cannot accumulate a catch-up queue.
    dispatch_block_t renderWork = dispatch_block_create_with_qos_class(
        DISPATCH_BLOCK_ENFORCE_QOS_CLASS, QOS_CLASS_USER_INTERACTIVE, 0, ^{
      [self renderFrame:frame];
    });
    if (renderWork != nil) {
      dispatch_sync(_inumaRenderQoSQueue, renderWork);
      return;
    }
    if (_inumaTrace.enabled) {
      os_unfair_lock_lock(&_lock);
      _inumaTrace.render_qos_work_item_creation_failures += 1;
      os_unfair_lock_unlock(&_lock);
    }
  }
  const InumaRenderQoSObservation inumaRenderQoS =
      InumaObserveRenderQoS(_inumaRenderQoSPolicy);
  const uint64_t started =
      _inumaTrace.enabled ? InumaMonotonicNanoseconds() : 0;
  NSUInteger inumaRenderEventIndex = NSNotFound;
  bool inumaShouldNotifyTexture = false;
  int64_t inumaTextureIdToNotify = -1;
  int64_t inumaFrameTimestampToNotify = 0;
  uint64_t inumaFrameGeneration = 0;
  uint64_t inumaFrameGenerationToNotify = 0;
  uint64_t inumaRendererStateGenerationToNotify = 0;
#endif
  os_unfair_lock_lock(&_lock);
#if TARGET_OS_OSX
  const uint64_t locked = _inumaTrace.enabled ? InumaMonotonicNanoseconds() : 0;
  _inumaFrameGenerationCounter =
      InumaNextFrameGeneration(_inumaFrameGenerationCounter);
  inumaFrameGeneration = _inumaFrameGenerationCounter;
  if (_inumaTrace.enabled) {
    InumaRecordRenderQoSObservationLocked(&_inumaTrace, inumaRenderQoS);
    if (inumaExecutingOnOwnedRenderQoSQueue) {
      _inumaTrace.render_qos_owned_queue_entries += 1;
    } else {
      _inumaTrace.render_qos_calling_thread_entries += 1;
    }
    _inumaTrace.render_frames += 1;
    _inumaTrace.frame_generation_assignments += 1;
    if (frame.timeStampNs == 0) {
      _inumaTrace.zero_timestamp_render_frames += 1;
    }
    if (_inumaTraceStartedMonotonicNs > 0 &&
        locked >= _inumaTraceStartedMonotonicNs) {
      inumaRenderEventIndex = InumaReserveTraceSample(
          &_inumaTrace.render_event_count,
          &_inumaTrace.sample_capacity_exhaustions);
      if (inumaRenderEventIndex != NSNotFound) {
        _inumaTrace.render_event_offset_samples[inumaRenderEventIndex] =
            locked - _inumaTraceStartedMonotonicNs;
        _inumaTrace.render_frame_timestamp_ns_samples[inumaRenderEventIndex] =
            frame.timeStampNs;
        _inumaTrace.render_frame_generation_samples[inumaRenderEventIndex] =
            inumaFrameGeneration;
        _inumaTrace.render_outcome_samples[inumaRenderEventIndex] = 0;
      }
    }
    InumaAppendTraceSample(
        _inumaTrace.render_lock_wait_samples,
        &_inumaTrace.render_lock_wait_count, locked - started,
        &_inumaTrace.sample_capacity_exhaustions);
    [self inumaRecordSourceBuffer:frame.buffer];
  }
#endif
  if (_videoTrack == nil) {
    os_unfair_lock_unlock(&_lock);
    return;
  }
#if TARGET_OS_OSX
  const bool canPrepareFrame =
      _inumaPixelMode == InumaMacOSPixelModeNativeNV12 ||
      _inumaStockBGRAPixelBufferPool != nil;
  const bool queueHasCapacity =
      _inumaMaxQueuedTextureFrames > 0 &&
      _inumaLastCopyMonotonicNs > 0 &&
      _inumaPendingTextureFrameCount < _inumaMaxQueuedTextureFrames;
  const bool primaryQueueFull =
      _frameAvailable && _inumaMaxQueuedTextureFrames > 0 &&
      _inumaPendingTextureFrameCount >= _inumaMaxQueuedTextureFrames;
  const bool emergencyGraceOccupied =
      _inumaEmergencyGraceTextureFrame.pixel_buffer != nil;
  if (!_inumaEmergencyGraceBurstArmed &&
      InumaEmergencyGraceShouldRearm(
          emergencyGraceOccupied, primaryQueueFull,
          _inumaPendingTextureFrameCount)) {
    _inumaEmergencyGraceBurstArmed = true;
    if (_inumaTrace.enabled) {
      _inumaTrace.emergency_grace_burst_rearms += 1;
    }
  }
  const uint64_t emergencyGraceCheckedAt =
      _inumaEmergencyGraceEnabled ? InumaMonotonicNanoseconds() : 0;
  const bool emergencyGraceQueueShape =
      primaryQueueFull && _inumaMaxQueuedTextureFrames == 1 &&
      _inumaPendingTextureFrameCount == 1;
  const InumaPendingTextureFrame emergencyGracePrimary =
      emergencyGraceQueueShape
          ? _inumaPendingTextureFrames[_inumaPendingTextureFrameHead]
          : (InumaPendingTextureFrame){0};
  const InumaEmergencyGracePolicyDecision emergencyGraceDecision =
      InumaEmergencyGraceEvaluate((InumaEmergencyGracePolicyInput){
          .enabled = _inumaEmergencyGraceEnabled,
          .primary_queue_full = primaryQueueFull,
          .maximum_queued_frames = _inumaMaxQueuedTextureFrames,
          .pending_frame_count = _inumaPendingTextureFrameCount,
          .current_frame_repeat_deferred = _inumaCurrentFrameRepeatDeferred,
          .current_frame_rescue_promoted =
              _inumaCurrentFrameWasRescuePromoted,
          .current_frame_awaits_copy = _frameAvailable,
          .current_ready_monotonic_ns = _inumaFrameReadyMonotonicNs,
          .primary_ready_monotonic_ns =
              emergencyGracePrimary.ready_monotonic_ns,
          .checked_monotonic_ns = emergencyGraceCheckedAt,
          .minimum_hold_ns = _inumaMinimumTextureHoldNs,
          .grace_occupied = emergencyGraceOccupied,
          .burst_armed = _inumaEmergencyGraceBurstArmed,
      });
  const bool emergencyGraceStateEligible = emergencyGraceDecision.eligible;
  const InumaEmergencyGraceRefuseReason emergencyGraceRefuseReason =
      emergencyGraceDecision.refuse_reason;
  const uint64_t emergencyGraceCurrentAge =
      _inumaFrameReadyMonotonicNs > 0 &&
              emergencyGraceCheckedAt >= _inumaFrameReadyMonotonicNs
          ? emergencyGraceCheckedAt - _inumaFrameReadyMonotonicNs
          : 0;
  const uint64_t emergencyGracePrimaryAge =
      emergencyGracePrimary.ready_monotonic_ns > 0 &&
              emergencyGraceCheckedAt >=
                  emergencyGracePrimary.ready_monotonic_ns
          ? emergencyGraceCheckedAt -
                emergencyGracePrimary.ready_monotonic_ns
          : 0;
  if (_inumaTrace.enabled && emergencyGraceStateEligible) {
    _inumaTrace.emergency_grace_eligible_frames += 1;
    _inumaTrace.emergency_grace_would_have_overflows += 1;
  }
  const bool canAcceptFrame =
      canPrepareFrame &&
      (!_frameAvailable || queueHasCapacity || emergencyGraceStateEligible);
#else
  const bool canAcceptFrame = !_frameAvailable && _pixelBufferRef != nil;
#endif
  if (canAcceptFrame) {
#if TARGET_OS_OSX
    CVPixelBufferRef preparedBuffer =
        [self inumaCreatePixelBufferFromFrame:frame];
    const bool framePrepared = preparedBuffer != nil;
    const uint64_t frameReadyNs =
        framePrepared ? InumaMonotonicNanoseconds() : 0;
    if (framePrepared && !_frameAvailable) {
      CVPixelBufferRef previousBuffer = _pixelBufferRef;
      _pixelBufferRef = preparedBuffer;
      _frameAvailable = true;
      _inumaFrameReadyMonotonicNs = frameReadyNs;
      _inumaFrameTimestampNs = frame.timeStampNs;
      _inumaCurrentFrameGeneration = inumaFrameGeneration;
      _inumaCurrentFrameWasRescuePromoted = false;
      _inumaCurrentFrameRepeatDeferred = false;
      _inumaCurrentRepeatRetryFired = false;
      _inumaCurrentNormalNotificationRequired = true;
      if (previousBuffer != nil) {
        CVBufferRelease(previousBuffer);
      }
      if (_textureId != -1) {
        inumaShouldNotifyTexture = true;
        inumaTextureIdToNotify = _textureId;
        inumaFrameTimestampToNotify = frame.timeStampNs;
        inumaFrameGenerationToNotify = _inumaCurrentFrameGeneration;
        inumaRendererStateGenerationToNotify =
            _inumaRendererStateGeneration;
      }
    } else if (framePrepared && queueHasCapacity) {
      const NSUInteger queueIndex =
          (_inumaPendingTextureFrameHead +
           _inumaPendingTextureFrameCount) %
          kInumaPendingTextureFrameCapacity;
      _inumaPendingTextureFrames[queueIndex] =
          (InumaPendingTextureFrame){
              .pixel_buffer = preparedBuffer,
              .frame_timestamp_ns = frame.timeStampNs,
              .frame_generation = inumaFrameGeneration,
              .ready_monotonic_ns = frameReadyNs,
              .emergency_grace_admitted_monotonic_ns = 0,
              .from_emergency_grace = false,
          };
      _inumaPendingTextureFrameCount += 1;
      if (_inumaTrace.enabled) {
        _inumaTrace.queued_frames += 1;
        _inumaTrace.queue_max_depth =
            MAX(_inumaTrace.queue_max_depth,
                (uint64_t)_inumaPendingTextureFrameCount);
        if (_inumaTraceStartedMonotonicNs > 0 &&
            frameReadyNs >= _inumaTraceStartedMonotonicNs) {
          const NSUInteger enqueueIndex = InumaReserveTraceSample(
              &_inumaTrace.queue_enqueue_event_count,
              &_inumaTrace.sample_capacity_exhaustions);
          if (enqueueIndex != NSNotFound) {
            _inumaTrace.queue_enqueue_event_offset_samples[enqueueIndex] =
                frameReadyNs - _inumaTraceStartedMonotonicNs;
            _inumaTrace.queue_enqueue_frame_timestamp_ns_samples[enqueueIndex] =
                frame.timeStampNs;
            _inumaTrace.queue_enqueue_frame_generation_samples[enqueueIndex] =
                inumaFrameGeneration;
          }
        }
      }
    } else if (framePrepared && emergencyGraceStateEligible) {
      _inumaEmergencyGraceBurstArmed = false;
      _inumaEmergencyGraceTextureFrame =
          (InumaPendingTextureFrame){
              .pixel_buffer = preparedBuffer,
              .frame_timestamp_ns = frame.timeStampNs,
              .frame_generation = inumaFrameGeneration,
              .ready_monotonic_ns = frameReadyNs,
              .emergency_grace_admitted_monotonic_ns = frameReadyNs,
              .from_emergency_grace = true,
          };
      if (_inumaTrace.enabled) {
        _inumaTrace.emergency_grace_admits += 1;
        if (emergencyGraceDecision.admitted_via_overdue_copy) {
          _inumaTrace.emergency_grace_admit_overdue_copy += 1;
        } else {
          _inumaTrace.emergency_grace_admit_repeat_deferred += 1;
        }
        _inumaTrace.emergency_grace_max_occupancy =
            MAX(_inumaTrace.emergency_grace_max_occupancy, 1);
        const NSUInteger admitIndex = InumaReserveTraceSample(
            &_inumaTrace.emergency_grace_admit_event_count,
            &_inumaTrace.sample_capacity_exhaustions);
        if (admitIndex != NSNotFound) {
          _inumaTrace
              .emergency_grace_admit_event_offset_samples[admitIndex] =
              frameReadyNs - _inumaTraceStartedMonotonicNs;
          _inumaTrace
              .emergency_grace_admit_frame_timestamp_ns_samples
                  [admitIndex] = frame.timeStampNs;
          _inumaTrace.emergency_grace_admit_frame_generation_samples
              [admitIndex] = inumaFrameGeneration;
          _inumaTrace
              .emergency_grace_admit_current_frame_timestamp_ns_samples
                  [admitIndex] = _inumaFrameTimestampNs;
          _inumaTrace.emergency_grace_admit_current_frame_generation_samples
              [admitIndex] = _inumaCurrentFrameGeneration;
          _inumaTrace
              .emergency_grace_admit_primary_frame_timestamp_ns_samples
                  [admitIndex] = emergencyGracePrimary.frame_timestamp_ns;
          _inumaTrace.emergency_grace_admit_primary_frame_generation_samples
              [admitIndex] = emergencyGracePrimary.frame_generation;
          _inumaTrace.emergency_grace_admit_primary_age_samples[admitIndex] =
              emergencyGraceCheckedAt -
              emergencyGracePrimary.ready_monotonic_ns;
          _inumaTrace
              .emergency_grace_admit_retry_fired_samples[admitIndex] =
              _inumaCurrentRepeatRetryFired ? 1 : 0;
          _inumaTrace
              .emergency_grace_admit_overdue_copy_samples[admitIndex] =
              emergencyGraceDecision.admitted_via_overdue_copy ? 1 : 0;
        }
      }
    }
    if (_inumaTrace.enabled && framePrepared) {
      _inumaTrace.accepted_frames += 1;
      if (frame.timeStampNs == 0) {
        _inumaTrace.zero_timestamp_accepted_frames += 1;
      }
      if (inumaRenderEventIndex != NSNotFound) {
        _inumaTrace.render_outcome_samples[inumaRenderEventIndex] =
            emergencyGraceStateEligible ? 3 : 1;
      }
    } else if (_inumaTrace.enabled && emergencyGraceStateEligible &&
               !framePrepared) {
      _inumaTrace.coalesced_frames += 1;
      _inumaTrace.queue_overflows += 1;
      InumaRecordEmergencyGraceRefusalLocked(
          &_inumaTrace, emergencyGraceCheckedAt,
          _inumaTraceStartedMonotonicNs, frame.timeStampNs,
          inumaFrameGeneration,
          InumaEmergencyGraceRefuseReasonConversionFailure,
          emergencyGraceCurrentAge, emergencyGracePrimaryAge,
          _inumaCurrentFrameWasRescuePromoted, _frameAvailable);
      if (inumaRenderEventIndex != NSNotFound) {
        _inumaTrace.render_outcome_samples[inumaRenderEventIndex] = 2;
      }
    }
#else
    [self copyI420ToCVPixelBuffer:_pixelBufferRef withFrame:frame];
    if (_textureId != -1) {
      [_registry textureFrameAvailable:_textureId];
    }
    _frameAvailable = true;
#endif
#if TARGET_OS_OSX
  } else if (_inumaTrace.enabled) {
    _inumaTrace.coalesced_frames += 1;
    if (_frameAvailable && _inumaMaxQueuedTextureFrames > 0 &&
        _inumaPendingTextureFrameCount >=
            _inumaMaxQueuedTextureFrames) {
      _inumaTrace.queue_overflows += 1;
      if (_inumaEmergencyGraceEnabled) {
        InumaRecordEmergencyGraceRefusalLocked(
            &_inumaTrace,
            emergencyGraceCheckedAt > 0 ? emergencyGraceCheckedAt : locked,
            _inumaTraceStartedMonotonicNs, frame.timeStampNs,
            inumaFrameGeneration,
            emergencyGraceRefuseReason ==
                    InumaEmergencyGraceRefuseReasonNone
                ? InumaEmergencyGraceRefuseReasonQueueShape
                : emergencyGraceRefuseReason,
            emergencyGraceCurrentAge, emergencyGracePrimaryAge,
            _inumaCurrentFrameWasRescuePromoted, _frameAvailable);
      }
    }
    if (inumaRenderEventIndex != NSNotFound) {
      _inumaTrace.render_outcome_samples[inumaRenderEventIndex] = 2;
    }
    if (_inumaFrameReadyMonotonicNs > 0 &&
        locked >= _inumaFrameReadyMonotonicNs) {
      InumaAppendTraceSample(
          _inumaTrace.coalesced_pending_age_samples,
          &_inumaTrace.coalesced_pending_age_count,
          locked - _inumaFrameReadyMonotonicNs,
          &_inumaTrace.sample_capacity_exhaustions);
    }
#endif
  }
  os_unfair_lock_unlock(&_lock);

  __weak FlutterRTCVideoRenderer *weakSelf = self;
#if TARGET_OS_OSX
  if (inumaShouldNotifyTexture) {
    [self inumaScheduleTextureNotificationForTextureId:
              inumaTextureIdToNotify
                                          frameTimestampNs:
                                              inumaFrameTimestampToNotify
                                           frameGeneration:
                                               inumaFrameGenerationToNotify
                                   rendererStateGeneration:
                                       inumaRendererStateGenerationToNotify
                                         bypassMinimumHold:false
                                        recordRescueBypass:false
                                  recordRasterRepeatRetry:false];
    if (_inumaDirectFrameDisplayRetryEnabled) {
      // The normal notification remains authoritative. Arm one independent
      // display-linked retry only while this direct frame is still awaiting
      // its first raster copy; copyPixelBuffer cancels it on the common path.
      [self inumaScheduleDirectFrameDisplayRetryForTextureId:
                inumaTextureIdToNotify
                                            frameTimestampNs:
                                                inumaFrameTimestampToNotify
                                             frameGeneration:
                                                 inumaFrameGenerationToNotify
                                     rendererStateGeneration:
                                         inumaRendererStateGenerationToNotify];
    }
  }
#endif
  if (_renderSize.width != frame.width || _renderSize.height != frame.height) {
    dispatch_async(dispatch_get_main_queue(), ^{
      FlutterRTCVideoRenderer *strongSelf = weakSelf;
      if (strongSelf.eventSink) {
        strongSelf.eventSink(@{
          @"event" : @"didTextureChangeVideoSize",
          @"id" : @(strongSelf.textureId),
          @"width" : @(frame.width),
          @"height" : @(frame.height),
        });
      }
    });
    _renderSize = CGSizeMake(frame.width, frame.height);
  }

  if (frame.rotation != _rotation) {
    dispatch_async(dispatch_get_main_queue(), ^{
      FlutterRTCVideoRenderer *strongSelf = weakSelf;
      if (strongSelf.eventSink) {
        strongSelf.eventSink(@{
          @"event" : @"didTextureChangeRotation",
          @"id" : @(strongSelf.textureId),
          @"rotation" : @(frame.rotation),
        });
      }
    });

    _rotation = frame.rotation;
  }

  // Notify the Flutter new pixelBufferRef to be ready.
  dispatch_async(dispatch_get_main_queue(), ^{
    FlutterRTCVideoRenderer *strongSelf = weakSelf;
    if (!strongSelf->_isFirstFrameRendered) {
      if (strongSelf.eventSink) {
        strongSelf.eventSink(@{@"event" : @"didFirstFrameRendered"});
        strongSelf->_isFirstFrameRendered = true;
      }
    }
  });
}

#if TARGET_OS_OSX
- (void)inumaRecordSourceBuffer:(id<RTCVideoFrameBuffer>)buffer {
  if ([buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
    _inumaTrace.source_cv_pixel_buffer_frames += 1;
    const OSType format = CVPixelBufferGetPixelFormatType(
        ((RTCCVPixelBuffer *)buffer).pixelBuffer);
    if (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
      _inumaTrace.source_nv12_frames += 1;
    } else if (format == kCVPixelFormatType_32BGRA) {
      _inumaTrace.source_bgra_frames += 1;
    } else {
      _inumaTrace.source_other_pixel_format_frames += 1;
    }
  } else {
    _inumaTrace.source_i420_frames += 1;
  }
}

- (CVPixelBufferRef)inumaCreatePixelBufferFromFrame:(RTCVideoFrame *)frame {
  CVPixelBufferRef preparedBuffer = nil;
  if (_inumaPixelMode == InumaMacOSPixelModeNativeNV12) {
    preparedBuffer = [self inumaRetainNativeNV12BufferFromFrame:frame];
    if (_inumaTrace.enabled && preparedBuffer == nil) {
      _inumaTrace.native_nv12_fallback_frames += 1;
    }
  }
  if (preparedBuffer == nil) {
    preparedBuffer = [self inumaCreateFreshStockBGRABuffer];
    if (preparedBuffer != nil) {
      const uint64_t conversionStarted =
          _inumaTrace.enabled ? InumaMonotonicNanoseconds() : 0;
      [self copyI420ToCVPixelBuffer:preparedBuffer withFrame:frame];
      if (_inumaTrace.enabled) {
        InumaAppendTraceSample(
            _inumaTrace.conversion_samples,
            &_inumaTrace.conversion_count,
            InumaMonotonicNanoseconds() - conversionStarted,
            &_inumaTrace.sample_capacity_exhaustions);
      }
    }
  }
  return preparedBuffer;
}

- (CVPixelBufferRef)inumaRetainNativeNV12BufferFromFrame:
    (RTCVideoFrame *)frame {
  if (frame.rotation != RTCVideoRotation_0 ||
      ![frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
    return nil;
  }
  RTCCVPixelBuffer *source = (RTCCVPixelBuffer *)frame.buffer;
  CVPixelBufferRef pixelBuffer = source.pixelBuffer;
  const OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
  if ((format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
       format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ||
      [source requiresCropping] ||
      [source requiresScalingToWidth:frame.width height:frame.height] ||
      CVPixelBufferGetIOSurface(pixelBuffer) == nil) {
    return nil;
  }
  CVBufferRetain(pixelBuffer);
  if (_inumaTrace.enabled) {
    _inumaTrace.native_nv12_frames += 1;
  }
  return pixelBuffer;
}

- (CVPixelBufferRef)inumaCreateFreshStockBGRABuffer {
  // Flutter retains the returned CVPixelBuffer while Metal presents it
  // asynchronously. Never overwrite that same backing for the next frame;
  // the pool recycles it only after downstream owners release it.
  _inumaTrace.stock_bgra_pool_buffer_requests += 1;
  CVPixelBufferRef freshBuffer = nil;
  CVReturn result = kCVReturnInvalidArgument;
  if (_inumaStockBGRAPixelBufferPool != nil) {
    result = CVPixelBufferPoolCreatePixelBuffer(
        kCFAllocatorDefault, _inumaStockBGRAPixelBufferPool, &freshBuffer);
  }
  if (result != kCVReturnSuccess || freshBuffer == nil) {
    _inumaTrace.stock_bgra_pool_buffer_failures += 1;
    return nil;
  }
  return freshBuffer;
}

- (void)inumaCreateMainRunLoopNotificationSource {
  os_unfair_lock_lock(&_lock);
  if (_inumaTrace.enabled) {
    _inumaTrace.main_run_loop_notification_source_create_attempts += 1;
  }
  os_unfair_lock_unlock(&_lock);
  if (!NSThread.isMainThread) {
    os_unfair_lock_lock(&_lock);
    if (_inumaTrace.enabled) {
      _inumaTrace.main_run_loop_notification_source_registration_failures +=
          1;
    }
    os_unfair_lock_unlock(&_lock);
    return;
  }

  CFRunLoopSourceContext context = {0};
  context.info = (__bridge void *)self;
  context.retain = InumaMainRunLoopNotificationRetainOwner;
  context.release = InumaMainRunLoopNotificationReleaseOwner;
  context.perform = InumaMainRunLoopNotificationPerform;
  CFRunLoopSourceRef source =
      CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context);
  if (source == NULL) {
    os_unfair_lock_lock(&_lock);
    if (_inumaTrace.enabled) {
      _inumaTrace.main_run_loop_notification_source_create_failures += 1;
    }
    os_unfair_lock_unlock(&_lock);
    return;
  }

  CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
  CFRunLoopAddSource(mainRunLoop, source, kCFRunLoopCommonModes);
  const bool registered =
      CFRunLoopContainsSource(mainRunLoop, source, kCFRunLoopCommonModes);
  bool accepted = false;
  os_unfair_lock_lock(&_lock);
  if (_inumaTrace.enabled) {
    _inumaTrace.main_run_loop_notification_source_creations += 1;
  }
  accepted = registered && _inumaMainRunLoopNotificationEnabled &&
             _inumaMainRunLoopNotificationSource == NULL;
  if (accepted) {
    _inumaMainRunLoopNotificationSource = source;
    if (_inumaTrace.enabled) {
      _inumaTrace.main_run_loop_notification_source_registrations += 1;
    }
  } else if (_inumaTrace.enabled) {
    _inumaTrace.main_run_loop_notification_source_registration_failures += 1;
  }
  os_unfair_lock_unlock(&_lock);
  if (accepted) {
    return;
  }
  if (registered) {
    CFRunLoopRemoveSource(mainRunLoop, source, kCFRunLoopCommonModes);
  }
  CFRunLoopSourceInvalidate(source);
  CFRelease(source);
}

- (BOOL)inumaArmMainRunLoopNotificationForTextureId:(int64_t)textureId
                                    frameTimestampNs:
                                        (int64_t)frameTimestampNs
                                     frameGeneration:
                                         (uint64_t)frameGeneration
                             rendererStateGeneration:
                                 (uint64_t)rendererStateGeneration
                                      successorRearm:(bool)successorRearm {
  const uint64_t armedAt = InumaMonotonicNanoseconds();
  CFRunLoopSourceRef source = NULL;
  InumaMainRunLoopNotificationArmDecision decision;
  os_unfair_lock_lock(&_lock);
  decision = InumaMainRunLoopNotificationEvaluateArm(
      (InumaMainRunLoopNotificationArmInput){
          .enabled = _inumaMainRunLoopNotificationEnabled,
          .ordinary_normal_path = true,
          .source_registered =
              _inumaMainRunLoopNotificationSource != NULL,
          .texture_registered = _textureId == textureId && textureId != -1 &&
                                _registry != nil,
          .frame_available = _frameAvailable,
          .frame_ownership_valid =
              InumaFrameOwnershipValuesMatch(
                  _inumaCurrentFrameGeneration, frameGeneration,
                  _inumaFrameTimestampNs, frameTimestampNs) &&
              _inumaRendererStateGeneration == rendererStateGeneration,
          .token_occupied =
              _inumaMainRunLoopNotificationTokenOccupied,
      });
  if (decision.arm) {
    _inumaMainRunLoopNotificationTokenOccupied = true;
    _inumaMainRunLoopNotificationTextureId = textureId;
    _inumaMainRunLoopNotificationFrameTimestampNs = frameTimestampNs;
    _inumaMainRunLoopNotificationFrameGeneration = frameGeneration;
    _inumaMainRunLoopNotificationRendererStateGeneration =
        rendererStateGeneration;
    _inumaMainRunLoopNotificationArmedMonotonicNs = armedAt;
    _inumaMainRunLoopNotificationEventIndex = NSNotFound;
    source = _inumaMainRunLoopNotificationSource;
    CFRetain(source);
    if (_inumaTrace.enabled) {
      _inumaTrace.main_run_loop_notification_source_signals += 1;
      _inumaTrace.main_run_loop_notification_run_loop_wakes += 1;
      if (successorRearm) {
        _inumaTrace.main_run_loop_notification_successor_rearms += 1;
      }
      const NSUInteger eventIndex = InumaReserveTraceSample(
          &_inumaTrace.main_run_loop_notification_event_count,
          &_inumaTrace.sample_capacity_exhaustions);
      if (eventIndex != NSNotFound) {
        _inumaTrace.main_run_loop_notification_arm_offset_samples[eventIndex] =
            armedAt - _inumaTraceStartedMonotonicNs;
        _inumaTrace
            .main_run_loop_notification_frame_timestamp_ns_samples
                [eventIndex] = frameTimestampNs;
        _inumaTrace
            .main_run_loop_notification_frame_generation_samples[eventIndex] =
            frameGeneration;
        _inumaTrace.main_run_loop_notification_outcome_samples[eventIndex] = 0;
        _inumaMainRunLoopNotificationEventIndex = eventIndex;
      }
    }
  } else if (_inumaTrace.enabled) {
    switch (decision.reason) {
    case InumaMainRunLoopNotificationArmReasonTokenOccupied:
      _inumaTrace.main_run_loop_notification_occupied_refusals += 1;
      break;
    case InumaMainRunLoopNotificationArmReasonSourceUnavailable:
      _inumaTrace.main_run_loop_notification_source_unavailable_fallbacks +=
          1;
      break;
    case InumaMainRunLoopNotificationArmReasonInvalidOwner:
      _inumaTrace.main_run_loop_notification_invalid_owner_refusals += 1;
      break;
    case InumaMainRunLoopNotificationArmReasonNone:
    case InumaMainRunLoopNotificationArmReasonAccepted:
    case InumaMainRunLoopNotificationArmReasonNonOrdinaryPath:
    default:
      break;
    }
  }
  os_unfair_lock_unlock(&_lock);

  if (source != NULL) {
    CFRunLoopSourceSignal(source);
    CFRunLoopWakeUp(CFRunLoopGetMain());
    CFRelease(source);
    return YES;
  }
  // An occupied or stale owner is deliberately not converted into a second
  // GCD notification. Only source unavailability falls back to V39.
  return decision.reason !=
         InumaMainRunLoopNotificationArmReasonSourceUnavailable;
}

- (void)inumaMainRunLoopNotificationSourceDidFire {
  const uint64_t callbackStarted = InumaMonotonicNanoseconds();
  id<FlutterTextureRegistry> registry = nil;
  int64_t textureId = -1;
  NSUInteger eventIndex = NSNotFound;
  bool shouldFire = false;
  bool shouldRearmSuccessor = false;
  int64_t successorTextureId = -1;
  int64_t successorFrameTimestampNs = 0;
  uint64_t successorFrameGeneration = 0;
  uint64_t successorRendererStateGeneration = 0;
  os_unfair_lock_lock(&_lock);
  if (_inumaTrace.enabled) {
    _inumaTrace.main_run_loop_notification_callbacks += 1;
    if (!NSThread.isMainThread) {
      _inumaTrace.main_run_loop_notification_off_main_callbacks += 1;
    }
  }
  const InumaMainRunLoopNotificationFireDecision decision =
      InumaMainRunLoopNotificationEvaluateFire(
          (InumaMainRunLoopNotificationFireInput){
              .enabled = _inumaMainRunLoopNotificationEnabled,
              .platform_thread = NSThread.isMainThread,
              .owns_source = _inumaMainRunLoopNotificationSource != NULL,
              .token_occupied =
                  _inumaMainRunLoopNotificationTokenOccupied,
              .renderer_state_matches =
                  _inumaRendererStateGeneration ==
                  _inumaMainRunLoopNotificationRendererStateGeneration,
              .texture_registered = _textureId != -1,
              .registry_available = _registry != nil,
              .texture_matches =
                  _textureId == _inumaMainRunLoopNotificationTextureId,
              .frame_available = _frameAvailable,
              .frame_ownership_matches =
                  InumaFrameOwnershipValuesMatch(
                      _inumaCurrentFrameGeneration,
                      _inumaMainRunLoopNotificationFrameGeneration,
                      _inumaFrameTimestampNs,
                      _inumaMainRunLoopNotificationFrameTimestampNs),
          });
  eventIndex = _inumaMainRunLoopNotificationEventIndex;
  if (decision.fire) {
    shouldFire = true;
    textureId = _inumaMainRunLoopNotificationTextureId;
    registry = _registry;
    _inumaCurrentNormalNotificationRequired = false;
    if (_inumaTrace.enabled) {
      _inumaTrace.main_run_loop_notification_current_fires += 1;
      if (eventIndex != NSNotFound &&
          eventIndex < _inumaTrace.main_run_loop_notification_event_count) {
        _inumaTrace.main_run_loop_notification_outcome_samples[eventIndex] = 1;
      }
    }
  } else if (decision.close_stale) {
    if (_inumaTrace.enabled) {
      _inumaTrace.main_run_loop_notification_stale_closes += 1;
      if (eventIndex != NSNotFound &&
          eventIndex < _inumaTrace.main_run_loop_notification_event_count) {
        _inumaTrace.main_run_loop_notification_outcome_samples[eventIndex] = 2;
      }
    }
  } else if (_inumaTrace.enabled) {
    _inumaTrace.main_run_loop_notification_empty_callbacks += 1;
  }
  if (eventIndex != NSNotFound &&
      eventIndex < _inumaTrace.main_run_loop_notification_event_count &&
      _inumaTraceStartedMonotonicNs > 0 &&
      callbackStarted >= _inumaTraceStartedMonotonicNs) {
    _inumaTrace.main_run_loop_notification_callback_offset_samples[eventIndex] =
        callbackStarted - _inumaTraceStartedMonotonicNs;
  }
  _inumaMainRunLoopNotificationTokenOccupied = false;
  _inumaMainRunLoopNotificationTextureId = -1;
  _inumaMainRunLoopNotificationFrameTimestampNs = 0;
  _inumaMainRunLoopNotificationFrameGeneration = 0;
  _inumaMainRunLoopNotificationRendererStateGeneration = 0;
  _inumaMainRunLoopNotificationArmedMonotonicNs = 0;
  _inumaMainRunLoopNotificationEventIndex = NSNotFound;
  shouldRearmSuccessor = !shouldFire &&
                         _inumaCurrentNormalNotificationRequired &&
                         _frameAvailable && _textureId != -1 &&
                         _inumaCurrentFrameGeneration != 0;
  if (shouldRearmSuccessor) {
    successorTextureId = _textureId;
    successorFrameTimestampNs = _inumaFrameTimestampNs;
    successorFrameGeneration = _inumaCurrentFrameGeneration;
    successorRendererStateGeneration = _inumaRendererStateGeneration;
  }
  os_unfair_lock_unlock(&_lock);

  if (shouldFire && registry != nil) {
    [registry textureFrameAvailable:textureId];
  }
  const uint64_t callbackEnded = InumaMonotonicNanoseconds();
  if (eventIndex != NSNotFound) {
    os_unfair_lock_lock(&_lock);
    if (_inumaTrace.enabled &&
        eventIndex < _inumaTrace.main_run_loop_notification_event_count) {
      _inumaTrace
          .main_run_loop_notification_callback_duration_samples[eventIndex] =
          callbackEnded - callbackStarted;
    }
    os_unfair_lock_unlock(&_lock);
  }
  if (shouldRearmSuccessor) {
    [self inumaArmMainRunLoopNotificationForTextureId:successorTextureId
                                     frameTimestampNs:
                                         successorFrameTimestampNs
                                      frameGeneration:
                                          successorFrameGeneration
                              rendererStateGeneration:
                                  successorRendererStateGeneration
                                       successorRearm:true];
  }
}

- (void)inumaCloseMainRunLoopNotificationTokenLockedForLifecycle {
  if (!InumaMainRunLoopNotificationShouldCloseForLifecycle(
          _inumaMainRunLoopNotificationEnabled,
          _inumaMainRunLoopNotificationTokenOccupied)) {
    return;
  }
  if (_inumaTrace.enabled) {
    _inumaTrace.main_run_loop_notification_lifecycle_closes += 1;
    const NSUInteger eventIndex = _inumaMainRunLoopNotificationEventIndex;
    if (eventIndex != NSNotFound &&
        eventIndex < _inumaTrace.main_run_loop_notification_event_count) {
      _inumaTrace.main_run_loop_notification_outcome_samples[eventIndex] = 3;
    }
  }
  _inumaMainRunLoopNotificationTokenOccupied = false;
  _inumaMainRunLoopNotificationTextureId = -1;
  _inumaMainRunLoopNotificationFrameTimestampNs = 0;
  _inumaMainRunLoopNotificationFrameGeneration = 0;
  _inumaMainRunLoopNotificationRendererStateGeneration = 0;
  _inumaMainRunLoopNotificationArmedMonotonicNs = 0;
  _inumaMainRunLoopNotificationEventIndex = NSNotFound;
}

- (CFRunLoopSourceRef)inumaDetachMainRunLoopNotificationSourceLocked {
  [self inumaCloseMainRunLoopNotificationTokenLockedForLifecycle];
  CFRunLoopSourceRef source = _inumaMainRunLoopNotificationSource;
  _inumaMainRunLoopNotificationSource = NULL;
  return source;
}

- (void)inumaInvalidateMainRunLoopNotificationSource:
    (CFRunLoopSourceRef)source {
  if (source == NULL) {
    return;
  }
  __block bool removed = false;
  void (^invalidateSource)(void) = ^{
    CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
    removed = CFRunLoopContainsSource(mainRunLoop, source,
                                      kCFRunLoopCommonModes);
    if (removed) {
      CFRunLoopRemoveSource(mainRunLoop, source, kCFRunLoopCommonModes);
    }
    CFRunLoopSourceInvalidate(source);
  };
  if (NSThread.isMainThread) {
    invalidateSource();
  } else {
    dispatch_sync(dispatch_get_main_queue(), invalidateSource);
  }
  os_unfair_lock_lock(&_lock);
  if (_inumaTrace.enabled) {
    _inumaTrace.main_run_loop_notification_source_removals += removed ? 1 : 0;
    _inumaTrace.main_run_loop_notification_source_invalidations += 1;
  }
  os_unfair_lock_unlock(&_lock);
  CFRelease(source);
}

- (void)inumaScheduleTextureNotificationForTextureId:(int64_t)textureId
                                    frameTimestampNs:
                                        (int64_t)frameTimestampNs
                                     frameGeneration:
                                         (uint64_t)frameGeneration
                             rendererStateGeneration:
                                 (uint64_t)rendererStateGeneration
                                   bypassMinimumHold:(bool)bypassMinimumHold
                                  recordRescueBypass:(bool)recordRescueBypass
                            recordRasterRepeatRetry:
                                (bool)recordRasterRepeatRetry {
  const uint64_t enqueuedAt = InumaMonotonicNanoseconds();
  const bool ordinaryNormalPath = !bypassMinimumHold &&
                                  !recordRescueBypass &&
                                  !recordRasterRepeatRetry;
  __block uint64_t scheduledDelayNs = 0;
  __block NSUInteger rasterRepeatRetryEventIndex = NSNotFound;
  os_unfair_lock_lock(&_lock);
  const bool notificationCanBeScheduled =
      _inumaRendererStateGeneration == rendererStateGeneration &&
      _textureId == textureId && _frameAvailable &&
      InumaFrameOwnershipValuesMatch(
          _inumaCurrentFrameGeneration, frameGeneration,
          _inumaFrameTimestampNs, frameTimestampNs);
  if (recordRasterRepeatRetry && _inumaTrace.enabled) {
    _inumaTrace.raster_repeat_platform_retry_schedules += 1;
    rasterRepeatRetryEventIndex = InumaReserveTraceSample(
        &_inumaTrace.raster_repeat_platform_retry_event_count,
        &_inumaTrace.sample_capacity_exhaustions);
    if (rasterRepeatRetryEventIndex != NSNotFound) {
      _inumaTrace
          .raster_repeat_platform_retry_schedule_offset_samples
              [rasterRepeatRetryEventIndex] =
          enqueuedAt - _inumaTraceStartedMonotonicNs;
      _inumaTrace
          .raster_repeat_platform_retry_frame_timestamp_ns_samples
              [rasterRepeatRetryEventIndex] = frameTimestampNs;
      _inumaTrace.raster_repeat_platform_retry_frame_generation_samples
          [rasterRepeatRetryEventIndex] = frameGeneration;
    }
    if (!notificationCanBeScheduled) {
      // The raster repeat already owns this retry even if lifecycle state
      // changed between copyPixelBuffer unlocking and this first scheduler
      // lock.  Close that schedule once here; no delayed branch will run.
      _inumaTrace.raster_repeat_platform_retry_stale_fires += 1;
      if (rasterRepeatRetryEventIndex != NSNotFound &&
          rasterRepeatRetryEventIndex <
              _inumaTrace.raster_repeat_platform_retry_event_count) {
        _inumaTrace.raster_repeat_platform_retry_fire_offset_samples
            [rasterRepeatRetryEventIndex] = 0;
      }
    }
  }
  if (notificationCanBeScheduled && bypassMinimumHold && recordRescueBypass &&
      _inumaTrace.enabled) {
    _inumaTrace.rescue_hold_bypasses += 1;
    const NSUInteger bypassIndex = InumaReserveTraceSample(
        &_inumaTrace.rescue_hold_bypass_count,
        &_inumaTrace.sample_capacity_exhaustions);
    if (bypassIndex != NSNotFound) {
      _inumaTrace
          .rescue_hold_bypass_frame_timestamp_ns_samples[bypassIndex] =
          frameTimestampNs;
      _inumaTrace.rescue_hold_bypass_frame_generation_samples[bypassIndex] =
          frameGeneration;
    }
  }
  if (notificationCanBeScheduled && !bypassMinimumHold &&
      _inumaMinimumTextureHoldNs > 0 &&
      _inumaLastCopyMonotonicNs > 0 &&
      enqueuedAt >= _inumaLastCopyMonotonicNs) {
    const uint64_t currentTenureNs =
        enqueuedAt - _inumaLastCopyMonotonicNs;
    if (currentTenureNs < _inumaMinimumTextureHoldNs) {
      scheduledDelayNs = _inumaMinimumTextureHoldNs - currentTenureNs;
      if (_inumaTrace.enabled) {
        _inumaTrace.texture_hold_applied += 1;
        const NSUInteger holdIndex = _inumaTrace.texture_hold_delay_count;
        const bool holdRetained = InumaAppendTraceSample(
            _inumaTrace.texture_hold_delay_samples,
            &_inumaTrace.texture_hold_delay_count,
            scheduledDelayNs,
            &_inumaTrace.sample_capacity_exhaustions);
        if (holdRetained) {
          _inumaTrace
              .texture_hold_frame_timestamp_ns_samples[holdIndex] =
              frameTimestampNs;
          _inumaTrace.texture_hold_frame_generation_samples[holdIndex] =
              frameGeneration;
        }
      }
    }
  }
  os_unfair_lock_unlock(&_lock);
  if (!notificationCanBeScheduled) {
    return;
  }

  __weak FlutterRTCVideoRenderer *weakSelf = self;
  void (^notifyTextureFrameAvailable)(void) = ^{
    FlutterRTCVideoRenderer *strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    const uint64_t notifyStarted = InumaMonotonicNanoseconds();
    os_unfair_lock_lock(&strongSelf->_lock);
    const bool notificationIsCurrent =
        strongSelf->_inumaRendererStateGeneration ==
            rendererStateGeneration &&
        strongSelf->_textureId == textureId &&
        strongSelf->_frameAvailable &&
        InumaFrameOwnershipValuesMatch(
            strongSelf->_inumaCurrentFrameGeneration, frameGeneration,
            strongSelf->_inumaFrameTimestampNs, frameTimestampNs);
    const bool traceEnabled = strongSelf->_inumaTrace.enabled;
    id<FlutterTextureRegistry> registry = strongSelf->_registry;
    if (traceEnabled && !notificationIsCurrent) {
      strongSelf->_inumaTrace.stale_texture_notifications += 1;
    }
    if (recordRasterRepeatRetry && notificationIsCurrent &&
        registry != nil && strongSelf->_inumaCurrentFrameRepeatDeferred) {
      strongSelf->_inumaCurrentRepeatRetryFired = true;
    }
    if (ordinaryNormalPath && notificationIsCurrent && registry != nil) {
      strongSelf->_inumaCurrentNormalNotificationRequired = false;
    }
    if (traceEnabled && recordRasterRepeatRetry) {
      if (notificationIsCurrent && registry != nil) {
        strongSelf->_inumaTrace.raster_repeat_platform_retry_fires += 1;
        if (rasterRepeatRetryEventIndex != NSNotFound &&
            rasterRepeatRetryEventIndex <
                strongSelf->_inumaTrace
                    .raster_repeat_platform_retry_event_count &&
            strongSelf->_inumaTraceStartedMonotonicNs > 0 &&
            notifyStarted >= strongSelf->_inumaTraceStartedMonotonicNs) {
          strongSelf->_inumaTrace
              .raster_repeat_platform_retry_fire_offset_samples
                  [rasterRepeatRetryEventIndex] =
              notifyStarted - strongSelf->_inumaTraceStartedMonotonicNs;
        }
      } else {
        strongSelf->_inumaTrace.raster_repeat_platform_retry_stale_fires += 1;
      }
    }
    if (traceEnabled && notificationIsCurrent && registry != nil &&
        strongSelf->_inumaTraceStartedMonotonicNs > 0 &&
        notifyStarted >= strongSelf->_inumaTraceStartedMonotonicNs) {
      const NSUInteger notifyEventIndex = InumaReserveTraceSample(
          &strongSelf->_inumaTrace.texture_notify_event_count,
          &strongSelf->_inumaTrace.sample_capacity_exhaustions);
      if (notifyEventIndex != NSNotFound) {
        strongSelf->_inumaTrace
            .texture_notify_event_offset_samples[notifyEventIndex] =
            notifyStarted - strongSelf->_inumaTraceStartedMonotonicNs;
        strongSelf->_inumaTrace
            .texture_notify_frame_timestamp_ns_samples[notifyEventIndex] =
            frameTimestampNs;
        strongSelf->_inumaTrace
            .texture_notify_frame_generation_samples[notifyEventIndex] =
            frameGeneration;
        strongSelf->_inumaTrace
            .texture_notify_scheduled_delay_samples[notifyEventIndex] =
            scheduledDelayNs;
        const uint64_t plannedDeadlineNs = enqueuedAt + scheduledDelayNs;
        strongSelf->_inumaTrace
            .texture_notify_deadline_lateness_samples[notifyEventIndex] =
            notifyStarted >= plannedDeadlineNs
                ? notifyStarted - plannedDeadlineNs
                : 0;
      }
    }
    os_unfair_lock_unlock(&strongSelf->_lock);
    if (!notificationIsCurrent || registry == nil) {
      return;
    }
    [registry textureFrameAvailable:textureId];
    if (traceEnabled) {
      const uint64_t notifyEnded = InumaMonotonicNanoseconds();
      os_unfair_lock_lock(&strongSelf->_lock);
      if (notifyStarted >= enqueuedAt) {
        InumaAppendTraceSample(
            strongSelf->_inumaTrace.texture_notify_dispatch_samples,
            &strongSelf->_inumaTrace.texture_notify_dispatch_count,
            notifyStarted - enqueuedAt,
            &strongSelf->_inumaTrace.sample_capacity_exhaustions);
      }
      InumaAppendTraceSample(
          strongSelf->_inumaTrace.texture_notify_samples,
          &strongSelf->_inumaTrace.texture_notify_count,
          notifyEnded - notifyStarted,
          &strongSelf->_inumaTrace.sample_capacity_exhaustions);
      os_unfair_lock_unlock(&strongSelf->_lock);
    }
  };
  void (^notifyOnNextPlatformTurn)(void) = ^{
    FlutterRTCVideoRenderer *strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    const uint64_t platformTurnScheduledAt = InumaMonotonicNanoseconds();
    os_unfair_lock_lock(&strongSelf->_lock);
    const bool platformTurnCanBeScheduled =
        strongSelf->_inumaRendererStateGeneration ==
            rendererStateGeneration &&
        strongSelf->_textureId == textureId &&
        strongSelf->_frameAvailable &&
        InumaFrameOwnershipValuesMatch(
            strongSelf->_inumaCurrentFrameGeneration, frameGeneration,
            strongSelf->_inumaFrameTimestampNs, frameTimestampNs);
    if (platformTurnCanBeScheduled && strongSelf->_inumaTrace.enabled) {
      strongSelf->_inumaTrace.texture_notification_platform_turn_schedules +=
          1;
      if (strongSelf->_inumaTraceStartedMonotonicNs > 0 &&
          platformTurnScheduledAt >=
              strongSelf->_inumaTraceStartedMonotonicNs) {
        strongSelf->_inumaTrace
            .texture_notification_platform_turn_last_schedule_offset_ns =
            platformTurnScheduledAt -
            strongSelf->_inumaTraceStartedMonotonicNs;
      }
    } else if (!platformTurnCanBeScheduled && recordRasterRepeatRetry &&
               strongSelf->_inumaTrace.enabled) {
      // Repeat ownership was already recorded at method entry.  If lifecycle
      // state changes before the platform block can be queued, close that one
      // schedule as stale here and leave its fire-offset sample at zero.
      strongSelf->_inumaTrace.raster_repeat_platform_retry_stale_fires += 1;
      if (rasterRepeatRetryEventIndex != NSNotFound &&
          rasterRepeatRetryEventIndex <
              strongSelf->_inumaTrace
                  .raster_repeat_platform_retry_event_count) {
        strongSelf->_inumaTrace
            .raster_repeat_platform_retry_fire_offset_samples
                [rasterRepeatRetryEventIndex] = 0;
      }
    }
    os_unfair_lock_unlock(&strongSelf->_lock);
    if (!platformTurnCanBeScheduled) {
      return;
    }
    FlutterRTCVideoRenderer *platformTurnOwner = strongSelf;
    dispatch_async(dispatch_get_main_queue(), ^{
      FlutterRTCVideoRenderer *innerSelf = platformTurnOwner;
      const uint64_t platformTurnFiredAt = InumaMonotonicNanoseconds();
      os_unfair_lock_lock(&innerSelf->_lock);
      if (innerSelf->_inumaTrace.enabled) {
        innerSelf->_inumaTrace.texture_notification_platform_turn_fires += 1;
        if (innerSelf->_inumaTraceStartedMonotonicNs > 0 &&
            platformTurnFiredAt >=
                innerSelf->_inumaTraceStartedMonotonicNs) {
          innerSelf->_inumaTrace
              .texture_notification_platform_turn_last_fire_offset_ns =
              platformTurnFiredAt -
              innerSelf->_inumaTraceStartedMonotonicNs;
        }
      }
      os_unfair_lock_unlock(&innerSelf->_lock);
      // Always enter the final guarded closure for an owned platform turn.
      // A lifecycle generation change is recorded there as a stale retry, and
      // the registry call remains unreachable unless the full state matches.
      notifyTextureFrameAvailable();
    });
  };
  void (^notifyOnSelectedPlatformOwner)(void) = ^{
    FlutterRTCVideoRenderer *strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    if (ordinaryNormalPath &&
        strongSelf->_inumaMainRunLoopNotificationEnabled &&
        [strongSelf
            inumaArmMainRunLoopNotificationForTextureId:textureId
                                         frameTimestampNs:frameTimestampNs
                                          frameGeneration:frameGeneration
                                  rendererStateGeneration:
                                      rendererStateGeneration
                                           successorRearm:false]) {
      return;
    }
    notifyOnNextPlatformTurn();
  };
  if (scheduledDelayNs == 0) {
    notifyOnSelectedPlatformOwner();
  } else {
    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT,
        dispatch_get_main_queue());
    if (timer == nil) {
      os_unfair_lock_lock(&_lock);
      if (_inumaTrace.enabled) {
        _inumaTrace.strict_hold_timer_create_failures += 1;
      }
      os_unfair_lock_unlock(&_lock);
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)scheduledDelayNs),
          dispatch_get_main_queue(), notifyOnSelectedPlatformOwner);
      return;
    }

    __block NSUInteger timerEventIndex = NSNotFound;
    const uint64_t deadlineNs = enqueuedAt + scheduledDelayNs;
    os_unfair_lock_lock(&_lock);
    const bool timerFrameIsCurrent =
        _inumaRendererStateGeneration == rendererStateGeneration &&
        _textureId == textureId && _frameAvailable &&
        InumaFrameOwnershipValuesMatch(
            _inumaCurrentFrameGeneration, frameGeneration,
            _inumaFrameTimestampNs, frameTimestampNs);
    const bool timerSlotAvailable = _inumaTextureHoldTimer == nil;
    const bool timerIsCurrent = timerFrameIsCurrent && timerSlotAvailable;
    if (timerIsCurrent) {
      _inumaTextureHoldTimer = timer;
      if (_inumaTrace.enabled) {
        _inumaTrace.strict_hold_timer_created += 1;
        if (_inumaTraceStartedMonotonicNs > 0 &&
            deadlineNs >= _inumaTraceStartedMonotonicNs) {
          timerEventIndex = InumaReserveTraceSample(
              &_inumaTrace.strict_hold_timer_event_count,
              &_inumaTrace.sample_capacity_exhaustions);
          if (timerEventIndex != NSNotFound) {
            _inumaTrace.strict_hold_timer_deadline_offset_samples
                [timerEventIndex] =
                deadlineNs - _inumaTraceStartedMonotonicNs;
            _inumaTrace.strict_hold_timer_frame_timestamp_ns_samples
                [timerEventIndex] = frameTimestampNs;
            _inumaTrace.strict_hold_timer_frame_generation_samples
                [timerEventIndex] = frameGeneration;
          }
        }
      }
    } else if (_inumaTrace.enabled) {
      if (timerFrameIsCurrent && !timerSlotAvailable) {
        _inumaTrace.strict_hold_timer_coalesced_existing += 1;
      } else {
        _inumaTrace.strict_hold_timer_stale_before_ownership += 1;
      }
    }
    os_unfair_lock_unlock(&_lock);
    if (!timerIsCurrent) {
      dispatch_source_cancel(timer);
      dispatch_resume(timer);
      return;
    }

    __weak dispatch_source_t weakTimer = timer;
    dispatch_source_set_event_handler(timer, ^{
      dispatch_source_t strongTimer = weakTimer;
      FlutterRTCVideoRenderer *strongSelf = weakSelf;
      if (strongTimer == nil) {
        return;
      }
      if (strongSelf == nil) {
        dispatch_source_cancel(strongTimer);
        return;
      }
      const uint64_t firedAt = InumaMonotonicNanoseconds();
      os_unfair_lock_lock(&strongSelf->_lock);
      const bool ownsTimer =
          strongSelf->_inumaTextureHoldTimer == strongTimer;
      const bool timerStateIsCurrent =
          ownsTimer && strongSelf->_inumaRendererStateGeneration ==
                           rendererStateGeneration &&
          strongSelf->_textureId == textureId &&
          strongSelf->_frameAvailable &&
          InumaFrameOwnershipValuesMatch(
              strongSelf->_inumaCurrentFrameGeneration, frameGeneration,
              strongSelf->_inumaFrameTimestampNs, frameTimestampNs);
      if (ownsTimer) {
        strongSelf->_inumaTextureHoldTimer = nil;
      }
      if (strongSelf->_inumaTrace.enabled) {
        strongSelf->_inumaTrace.strict_hold_timer_fired += 1;
        if (timerEventIndex != NSNotFound &&
            timerEventIndex <
                strongSelf->_inumaTrace.strict_hold_timer_event_count &&
            strongSelf->_inumaTraceStartedMonotonicNs > 0 &&
            firedAt >= strongSelf->_inumaTraceStartedMonotonicNs) {
          strongSelf->_inumaTrace.strict_hold_timer_fire_offset_samples
              [timerEventIndex] =
              firedAt - strongSelf->_inumaTraceStartedMonotonicNs;
        }
      }
      os_unfair_lock_unlock(&strongSelf->_lock);
      dispatch_source_cancel(strongTimer);
      if (timerStateIsCurrent) {
        notifyOnSelectedPlatformOwner();
      }
    });
    dispatch_source_set_timer(
        timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)scheduledDelayNs),
        DISPATCH_TIME_FOREVER, 0);
    dispatch_resume(timer);
  }
}

- (void)inumaScheduleDisplayLinkedRescueForTextureId:(int64_t)textureId
                                    frameTimestampNs:
                                        (int64_t)frameTimestampNs
                                     frameGeneration:
                                         (uint64_t)frameGeneration
                             rendererStateGeneration:
                                 (uint64_t)rendererStateGeneration
                            predecessorCopyUptimeNs:
                                (uint64_t)predecessorCopyUptimeNs {
  const uint64_t scheduledAt = InumaMonotonicNanoseconds();
  __weak FlutterRTCVideoRenderer *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    FlutterRTCVideoRenderer *strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    if (@available(macOS 14.0, *)) {
      NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
      CADisplayLink *displayLink =
          [screen displayLinkWithTarget:strongSelf
                              selector:@selector(inumaRescueDisplayLinkDidFire:)];
      os_unfair_lock_lock(&strongSelf->_lock);
      const bool rescueIsCurrent =
          screen != nil && displayLink != nil &&
          strongSelf->_inumaRendererStateGeneration ==
              rendererStateGeneration &&
          strongSelf->_textureId == textureId &&
          strongSelf->_frameAvailable &&
          InumaFrameOwnershipValuesMatch(
              strongSelf->_inumaCurrentFrameGeneration, frameGeneration,
              strongSelf->_inumaFrameTimestampNs, frameTimestampNs) &&
          strongSelf->_inumaRescueDisplayLink == nil;
      if (rescueIsCurrent) {
        strongSelf->_inumaRescueDisplayLink = displayLink;
        strongSelf->_inumaRescueDisplayLinkFrameTimestampNs =
            frameTimestampNs;
        strongSelf->_inumaRescueDisplayLinkFrameGeneration =
            frameGeneration;
        strongSelf->_inumaRescueDisplayLinkRendererStateGeneration =
            rendererStateGeneration;
        strongSelf->_inumaRescuePredecessorCopyUptimeNs =
            predecessorCopyUptimeNs;
        strongSelf->_inumaRescueDisplayLinkEventIndex = NSNotFound;
        if (strongSelf->_inumaTrace.enabled) {
          strongSelf->_inumaTrace.rescue_display_link_schedules += 1;
          if (strongSelf->_inumaTraceStartedMonotonicNs > 0 &&
              scheduledAt >= strongSelf->_inumaTraceStartedMonotonicNs) {
            const NSUInteger eventIndex = InumaReserveTraceSample(
                &strongSelf->_inumaTrace.rescue_display_link_event_count,
                &strongSelf->_inumaTrace.sample_capacity_exhaustions);
            if (eventIndex != NSNotFound) {
              strongSelf->_inumaTrace
                  .rescue_display_link_schedule_offset_samples[eventIndex] =
                  scheduledAt - strongSelf->_inumaTraceStartedMonotonicNs;
              strongSelf->_inumaTrace
                  .rescue_display_link_frame_timestamp_ns_samples[eventIndex] =
                  frameTimestampNs;
              strongSelf->_inumaTrace
                  .rescue_display_link_frame_generation_samples[eventIndex] =
                  frameGeneration;
              strongSelf->_inumaRescueDisplayLinkEventIndex = eventIndex;
            }
          }
        }
      }
      os_unfair_lock_unlock(&strongSelf->_lock);
      if (rescueIsCurrent) {
        [displayLink addToRunLoop:NSRunLoop.mainRunLoop
                         forMode:NSRunLoopCommonModes];
        return;
      }
      [displayLink invalidate];
      if (screen == nil || displayLink == nil) {
        os_unfair_lock_lock(&strongSelf->_lock);
        const bool fallbackIsCurrent =
            strongSelf->_inumaRendererStateGeneration ==
                rendererStateGeneration &&
            strongSelf->_textureId == textureId &&
            strongSelf->_frameAvailable &&
            InumaFrameOwnershipValuesMatch(
                strongSelf->_inumaCurrentFrameGeneration, frameGeneration,
                strongSelf->_inumaFrameTimestampNs, frameTimestampNs);
        if (fallbackIsCurrent && strongSelf->_inumaTrace.enabled) {
          strongSelf->_inumaTrace.rescue_display_link_fallbacks += 1;
        }
        os_unfair_lock_unlock(&strongSelf->_lock);
        if (fallbackIsCurrent) {
          [strongSelf
              inumaScheduleTextureNotificationForTextureId:textureId
                                          frameTimestampNs:frameTimestampNs
                                           frameGeneration:frameGeneration
                                   rendererStateGeneration:
                                       rendererStateGeneration
                                         bypassMinimumHold:false
                                        recordRescueBypass:false
                                  recordRasterRepeatRetry:false];
        }
      }
      return;
    }

    os_unfair_lock_lock(&strongSelf->_lock);
    const bool fallbackIsCurrent =
        strongSelf->_inumaRendererStateGeneration ==
            rendererStateGeneration &&
        strongSelf->_textureId == textureId &&
        strongSelf->_frameAvailable &&
        InumaFrameOwnershipValuesMatch(
            strongSelf->_inumaCurrentFrameGeneration, frameGeneration,
            strongSelf->_inumaFrameTimestampNs, frameTimestampNs);
    if (fallbackIsCurrent && strongSelf->_inumaTrace.enabled) {
      strongSelf->_inumaTrace.rescue_display_link_fallbacks += 1;
    }
    os_unfair_lock_unlock(&strongSelf->_lock);
    if (fallbackIsCurrent) {
      [strongSelf inumaScheduleTextureNotificationForTextureId:textureId
                                             frameTimestampNs:
                                                 frameTimestampNs
                                              frameGeneration:
                                                  frameGeneration
                                      rendererStateGeneration:
                                          rendererStateGeneration
                                            bypassMinimumHold:false
                                           recordRescueBypass:false
                                     recordRasterRepeatRetry:false];
    }
  });
}

- (void)inumaRescueDisplayLinkDidFire:(CADisplayLink *)displayLink
    API_AVAILABLE(macos(14.0)) {
  const uint64_t firedAt = InumaMonotonicNanoseconds();
  const uint64_t displayedAtUptimeNs =
      InumaDisplayLinkTimestampNanoseconds(displayLink);
  int64_t textureId = -1;
  int64_t frameTimestampNs = 0;
  uint64_t frameGeneration = 0;
  uint64_t rendererStateGeneration = 0;
  bool rescueIsCurrent = false;
  bool predecessorWasPresented = false;
  bool deferUntilPresentation = false;
  os_unfair_lock_lock(&_lock);
  const bool ownsDisplayLink = _inumaRescueDisplayLink == displayLink;
  if (ownsDisplayLink) {
    textureId = _textureId;
    frameTimestampNs = _inumaRescueDisplayLinkFrameTimestampNs;
    frameGeneration = _inumaRescueDisplayLinkFrameGeneration;
    rendererStateGeneration =
        _inumaRescueDisplayLinkRendererStateGeneration;
    rescueIsCurrent =
        _inumaRendererStateGeneration == rendererStateGeneration &&
        textureId != -1 && _frameAvailable &&
        InumaFrameOwnershipValuesMatch(
            _inumaCurrentFrameGeneration, frameGeneration,
            _inumaFrameTimestampNs, frameTimestampNs);
    predecessorWasPresented =
        _inumaRescuePredecessorCopyUptimeNs > 0 &&
        displayedAtUptimeNs >= _inumaRescuePredecessorCopyUptimeNs;
    deferUntilPresentation = rescueIsCurrent && !predecessorWasPresented;
    if (_inumaTrace.enabled) {
      _inumaTrace.rescue_display_link_callbacks += 1;
      const NSUInteger eventIndex = _inumaRescueDisplayLinkEventIndex;
      if (eventIndex != NSNotFound &&
          eventIndex < _inumaTrace.rescue_display_link_event_count) {
        _inumaTrace.rescue_display_link_callback_count_samples[eventIndex] +=
            1;
      }
      if (deferUntilPresentation) {
        _inumaTrace.rescue_display_link_deferrals += 1;
      } else if (rescueIsCurrent && predecessorWasPresented) {
        _inumaTrace.rescue_display_link_fires += 1;
        if (eventIndex != NSNotFound &&
            eventIndex < _inumaTrace.rescue_display_link_event_count &&
            _inumaTraceStartedMonotonicNs > 0 &&
            firedAt >= _inumaTraceStartedMonotonicNs) {
          _inumaTrace.rescue_display_link_fire_offset_samples[eventIndex] =
              firedAt - _inumaTraceStartedMonotonicNs;
          _inumaTrace.rescue_display_link_presentation_ack_samples[eventIndex] =
              displayedAtUptimeNs - _inumaRescuePredecessorCopyUptimeNs;
        }
      }
      if (!rescueIsCurrent) {
        _inumaTrace.rescue_display_link_stale_fires += 1;
      }
    }
    if (!deferUntilPresentation) {
      _inumaRescueDisplayLink = nil;
      _inumaRescueDisplayLinkFrameTimestampNs = 0;
      _inumaRescueDisplayLinkFrameGeneration = 0;
      _inumaRescueDisplayLinkRendererStateGeneration = 0;
      _inumaRescuePredecessorCopyUptimeNs = 0;
      _inumaRescueDisplayLinkEventIndex = NSNotFound;
    }
  }
  os_unfair_lock_unlock(&_lock);
  if (deferUntilPresentation) {
    return;
  }
  [displayLink invalidate];
  if (rescueIsCurrent && predecessorWasPresented) {
    [self inumaScheduleTextureNotificationForTextureId:textureId
                                      frameTimestampNs:frameTimestampNs
                                      frameGeneration:frameGeneration
                               rendererStateGeneration:
                                   rendererStateGeneration
                                     bypassMinimumHold:true
                                    recordRescueBypass:false
                              recordRasterRepeatRetry:false];
  }
}

- (void)inumaCancelTextureHoldTimerLocked {
  dispatch_source_t timer = _inumaTextureHoldTimer;
  if (timer == nil) {
    return;
  }
  _inumaTextureHoldTimer = nil;
  dispatch_source_cancel(timer);
  if (_inumaTrace.enabled) {
    _inumaTrace.strict_hold_timer_cancelled += 1;
  }
}

- (void)inumaCancelRescueDisplayLinkLocked {
  CADisplayLink *displayLink = _inumaRescueDisplayLink;
  if (displayLink == nil) {
    return;
  }
  _inumaRescueDisplayLink = nil;
  _inumaRescueDisplayLinkFrameTimestampNs = 0;
  _inumaRescueDisplayLinkFrameGeneration = 0;
  _inumaRescueDisplayLinkRendererStateGeneration = 0;
  _inumaRescuePredecessorCopyUptimeNs = 0;
  _inumaRescueDisplayLinkEventIndex = NSNotFound;
  [displayLink invalidate];
  if (_inumaTrace.enabled) {
    _inumaTrace.rescue_display_link_cancellations += 1;
  }
}

- (void)inumaCancelDirectFrameDisplayRetryLocked {
  CADisplayLink *displayLink = _inumaDirectFrameDisplayRetryLink;
  if (displayLink == nil || !_inumaDirectFrameDisplayRetryActive) {
    return;
  }
  const NSUInteger eventIndex = _inumaDirectFrameDisplayRetryEventIndex;
  _inumaDirectFrameDisplayRetryActive = false;
  _inumaDirectFrameDisplayRetryFrameTimestampNs = 0;
  _inumaDirectFrameDisplayRetryFrameGeneration = 0;
  _inumaDirectFrameDisplayRetryRendererStateGeneration = 0;
  _inumaDirectFrameDisplayRetryFrameReadyMonotonicNs = 0;
  _inumaDirectFrameDisplayRetryScheduledMonotonicNs = 0;
  _inumaDirectFrameDisplayRetryEventIndex = NSNotFound;
  // Apple documents isPaused as thread-safe. Pause the reusable run-loop
  // object while ownership is locked so a later arm cannot be undone by a
  // delayed cancellation block. Invalidation is reserved for final dispose.
  displayLink.paused = YES;
  if (_inumaTrace.enabled) {
    _inumaTrace.direct_frame_display_retry_cancellations += 1;
    _inumaTrace.direct_frame_display_retry_link_pauses += 1;
    if (eventIndex != NSNotFound &&
        eventIndex < _inumaTrace.direct_frame_display_retry_event_count) {
      _inumaTrace.direct_frame_display_retry_outcome_samples[eventIndex] =
          InumaDirectFrameDisplayRetryOutcomeCancelled;
    }
  }
}

- (void)inumaInvalidateDirectFrameDisplayRetryLinkLocked {
  CADisplayLink *displayLink = _inumaDirectFrameDisplayRetryLink;
  if (displayLink == nil) {
    return;
  }
  _inumaDirectFrameDisplayRetryActive = false;
  _inumaDirectFrameDisplayRetryLink = nil;
  _inumaDirectFrameDisplayRetryFrameTimestampNs = 0;
  _inumaDirectFrameDisplayRetryFrameGeneration = 0;
  _inumaDirectFrameDisplayRetryRendererStateGeneration = 0;
  _inumaDirectFrameDisplayRetryFrameReadyMonotonicNs = 0;
  _inumaDirectFrameDisplayRetryScheduledMonotonicNs = 0;
  _inumaDirectFrameDisplayRetryEventIndex = NSNotFound;
  displayLink.paused = YES;
  if (_inumaTrace.enabled) {
    _inumaTrace.direct_frame_display_retry_link_invalidations += 1;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [displayLink invalidate];
  });
}

- (void)inumaRetainCopiedBufferHoldLocked:(CVPixelBufferRef)pixelBuffer
                                 copiedAt:(uint64_t)copiedAt {
  if (_inumaCopiedBufferHoldCount == kInumaCopiedBufferHoldCapacity) {
    [self inumaReleaseOldestCopiedBufferHoldLockedAt:copiedAt
                                           lifecycle:false];
  }
  const NSUInteger index =
      (_inumaCopiedBufferHoldHead + _inumaCopiedBufferHoldCount) %
      kInumaCopiedBufferHoldCapacity;
  _inumaCopiedBufferHoldRefs[index] = CVBufferRetain(pixelBuffer);
  _inumaCopiedBufferHoldStartedMonotonicNs[index] = copiedAt;
  _inumaCopiedBufferHoldCount += 1;
  if (_inumaTrace.enabled) {
    _inumaTrace.copied_buffer_holds += 1;
  }
}

- (void)inumaReleaseOldestCopiedBufferHoldLockedAt:(uint64_t)releasedAt
                                          lifecycle:(bool)lifecycle {
  if (_inumaCopiedBufferHoldCount == 0) {
    return;
  }
  const NSUInteger index = _inumaCopiedBufferHoldHead;
  CVPixelBufferRef heldBuffer = _inumaCopiedBufferHoldRefs[index];
  const uint64_t heldAt =
      _inumaCopiedBufferHoldStartedMonotonicNs[index];
  _inumaCopiedBufferHoldRefs[index] = nil;
  _inumaCopiedBufferHoldStartedMonotonicNs[index] = 0;
  _inumaCopiedBufferHoldHead =
      (_inumaCopiedBufferHoldHead + 1) %
      kInumaCopiedBufferHoldCapacity;
  _inumaCopiedBufferHoldCount -= 1;
  if (_inumaTrace.enabled) {
    if (lifecycle) {
      _inumaTrace.copied_buffer_lifecycle_releases += 1;
    } else {
      _inumaTrace.copied_buffer_second_next_copy_releases += 1;
      if (heldAt > 0 && releasedAt >= heldAt) {
        InumaAppendTraceSample(
            _inumaTrace.copied_buffer_second_next_copy_hold_samples,
            &_inumaTrace.copied_buffer_second_next_copy_hold_count,
            releasedAt - heldAt,
            &_inumaTrace.sample_capacity_exhaustions);
      }
    }
  }
  if (heldBuffer != nil) {
    CVBufferRelease(heldBuffer);
  }
}

- (void)inumaReleaseAllCopiedBufferHoldsLockedAt:(uint64_t)releasedAt {
  while (_inumaCopiedBufferHoldCount > 0) {
    [self inumaReleaseOldestCopiedBufferHoldLockedAt:releasedAt
                                           lifecycle:true];
  }
  _inumaCopiedBufferHoldHead = 0;
}

- (void)inumaClearPendingTextureFramesLocked {
  while (_inumaPendingTextureFrameCount > 0) {
    InumaPendingTextureFrame pending =
        _inumaPendingTextureFrames[_inumaPendingTextureFrameHead];
    _inumaPendingTextureFrames[_inumaPendingTextureFrameHead] =
        (InumaPendingTextureFrame){0};
    _inumaPendingTextureFrameHead =
        (_inumaPendingTextureFrameHead + 1) %
        kInumaPendingTextureFrameCapacity;
    _inumaPendingTextureFrameCount -= 1;
    if (pending.pixel_buffer != nil) {
      CVBufferRelease(pending.pixel_buffer);
    }
    if (_inumaTrace.enabled) {
      _inumaTrace.queue_cleared_frames += 1;
      if (pending.from_emergency_grace) {
        _inumaTrace.emergency_grace_clears += 1;
      }
    }
  }
  _inumaPendingTextureFrameHead = 0;
  if (_inumaEmergencyGraceTextureFrame.pixel_buffer != nil) {
    CVBufferRelease(_inumaEmergencyGraceTextureFrame.pixel_buffer);
    _inumaEmergencyGraceTextureFrame = (InumaPendingTextureFrame){0};
    if (_inumaTrace.enabled) {
      _inumaTrace.emergency_grace_clears += 1;
    }
  }
  _inumaEmergencyGraceBurstArmed = true;
}

- (void)inumaResetStockBGRAPixelBufferPoolForSize:(CGSize)size {
  if (_inumaStockBGRAPixelBufferPool != nil) {
    CVPixelBufferPoolRelease(_inumaStockBGRAPixelBufferPool);
    _inumaStockBGRAPixelBufferPool = nil;
  }
  NSDictionary *pixelAttributes = @{
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    (id)kCVPixelBufferWidthKey : @(size.width),
    (id)kCVPixelBufferHeightKey : @(size.height),
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
  };
  NSDictionary *poolAttributes = @{
    (id)kCVPixelBufferPoolMinimumBufferCountKey :
        @(kInumaStockBGRAPoolMinimumBufferCount),
  };
  CVReturn result = CVPixelBufferPoolCreate(
      kCFAllocatorDefault, (__bridge CFDictionaryRef)poolAttributes,
      (__bridge CFDictionaryRef)pixelAttributes,
      &_inumaStockBGRAPixelBufferPool);
  if (result != kCVReturnSuccess ||
      _inumaStockBGRAPixelBufferPool == nil) {
    _inumaTrace.stock_bgra_pool_create_failures += 1;
    _inumaStockBGRAPixelBufferPool = nil;
  }
}

- (void)inumaWriteTextureTrace {
  if (!_inumaTrace.enabled || _inumaTracePath.length == 0) {
    return;
  }
  InumaTextureTrace *snapshot = malloc(sizeof(InumaTextureTrace));
  if (snapshot == NULL) {
    return;
  }
  NSUInteger pendingTextureFrameCount = 0;
  NSUInteger copiedBufferHoldCount = 0;
  bool textureHoldTimerActive = false;
  bool rescueDisplayLinkActive = false;
  bool directFrameDisplayRetryActive = false;
  bool mainRunLoopNotificationSourceRegistered = false;
  bool mainRunLoopNotificationTokenOccupied = false;
  bool currentFrameRepeatDeferred = false;
  bool currentFrameRescuePromoted = false;
  bool currentRepeatRetryFired = false;
  bool emergencyGraceOccupied = false;
  bool emergencyGraceBurstArmed = false;
  bool primaryFromEmergencyGrace = false;
  int64_t currentFrameTimestampNs = 0;
  int64_t primaryFrameTimestampNs = 0;
  int64_t emergencyGraceFrameTimestampNs = 0;
  int64_t mainRunLoopNotificationFrameTimestampNs = 0;
  uint64_t currentFrameGeneration = 0;
  uint64_t mainRunLoopNotificationFrameGeneration = 0;
  uint64_t primaryFrameAgeNs = 0;
  uint64_t currentFrameAgeNs = 0;
  uint64_t emergencyGraceResidenceNs = 0;
  uint64_t mainRunLoopNotificationTokenAgeNs = 0;
  os_unfair_lock_lock(&_lock);
  const uint64_t traceSnapshotMonotonicNs = InumaMonotonicNanoseconds();
  InumaCopyTextureTraceLocked(snapshot, &_inumaTrace);
  pendingTextureFrameCount = _inumaPendingTextureFrameCount;
  copiedBufferHoldCount = _inumaCopiedBufferHoldCount;
  textureHoldTimerActive = _inumaTextureHoldTimer != nil;
  rescueDisplayLinkActive = _inumaRescueDisplayLink != nil;
  directFrameDisplayRetryActive = _inumaDirectFrameDisplayRetryActive;
  mainRunLoopNotificationSourceRegistered =
      _inumaMainRunLoopNotificationSource != NULL;
  mainRunLoopNotificationTokenOccupied =
      _inumaMainRunLoopNotificationTokenOccupied;
  mainRunLoopNotificationFrameTimestampNs =
      _inumaMainRunLoopNotificationFrameTimestampNs;
  mainRunLoopNotificationFrameGeneration =
      _inumaMainRunLoopNotificationFrameGeneration;
  if (_inumaMainRunLoopNotificationArmedMonotonicNs > 0 &&
      traceSnapshotMonotonicNs >=
          _inumaMainRunLoopNotificationArmedMonotonicNs) {
    mainRunLoopNotificationTokenAgeNs =
        traceSnapshotMonotonicNs -
        _inumaMainRunLoopNotificationArmedMonotonicNs;
  }
  currentFrameRepeatDeferred = _inumaCurrentFrameRepeatDeferred;
  currentFrameRescuePromoted = _inumaCurrentFrameWasRescuePromoted;
  currentRepeatRetryFired = _inumaCurrentRepeatRetryFired;
  currentFrameTimestampNs = _inumaFrameTimestampNs;
  currentFrameGeneration = _inumaCurrentFrameGeneration;
  if (_inumaFrameReadyMonotonicNs > 0 &&
      traceSnapshotMonotonicNs >= _inumaFrameReadyMonotonicNs) {
    currentFrameAgeNs =
        traceSnapshotMonotonicNs - _inumaFrameReadyMonotonicNs;
  }
  if (_inumaPendingTextureFrameCount > 0) {
    const InumaPendingTextureFrame primary =
        _inumaPendingTextureFrames[_inumaPendingTextureFrameHead];
    primaryFrameTimestampNs = primary.frame_timestamp_ns;
    primaryFromEmergencyGrace = primary.from_emergency_grace;
    if (primary.ready_monotonic_ns > 0 &&
        traceSnapshotMonotonicNs >= primary.ready_monotonic_ns) {
      primaryFrameAgeNs =
          traceSnapshotMonotonicNs - primary.ready_monotonic_ns;
    }
  }
  emergencyGraceOccupied =
      _inumaEmergencyGraceTextureFrame.pixel_buffer != nil;
  emergencyGraceBurstArmed = _inumaEmergencyGraceBurstArmed;
  if (emergencyGraceOccupied) {
    emergencyGraceFrameTimestampNs =
        _inumaEmergencyGraceTextureFrame.frame_timestamp_ns;
    if (_inumaEmergencyGraceTextureFrame
                .emergency_grace_admitted_monotonic_ns > 0 &&
        traceSnapshotMonotonicNs >=
            _inumaEmergencyGraceTextureFrame
                .emergency_grace_admitted_monotonic_ns) {
      emergencyGraceResidenceNs =
          traceSnapshotMonotonicNs -
          _inumaEmergencyGraceTextureFrame
              .emergency_grace_admitted_monotonic_ns;
    }
  }
  os_unfair_lock_unlock(&_lock);
  const uint64_t traceSnapshotLockHoldNs =
      InumaMonotonicNanoseconds() - traceSnapshotMonotonicNs;
  _inumaTraceSnapshotCount += 1;
  _inumaTraceSnapshotLockHoldMaxNs =
      MAX(_inumaTraceSnapshotLockHoldMaxNs, traceSnapshotLockHoldNs);
  NSString *mode = _inumaPixelMode == InumaMacOSPixelModeNativeNV12
                       ? @"native_nv12"
                       : @"stock_bgra";
  const uint64_t prerendererSmoothingDisabledConfigurationCount =
      InumaPrerendererSmoothingDisabledConfigurationCount();
  const uint64_t lowLatencyVideoPlayoutEnabledConfigurationCount =
      InumaLowLatencyVideoPlayoutEnabledConfigurationCount();
  NSDictionary *report = @{
    @"schema" : @"inuma.flutter_webrtc.macos_texture_trace.v1",
    @"status" : @"pass",
    @"pixel_mode" : mode,
    @"payload_policy" : @"scalar_timing_and_counts_only_no_pixel_payloads",
    @"sample_capacity" : @(kInumaTextureTraceCapacity),
    @"sample_capacity_exhaustions" :
        @(snapshot->sample_capacity_exhaustions),
    @"tail_diagnostics_version" : @59,
    @"decoder_boundary_trace" : InumaDecoderBoundaryTraceSnapshot(),
    @"receiver_scheduler_trace" :
        RTCInumaReceiverSchedulerTraceSnapshot(),
    @"prerenderer_smoothing_configuration_contract" :
        @"explicit_objc_to_native_peer_configuration",
    @"prerenderer_smoothing_disabled_configuration_count" :
        @(prerendererSmoothingDisabledConfigurationCount),
    @"prerenderer_smoothing_disabled_applied" :
        prerendererSmoothingDisabledConfigurationCount > 0 ? @YES : @NO,
    @"low_latency_video_playout_configuration_contract" :
        @"explicit_dart_to_objc_factory_field_trials",
    @"low_latency_video_playout_enabled_configuration_count" :
        @(lowLatencyVideoPlayoutEnabledConfigurationCount),
    @"low_latency_video_playout_enabled" :
        lowLatencyVideoPlayoutEnabledConfigurationCount > 0 ? @YES : @NO,
    @"low_latency_video_playout_forced_minimum_ms" :
        @(InumaLowLatencyVideoPlayoutForcedMinimumMs()),
    @"low_latency_video_playout_forced_maximum_ms" :
        @(InumaLowLatencyVideoPlayoutForcedMaximumMs()),
    @"low_latency_video_playout_minimum_pacing_ms" :
        @(InumaLowLatencyVideoPlayoutMinimumPacingMs()),
    @"low_latency_video_playout_maximum_decode_queue_size" :
        @(InumaLowLatencyVideoPlayoutMaximumDecodeQueueSize()),
    @"low_latency_video_playout_initial_nack_rtt_ms" :
        @(InumaLowLatencyVideoPlayoutInitialNackRttMs()),
    @"low_latency_video_playout_nack_periodic_interval_ms" :
        @(InumaLowLatencyVideoPlayoutNackPeriodicIntervalMs()),
    @"low_latency_video_playout_nack_timer_high_precision" :
        @(InumaLowLatencyVideoPlayoutNackTimerHighPrecision()),
    @"trace_clock_domain" :
        @"macos_clock_uptime_raw_shared_mach_absolute_time",
    @"texture_notification_contract" :
        @"frame_state_before_platform_thread_notification",
    @"frame_ownership_contract" :
        @"explicit_monotonic_render_generation_timestamp_zero_accepted",
    @"frame_identity_contract" :
        @"renderer_local_monotonic_generation_not_media_timestamp",
    @"trace_snapshot_monotonic_ns" : @(traceSnapshotMonotonicNs),
    @"trace_snapshot_count" : @(_inumaTraceSnapshotCount),
    @"trace_snapshot_lock_hold_ns" : @(traceSnapshotLockHoldNs),
    @"trace_snapshot_lock_hold_max_ns" :
        @(_inumaTraceSnapshotLockHoldMaxNs),
    @"trace_snapshot_wall_time_ns" :
        @((uint64_t)(NSDate.date.timeIntervalSince1970 * 1000000000.0)),
    @"render_frames" : @(snapshot->render_frames),
    @"accepted_frames" : @(snapshot->accepted_frames),
    @"coalesced_frames" : @(snapshot->coalesced_frames),
    @"frame_generation_assignments" :
        @(snapshot->frame_generation_assignments),
    @"zero_timestamp_render_frames" :
        @(snapshot->zero_timestamp_render_frames),
    @"zero_timestamp_accepted_frames" :
        @(snapshot->zero_timestamp_accepted_frames),
    @"current_frame_generation_at_snapshot" : @(currentFrameGeneration),
    @"main_run_loop_notification_frame_generation_at_snapshot" :
        @(mainRunLoopNotificationFrameGeneration),
    @"copy_calls" : @(snapshot->copy_calls),
    @"copy_hits" : @(snapshot->copy_hits),
    @"copy_misses" : @(snapshot->copy_misses),
    @"source_cv_pixel_buffer_frames" :
        @(snapshot->source_cv_pixel_buffer_frames),
    @"source_i420_frames" : @(snapshot->source_i420_frames),
    @"source_nv12_frames" : @(snapshot->source_nv12_frames),
    @"source_bgra_frames" : @(snapshot->source_bgra_frames),
    @"source_other_pixel_format_frames" :
        @(snapshot->source_other_pixel_format_frames),
    @"native_nv12_frames" : @(snapshot->native_nv12_frames),
    @"native_nv12_fallback_frames" : @(snapshot->native_nv12_fallback_frames),
    @"minimum_texture_hold_ns" : @(_inumaMinimumTextureHoldNs),
    @"raster_repeat_guard_enabled" : @(_inumaRasterRepeatGuardEnabled),
    @"raster_repeat_guard_contract" :
        @"repeat_recent_rescue_predecessor_once_then_platform_turn_retry",
    @"raster_repeat_boundary_enabled" :
        @((BOOL)(_inumaRasterRepeatBoundaryNs > 0)),
    @"raster_repeat_boundary_default" : @"disabled",
    @"raster_repeat_boundary_ns" : @(_inumaRasterRepeatBoundaryNs),
    @"raster_repeat_boundary_contract" :
        @"opt_in_repeat_only_predecessor_boundary_no_normal_hold_or_retry_delay_change",
    @"raster_repeat_boundary_evaluations" :
        @(snapshot->raster_repeat_boundary_evaluations),
    @"raster_repeat_boundary_applies" :
        @(snapshot->raster_repeat_boundary_applies),
    @"raster_repeat_boundary_extended_applies" :
        @(snapshot->raster_repeat_boundary_extended_applies),
    @"raster_repeat_boundary_bypasses" :
        @(snapshot->raster_repeat_boundary_bypasses),
    @"rescue_notification_phase" :
        InumaRescueNotificationPhaseName(_inumaRescueNotificationPhase),
    @"rescue_notification_contract" :
        @"queued_promotion_only_default_display_link_opt_in_platform_turn",
    @"raster_repeat_guard_eligible_copy_calls" :
        @(snapshot->raster_repeat_guard_eligible_copy_calls),
    @"raster_repeat_guard_repeats" :
        @(snapshot->raster_repeat_guard_repeats),
    @"raster_repeat_guard_missing_predecessor" :
        @(snapshot->raster_repeat_guard_missing_predecessor),
    @"raster_repeat_guard_retry_unavailable" :
        @(snapshot->raster_repeat_guard_retry_unavailable),
    @"raster_repeat_platform_retry_schedules" :
        @(snapshot->raster_repeat_platform_retry_schedules),
    @"raster_repeat_platform_retry_fires" :
        @(snapshot->raster_repeat_platform_retry_fires),
    @"raster_repeat_platform_retry_stale_fires" :
        @(snapshot->raster_repeat_platform_retry_stale_fires),
    @"emergency_grace_enabled" : @(_inumaEmergencyGraceEnabled),
    @"emergency_grace_default" : @"disabled",
    @"emergency_grace_contract" :
        @"one_native_frame_only_when_current_repeat_deferred_or_current_"
         @"copy_overdue_primary_full_primary_age_at_least_minimum_"
         @"hold_grace_empty_and_burst_armed_then_fifo_shift",
    @"emergency_grace_sustained_backlog_contract" :
        @"one_admission_per_overload_burst_rearm_only_after_normal_empty_"
         @"primary_queue_shape",
    @"emergency_grace_eligible_frames" :
        @(snapshot->emergency_grace_eligible_frames),
    @"emergency_grace_admits" : @(snapshot->emergency_grace_admits),
    @"emergency_grace_admit_repeat_deferred" :
        @(snapshot->emergency_grace_admit_repeat_deferred),
    @"emergency_grace_admit_overdue_copy" :
        @(snapshot->emergency_grace_admit_overdue_copy),
    @"emergency_grace_shifts" : @(snapshot->emergency_grace_shifts),
    @"emergency_grace_drains" : @(snapshot->emergency_grace_drains),
    @"emergency_grace_refuses" : @(snapshot->emergency_grace_refuses),
    @"emergency_grace_clears" : @(snapshot->emergency_grace_clears),
    @"emergency_grace_would_have_overflows" :
        @(snapshot->emergency_grace_would_have_overflows),
    @"emergency_grace_max_occupancy" :
        @(snapshot->emergency_grace_max_occupancy),
    @"emergency_grace_refuse_not_repeat_deferred" :
        @(snapshot->emergency_grace_refuse_not_repeat_deferred),
    @"emergency_grace_refuse_primary_below_minimum_age" :
        @(snapshot->emergency_grace_refuse_primary_below_minimum_age),
    @"emergency_grace_refuse_occupied" :
        @(snapshot->emergency_grace_refuse_occupied),
    @"emergency_grace_refuse_queue_shape" :
        @(snapshot->emergency_grace_refuse_queue_shape),
    @"emergency_grace_refuse_conversion_failure" :
        @(snapshot->emergency_grace_refuse_conversion_failure),
    @"emergency_grace_refuse_burst_not_rearmed" :
        @(snapshot->emergency_grace_refuse_burst_not_rearmed),
    @"emergency_grace_burst_rearms" :
        @(snapshot->emergency_grace_burst_rearms),
    @"emergency_grace_occupied_at_snapshot" : @(emergencyGraceOccupied),
    @"emergency_grace_burst_armed_at_snapshot" :
        @(emergencyGraceBurstArmed),
    @"current_frame_repeat_deferred_at_snapshot" :
        @(currentFrameRepeatDeferred),
    @"current_frame_rescue_promoted_at_snapshot" :
        @(currentFrameRescuePromoted),
    @"current_frame_age_ns_at_snapshot" : @(currentFrameAgeNs),
    @"current_repeat_retry_fired_at_snapshot" :
        @(currentRepeatRetryFired),
    @"current_frame_timestamp_ns_at_snapshot" :
        @(currentFrameTimestampNs),
    @"primary_frame_timestamp_ns_at_snapshot" :
        @(primaryFrameTimestampNs),
    @"primary_from_emergency_grace_at_snapshot" :
        @(primaryFromEmergencyGrace),
    @"primary_frame_age_ns_at_snapshot" : @(primaryFrameAgeNs),
    @"emergency_grace_frame_timestamp_ns_at_snapshot" :
        @(emergencyGraceFrameTimestampNs),
    @"emergency_grace_residence_ns_at_snapshot" :
        @(emergencyGraceResidenceNs),
    @"texture_hold_applied" : @(snapshot->texture_hold_applied),
    @"stale_texture_notifications" :
        @(snapshot->stale_texture_notifications),
    @"max_queued_texture_frames" : @(_inumaMaxQueuedTextureFrames),
    @"queued_frames" : @(snapshot->queued_frames),
    @"queue_promotions" : @(snapshot->queue_promotions),
    @"queue_overflows" : @(snapshot->queue_overflows),
    @"queue_cleared_frames" : @(snapshot->queue_cleared_frames),
    @"queue_max_depth" : @(snapshot->queue_max_depth),
    @"queue_pending_at_snapshot" : @(pendingTextureFrameCount),
    @"rescue_hold_bypasses" : @(snapshot->rescue_hold_bypasses),
    @"rescue_hold_preservations" :
        @(snapshot->rescue_hold_preservations),
    @"rescue_display_link_schedules" :
        @(snapshot->rescue_display_link_schedules),
    @"rescue_display_link_fires" :
        @(snapshot->rescue_display_link_fires),
    @"rescue_display_link_cancellations" :
        @(snapshot->rescue_display_link_cancellations),
    @"rescue_display_link_fallbacks" :
        @(snapshot->rescue_display_link_fallbacks),
    @"rescue_display_link_stale_fires" :
        @(snapshot->rescue_display_link_stale_fires),
    @"rescue_display_link_callbacks" :
        @(snapshot->rescue_display_link_callbacks),
    @"rescue_display_link_deferrals" :
        @(snapshot->rescue_display_link_deferrals),
    @"direct_frame_display_retry_enabled" :
        @(_inumaDirectFrameDisplayRetryEnabled),
    @"direct_frame_display_retry_default" : @"disabled",
    @"direct_frame_display_retry_contract" :
        @"one_reusable_paused_display_link_retry_only_while_same_direct_frame_"
         @"awaits_first_copy_after_19ms_age_and_predecessor_minimum_hold",
    @"direct_frame_display_retry_minimum_age_ns" :
        @(kInumaDirectFrameDisplayRetryMinimumAgeNs),
    @"direct_frame_display_retry_schedules" :
        @(snapshot->direct_frame_display_retry_schedules),
    @"direct_frame_display_retry_callbacks" :
        @(snapshot->direct_frame_display_retry_callbacks),
    @"direct_frame_display_retry_deferrals" :
        @(snapshot->direct_frame_display_retry_deferrals),
    @"direct_frame_display_retry_fires" :
        @(snapshot->direct_frame_display_retry_fires),
    @"direct_frame_display_retry_cancellations" :
        @(snapshot->direct_frame_display_retry_cancellations),
    @"direct_frame_display_retry_stale_fires" :
        @(snapshot->direct_frame_display_retry_stale_fires),
    @"direct_frame_display_retry_create_failures" :
        @(snapshot->direct_frame_display_retry_create_failures),
    @"direct_frame_display_retry_link_creations" :
        @(snapshot->direct_frame_display_retry_link_creations),
    @"direct_frame_display_retry_link_reuses" :
        @(snapshot->direct_frame_display_retry_link_reuses),
    @"direct_frame_display_retry_link_arms" :
        @(snapshot->direct_frame_display_retry_link_arms),
    @"direct_frame_display_retry_link_pauses" :
        @(snapshot->direct_frame_display_retry_link_pauses),
    @"direct_frame_display_retry_link_invalidations" :
        @(snapshot->direct_frame_display_retry_link_invalidations),
    @"direct_frame_display_retry_link_abandoned_creations" :
        @(snapshot->direct_frame_display_retry_link_abandoned_creations),
    @"direct_frame_display_retry_notifications" :
        @(snapshot->direct_frame_display_retry_notifications),
    @"direct_frame_display_retry_link_lifecycle" :
        @"renderer_owned_create_once_add_once_pause_between_bounded_arms_"
         @"invalidate_only_at_dispose",
    @"direct_frame_display_retry_active_at_snapshot" :
        @(directFrameDisplayRetryActive),
    @"main_run_loop_notification_enabled" :
        @(_inumaMainRunLoopNotificationEnabled),
    @"main_run_loop_notification_default" : @"disabled",
    @"main_run_loop_notification_contract" :
        @"one_persistent_main_common_modes_version0_source_one_exact_"
         @"ordinary_current_token_one_mark_no_replay",
    @"main_run_loop_notification_source_create_attempts" :
        @(snapshot->main_run_loop_notification_source_create_attempts),
    @"main_run_loop_notification_source_creations" :
        @(snapshot->main_run_loop_notification_source_creations),
    @"main_run_loop_notification_source_create_failures" :
        @(snapshot->main_run_loop_notification_source_create_failures),
    @"main_run_loop_notification_source_registrations" :
        @(snapshot->main_run_loop_notification_source_registrations),
    @"main_run_loop_notification_source_registration_failures" :
        @(snapshot->main_run_loop_notification_source_registration_failures),
    @"main_run_loop_notification_source_signals" :
        @(snapshot->main_run_loop_notification_source_signals),
    @"main_run_loop_notification_run_loop_wakes" :
        @(snapshot->main_run_loop_notification_run_loop_wakes),
    @"main_run_loop_notification_callbacks" :
        @(snapshot->main_run_loop_notification_callbacks),
    @"main_run_loop_notification_current_fires" :
        @(snapshot->main_run_loop_notification_current_fires),
    @"main_run_loop_notification_stale_closes" :
        @(snapshot->main_run_loop_notification_stale_closes),
    @"main_run_loop_notification_empty_callbacks" :
        @(snapshot->main_run_loop_notification_empty_callbacks),
    @"main_run_loop_notification_occupied_refusals" :
        @(snapshot->main_run_loop_notification_occupied_refusals),
    @"main_run_loop_notification_invalid_owner_refusals" :
        @(snapshot->main_run_loop_notification_invalid_owner_refusals),
    @"main_run_loop_notification_source_unavailable_fallbacks" :
        @(snapshot
              ->main_run_loop_notification_source_unavailable_fallbacks),
    @"main_run_loop_notification_successor_rearms" :
        @(snapshot->main_run_loop_notification_successor_rearms),
    @"main_run_loop_notification_lifecycle_closes" :
        @(snapshot->main_run_loop_notification_lifecycle_closes),
    @"main_run_loop_notification_source_removals" :
        @(snapshot->main_run_loop_notification_source_removals),
    @"main_run_loop_notification_source_invalidations" :
        @(snapshot->main_run_loop_notification_source_invalidations),
    @"main_run_loop_notification_off_main_callbacks" :
        @(snapshot->main_run_loop_notification_off_main_callbacks),
    @"main_run_loop_notification_source_registered_at_snapshot" :
        @(mainRunLoopNotificationSourceRegistered),
    @"main_run_loop_notification_token_occupied_at_snapshot" :
        @(mainRunLoopNotificationTokenOccupied),
    @"main_run_loop_notification_frame_timestamp_ns_at_snapshot" :
        @(mainRunLoopNotificationFrameTimestampNs),
    @"main_run_loop_notification_token_age_ns_at_snapshot" :
        @(mainRunLoopNotificationTokenAgeNs),
    @"texture_notification_platform_turn_schedules" :
        @(snapshot->texture_notification_platform_turn_schedules),
    @"texture_notification_platform_turn_fires" :
        @(snapshot->texture_notification_platform_turn_fires),
    @"texture_notification_platform_turn_last_schedule_offset_ns" :
        @(snapshot
              ->texture_notification_platform_turn_last_schedule_offset_ns),
    @"texture_notification_platform_turn_last_fire_offset_ns" :
        @(snapshot
              ->texture_notification_platform_turn_last_fire_offset_ns),
    @"render_qos_policy" :
        InumaRenderQoSPolicyName(_inumaRenderQoSPolicy),
    @"render_qos_execution_owner" :
        _inumaRenderQoSQueue != nil ? @"owned_serial_enforced_qos_sync"
                                    : @"calling_thread",
    @"render_qos_queue_configured" :
        _inumaRenderQoSQueue != nil ? @YES : @NO,
    @"render_qos_queue_class" :
        _inumaRenderQoSQueue != nil &&
                dispatch_queue_get_qos_class(_inumaRenderQoSQueue, NULL) ==
                    QOS_CLASS_USER_INTERACTIVE
            ? @"user_interactive"
            : @"not_user_interactive",
    @"render_qos_sync_handoffs" :
        @(snapshot->render_qos_sync_handoffs),
    @"render_qos_work_item_creation_failures" :
        @(snapshot->render_qos_work_item_creation_failures),
    @"render_qos_owned_queue_entries" :
        @(snapshot->render_qos_owned_queue_entries),
    @"render_qos_calling_thread_entries" :
        @(snapshot->render_qos_calling_thread_entries),
    @"render_qos_observations" :
        @(snapshot->render_qos_observations),
    @"render_qos_apply_attempts" :
        @(snapshot->render_qos_apply_attempts),
    @"render_qos_apply_successes" :
        @(snapshot->render_qos_apply_successes),
    @"render_qos_apply_failures" :
        @(snapshot->render_qos_apply_failures),
    @"render_qos_before_unspecified" :
        @(snapshot->render_qos_before_unspecified),
    @"render_qos_before_background" :
        @(snapshot->render_qos_before_background),
    @"render_qos_before_utility" :
        @(snapshot->render_qos_before_utility),
    @"render_qos_before_default" :
        @(snapshot->render_qos_before_default),
    @"render_qos_before_user_initiated" :
        @(snapshot->render_qos_before_user_initiated),
    @"render_qos_before_user_interactive" :
        @(snapshot->render_qos_before_user_interactive),
    @"render_qos_after_user_interactive" :
        @(snapshot->render_qos_after_user_interactive),
    @"render_qos_after_not_user_interactive" :
        @(snapshot->render_qos_after_not_user_interactive),
    @"rescue_display_link_active_at_snapshot" :
        @(rescueDisplayLinkActive),
    @"strict_hold_timer_created" :
        @(snapshot->strict_hold_timer_created),
    @"strict_hold_timer_fired" : @(snapshot->strict_hold_timer_fired),
    @"strict_hold_timer_cancelled" :
        @(snapshot->strict_hold_timer_cancelled),
    @"strict_hold_timer_create_failures" :
        @(snapshot->strict_hold_timer_create_failures),
    @"strict_hold_timer_coalesced_existing" :
        @(snapshot->strict_hold_timer_coalesced_existing),
    @"strict_hold_timer_stale_before_ownership" :
        @(snapshot->strict_hold_timer_stale_before_ownership),
    @"strict_hold_timer_active_at_snapshot" :
        @(textureHoldTimerActive),
    @"stock_bgra_pool_minimum_buffer_count" :
        @(kInumaStockBGRAPoolMinimumBufferCount),
    @"stock_bgra_pool_create_failures" :
        @(snapshot->stock_bgra_pool_create_failures),
    @"stock_bgra_pool_buffer_requests" :
        @(snapshot->stock_bgra_pool_buffer_requests),
    @"stock_bgra_pool_buffer_failures" :
        @(snapshot->stock_bgra_pool_buffer_failures),
    @"copied_buffer_holds" : @(snapshot->copied_buffer_holds),
    @"copied_buffer_second_next_copy_releases" :
        @(snapshot->copied_buffer_second_next_copy_releases),
    @"copied_buffer_lifecycle_releases" :
        @(snapshot->copied_buffer_lifecycle_releases),
    @"copied_buffer_hold_count_at_snapshot" :
        @(copiedBufferHoldCount),
    @"mutable_single_bgra_buffer_reuse_enabled" : @NO,
    @"conversion_ns" : InumaTraceSampleArray(snapshot->conversion_samples,
                                             snapshot->conversion_count),
    @"render_lock_wait_ns" : InumaTraceSampleArray(
        snapshot->render_lock_wait_samples, snapshot->render_lock_wait_count),
    @"copy_lock_wait_ns" : InumaTraceSampleArray(
        snapshot->copy_lock_wait_samples, snapshot->copy_lock_wait_count),
    @"copy_ready_age_ns" : InumaTraceSampleArray(
        snapshot->copy_ready_age_samples, snapshot->copy_ready_age_count),
    @"texture_notify_dispatch_ns" : InumaTraceSampleArray(
        snapshot->texture_notify_dispatch_samples,
        snapshot->texture_notify_dispatch_count),
    @"texture_notify_ns" : InumaTraceSampleArray(
        snapshot->texture_notify_samples, snapshot->texture_notify_count),
    @"texture_hold_delay_ns" : InumaTraceSampleArray(
        snapshot->texture_hold_delay_samples,
        snapshot->texture_hold_delay_count),
    @"texture_hold_frame_timestamp_ns" : InumaTraceSignedSampleArray(
        snapshot->texture_hold_frame_timestamp_ns_samples,
        snapshot->texture_hold_delay_count),
    @"texture_hold_frame_generation" : InumaTraceSampleArray(
        snapshot->texture_hold_frame_generation_samples,
        snapshot->texture_hold_delay_count),
    @"texture_notify_event_offset_ns" : InumaTraceSampleArray(
        snapshot->texture_notify_event_offset_samples,
        snapshot->texture_notify_event_count),
    @"texture_notify_frame_timestamp_ns" : InumaTraceSignedSampleArray(
        snapshot->texture_notify_frame_timestamp_ns_samples,
        snapshot->texture_notify_event_count),
    @"texture_notify_frame_generation" : InumaTraceSampleArray(
        snapshot->texture_notify_frame_generation_samples,
        snapshot->texture_notify_event_count),
    @"texture_notify_scheduled_delay_ns" : InumaTraceSampleArray(
        snapshot->texture_notify_scheduled_delay_samples,
        snapshot->texture_notify_event_count),
    @"texture_notify_deadline_lateness_ns" : InumaTraceSampleArray(
        snapshot->texture_notify_deadline_lateness_samples,
        snapshot->texture_notify_event_count),
    @"queue_wait_ns" : InumaTraceSampleArray(
        snapshot->queue_wait_samples, snapshot->queue_wait_count),
    @"queue_enqueue_event_offset_ns" : InumaTraceSampleArray(
        snapshot->queue_enqueue_event_offset_samples,
        snapshot->queue_enqueue_event_count),
    @"queue_enqueue_frame_timestamp_ns" : InumaTraceSignedSampleArray(
        snapshot->queue_enqueue_frame_timestamp_ns_samples,
        snapshot->queue_enqueue_event_count),
    @"queue_enqueue_frame_generation" : InumaTraceSampleArray(
        snapshot->queue_enqueue_frame_generation_samples,
        snapshot->queue_enqueue_event_count),
    @"queue_promote_event_offset_ns" : InumaTraceSampleArray(
        snapshot->queue_promote_event_offset_samples,
        snapshot->queue_promote_event_count),
    @"queue_promote_frame_timestamp_ns" : InumaTraceSignedSampleArray(
        snapshot->queue_promote_frame_timestamp_ns_samples,
        snapshot->queue_promote_event_count),
    @"queue_promote_frame_generation" : InumaTraceSampleArray(
        snapshot->queue_promote_frame_generation_samples,
        snapshot->queue_promote_event_count),
    @"rescue_hold_bypass_frame_timestamp_ns" : InumaTraceSignedSampleArray(
        snapshot->rescue_hold_bypass_frame_timestamp_ns_samples,
        snapshot->rescue_hold_bypass_count),
    @"rescue_hold_bypass_frame_generation" : InumaTraceSampleArray(
        snapshot->rescue_hold_bypass_frame_generation_samples,
        snapshot->rescue_hold_bypass_count),
    @"rescue_hold_preservation_frame_timestamp_ns" :
        InumaTraceSignedSampleArray(
            snapshot->rescue_hold_preservation_frame_timestamp_ns_samples,
            snapshot->rescue_hold_preservation_count),
    @"rescue_hold_preservation_frame_generation" :
        InumaTraceSampleArray(
            snapshot->rescue_hold_preservation_frame_generation_samples,
            snapshot->rescue_hold_preservation_count),
    @"rescue_display_link_schedule_offset_ns" : InumaTraceSampleArray(
        snapshot->rescue_display_link_schedule_offset_samples,
        snapshot->rescue_display_link_event_count),
    @"rescue_display_link_fire_offset_ns" : InumaTraceSampleArray(
        snapshot->rescue_display_link_fire_offset_samples,
        snapshot->rescue_display_link_event_count),
    @"rescue_display_link_presentation_ack_ns" : InumaTraceSampleArray(
        snapshot->rescue_display_link_presentation_ack_samples,
        snapshot->rescue_display_link_event_count),
    @"rescue_display_link_callback_count" : InumaTraceSampleArray(
        snapshot->rescue_display_link_callback_count_samples,
        snapshot->rescue_display_link_event_count),
    @"rescue_display_link_frame_timestamp_ns" : InumaTraceSignedSampleArray(
        snapshot->rescue_display_link_frame_timestamp_ns_samples,
        snapshot->rescue_display_link_event_count),
    @"rescue_display_link_frame_generation" : InumaTraceSampleArray(
        snapshot->rescue_display_link_frame_generation_samples,
        snapshot->rescue_display_link_event_count),
    @"direct_frame_display_retry_schedule_offset_ns" : InumaTraceSampleArray(
        snapshot->direct_frame_display_retry_schedule_offset_samples,
        snapshot->direct_frame_display_retry_event_count),
    @"direct_frame_display_retry_callback_offset_ns" : InumaTraceSampleArray(
        snapshot->direct_frame_display_retry_callback_offset_samples,
        snapshot->direct_frame_display_retry_event_count),
    @"direct_frame_display_retry_callback_count" : InumaTraceSampleArray(
        snapshot->direct_frame_display_retry_callback_count_samples,
        snapshot->direct_frame_display_retry_event_count),
    @"direct_frame_display_retry_notification_offset_ns" :
        InumaTraceSampleArray(
            snapshot
                ->direct_frame_display_retry_notification_offset_samples,
            snapshot->direct_frame_display_retry_event_count),
    @"direct_frame_display_retry_frame_timestamp_ns" :
        InumaTraceSignedSampleArray(
            snapshot->direct_frame_display_retry_frame_timestamp_ns_samples,
            snapshot->direct_frame_display_retry_event_count),
    @"direct_frame_display_retry_frame_generation" :
        InumaTraceSampleArray(
            snapshot->direct_frame_display_retry_frame_generation_samples,
            snapshot->direct_frame_display_retry_event_count),
    @"direct_frame_display_retry_outcome" : InumaTraceByteSampleArray(
        snapshot->direct_frame_display_retry_outcome_samples,
        snapshot->direct_frame_display_retry_event_count),
    @"direct_frame_display_retry_outcome_codes" : @{
      @"0" : @"pending_at_snapshot",
      @"1" : @"fired",
      @"2" : @"stale",
      @"3" : @"cancelled_after_first_copy",
    },
    @"main_run_loop_notification_arm_offset_ns" : InumaTraceSampleArray(
        snapshot->main_run_loop_notification_arm_offset_samples,
        snapshot->main_run_loop_notification_event_count),
    @"main_run_loop_notification_callback_offset_ns" : InumaTraceSampleArray(
        snapshot->main_run_loop_notification_callback_offset_samples,
        snapshot->main_run_loop_notification_event_count),
    @"main_run_loop_notification_callback_duration_ns" :
        InumaTraceSampleArray(
            snapshot->main_run_loop_notification_callback_duration_samples,
            snapshot->main_run_loop_notification_event_count),
    @"main_run_loop_notification_frame_timestamp_ns" :
        InumaTraceSignedSampleArray(
            snapshot
                ->main_run_loop_notification_frame_timestamp_ns_samples,
            snapshot->main_run_loop_notification_event_count),
    @"main_run_loop_notification_frame_generation" :
        InumaTraceSampleArray(
            snapshot
                ->main_run_loop_notification_frame_generation_samples,
            snapshot->main_run_loop_notification_event_count),
    @"main_run_loop_notification_outcome" : InumaTraceByteSampleArray(
        snapshot->main_run_loop_notification_outcome_samples,
        snapshot->main_run_loop_notification_event_count),
    @"main_run_loop_notification_outcome_codes" : @{
      @"0" : @"pending_at_snapshot",
      @"1" : @"current_fire",
      @"2" : @"stale_close",
      @"3" : @"lifecycle_close",
    },
    @"strict_hold_timer_deadline_offset_ns" : InumaTraceSampleArray(
        snapshot->strict_hold_timer_deadline_offset_samples,
        snapshot->strict_hold_timer_event_count),
    @"strict_hold_timer_fire_offset_ns" : InumaTraceSampleArray(
        snapshot->strict_hold_timer_fire_offset_samples,
        snapshot->strict_hold_timer_event_count),
    @"strict_hold_timer_frame_timestamp_ns" : InumaTraceSignedSampleArray(
        snapshot->strict_hold_timer_frame_timestamp_ns_samples,
        snapshot->strict_hold_timer_event_count),
    @"strict_hold_timer_frame_generation" : InumaTraceSampleArray(
        snapshot->strict_hold_timer_frame_generation_samples,
        snapshot->strict_hold_timer_event_count),
    @"trace_started_monotonic_ns" : @(_inumaTraceStartedMonotonicNs),
    @"render_event_offset_ns" : InumaTraceSampleArray(
        snapshot->render_event_offset_samples, snapshot->render_event_count),
    @"render_frame_timestamp_ns" : InumaTraceSignedSampleArray(
        snapshot->render_frame_timestamp_ns_samples,
        snapshot->render_event_count),
    @"render_frame_generation" : InumaTraceSampleArray(
        snapshot->render_frame_generation_samples,
        snapshot->render_event_count),
    @"render_outcome" : InumaTraceByteSampleArray(
        snapshot->render_outcome_samples, snapshot->render_event_count),
    @"render_outcome_codes" : @{
      @"0" : @"ignored",
      @"1" : @"accepted",
      @"2" : @"coalesced",
      @"3" : @"accepted_emergency_grace",
    },
    @"coalesced_pending_age_ns" : InumaTraceSampleArray(
        snapshot->coalesced_pending_age_samples,
        snapshot->coalesced_pending_age_count),
    @"copy_event_offset_ns" : InumaTraceSampleArray(
        snapshot->copy_event_offset_samples, snapshot->copy_event_count),
    @"copy_frame_timestamp_ns" : InumaTraceSignedSampleArray(
        snapshot->copy_frame_timestamp_ns_samples,
        snapshot->copy_event_count),
    @"copy_frame_generation" : InumaTraceSampleArray(
        snapshot->copy_frame_generation_samples,
        snapshot->copy_event_count),
    @"raster_repeat_event_offset_ns" : InumaTraceSampleArray(
        snapshot->raster_repeat_event_offset_samples,
        snapshot->raster_repeat_event_count),
    @"raster_repeat_predecessor_frame_timestamp_ns" :
        InumaTraceSignedSampleArray(
            snapshot->raster_repeat_predecessor_frame_timestamp_ns_samples,
            snapshot->raster_repeat_event_count),
    @"raster_repeat_predecessor_frame_generation" :
        InumaTraceSampleArray(
            snapshot->raster_repeat_predecessor_frame_generation_samples,
            snapshot->raster_repeat_event_count),
    @"raster_repeat_deferred_frame_timestamp_ns" :
        InumaTraceSignedSampleArray(
            snapshot->raster_repeat_deferred_frame_timestamp_ns_samples,
            snapshot->raster_repeat_event_count),
    @"raster_repeat_deferred_frame_generation" : InumaTraceSampleArray(
        snapshot->raster_repeat_deferred_frame_generation_samples,
        snapshot->raster_repeat_event_count),
    @"raster_repeat_predecessor_tenure_ns" : InumaTraceSampleArray(
        snapshot->raster_repeat_predecessor_tenure_samples,
        snapshot->raster_repeat_event_count),
    @"raster_repeat_boundary_outcome_codes" : @{
      @"0" : @"bypassed_at_or_above_boundary",
      @"1" : @"repeated_within_normal_hold",
      @"2" : @"repeated_by_extended_boundary",
    },
    @"raster_repeat_boundary_event_offset_ns" : InumaTraceSampleArray(
        snapshot->raster_repeat_boundary_event_offset_samples,
        snapshot->raster_repeat_boundary_event_count),
    @"raster_repeat_boundary_predecessor_frame_timestamp_ns" :
        InumaTraceSignedSampleArray(
            snapshot
                ->raster_repeat_boundary_predecessor_frame_timestamp_ns_samples,
            snapshot->raster_repeat_boundary_event_count),
    @"raster_repeat_boundary_predecessor_frame_generation" :
        InumaTraceSampleArray(
            snapshot
                ->raster_repeat_boundary_predecessor_frame_generation_samples,
            snapshot->raster_repeat_boundary_event_count),
    @"raster_repeat_boundary_successor_frame_timestamp_ns" :
        InumaTraceSignedSampleArray(
            snapshot
                ->raster_repeat_boundary_successor_frame_timestamp_ns_samples,
            snapshot->raster_repeat_boundary_event_count),
    @"raster_repeat_boundary_successor_frame_generation" :
        InumaTraceSampleArray(
            snapshot
                ->raster_repeat_boundary_successor_frame_generation_samples,
            snapshot->raster_repeat_boundary_event_count),
    @"raster_repeat_boundary_predecessor_tenure_ns" :
        InumaTraceSampleArray(
            snapshot->raster_repeat_boundary_predecessor_tenure_samples,
            snapshot->raster_repeat_boundary_event_count),
    @"raster_repeat_boundary_outcome" : InumaTraceByteSampleArray(
        snapshot->raster_repeat_boundary_outcome_samples,
        snapshot->raster_repeat_boundary_event_count),
    @"raster_repeat_platform_retry_schedule_offset_ns" :
        InumaTraceSampleArray(
            snapshot->raster_repeat_platform_retry_schedule_offset_samples,
            snapshot->raster_repeat_platform_retry_event_count),
    @"raster_repeat_platform_retry_fire_offset_ns" :
        InumaTraceSampleArray(
            snapshot->raster_repeat_platform_retry_fire_offset_samples,
            snapshot->raster_repeat_platform_retry_event_count),
    @"raster_repeat_platform_retry_frame_timestamp_ns" :
        InumaTraceSignedSampleArray(
            snapshot->raster_repeat_platform_retry_frame_timestamp_ns_samples,
            snapshot->raster_repeat_platform_retry_event_count),
    @"raster_repeat_platform_retry_frame_generation" :
        InumaTraceSampleArray(
            snapshot->raster_repeat_platform_retry_frame_generation_samples,
            snapshot->raster_repeat_platform_retry_event_count),
    @"copied_buffer_second_next_copy_hold_ns" : InumaTraceSampleArray(
        snapshot->copied_buffer_second_next_copy_hold_samples,
        snapshot->copied_buffer_second_next_copy_hold_count),
    @"emergency_grace_admit_event_offset_ns" : InumaTraceSampleArray(
        snapshot->emergency_grace_admit_event_offset_samples,
        snapshot->emergency_grace_admit_event_count),
    @"emergency_grace_admit_frame_timestamp_ns" :
        InumaTraceSignedSampleArray(
            snapshot->emergency_grace_admit_frame_timestamp_ns_samples,
            snapshot->emergency_grace_admit_event_count),
    @"emergency_grace_admit_frame_generation" : InumaTraceSampleArray(
        snapshot->emergency_grace_admit_frame_generation_samples,
        snapshot->emergency_grace_admit_event_count),
    @"emergency_grace_admit_current_frame_timestamp_ns" :
        InumaTraceSignedSampleArray(
            snapshot
                ->emergency_grace_admit_current_frame_timestamp_ns_samples,
            snapshot->emergency_grace_admit_event_count),
    @"emergency_grace_admit_current_frame_generation" :
        InumaTraceSampleArray(
            snapshot
                ->emergency_grace_admit_current_frame_generation_samples,
            snapshot->emergency_grace_admit_event_count),
    @"emergency_grace_admit_primary_frame_timestamp_ns" :
        InumaTraceSignedSampleArray(
            snapshot
                ->emergency_grace_admit_primary_frame_timestamp_ns_samples,
            snapshot->emergency_grace_admit_event_count),
    @"emergency_grace_admit_primary_frame_generation" :
        InumaTraceSampleArray(
            snapshot
                ->emergency_grace_admit_primary_frame_generation_samples,
            snapshot->emergency_grace_admit_event_count),
    @"emergency_grace_admit_primary_age_ns" : InumaTraceSampleArray(
        snapshot->emergency_grace_admit_primary_age_samples,
        snapshot->emergency_grace_admit_event_count),
    @"emergency_grace_admit_retry_fired" : InumaTraceByteSampleArray(
        snapshot->emergency_grace_admit_retry_fired_samples,
        snapshot->emergency_grace_admit_event_count),
    @"emergency_grace_admit_overdue_copy_flags" : InumaTraceByteSampleArray(
        snapshot->emergency_grace_admit_overdue_copy_samples,
        snapshot->emergency_grace_admit_event_count),
    @"emergency_grace_shift_event_offset_ns" : InumaTraceSampleArray(
        snapshot->emergency_grace_shift_event_offset_samples,
        snapshot->emergency_grace_shift_event_count),
    @"emergency_grace_shift_frame_timestamp_ns" :
        InumaTraceSignedSampleArray(
            snapshot->emergency_grace_shift_frame_timestamp_ns_samples,
            snapshot->emergency_grace_shift_event_count),
    @"emergency_grace_shift_frame_generation" : InumaTraceSampleArray(
        snapshot->emergency_grace_shift_frame_generation_samples,
        snapshot->emergency_grace_shift_event_count),
    @"emergency_grace_drain_event_offset_ns" : InumaTraceSampleArray(
        snapshot->emergency_grace_drain_event_offset_samples,
        snapshot->emergency_grace_drain_event_count),
    @"emergency_grace_drain_frame_timestamp_ns" :
        InumaTraceSignedSampleArray(
            snapshot->emergency_grace_drain_frame_timestamp_ns_samples,
            snapshot->emergency_grace_drain_event_count),
    @"emergency_grace_drain_frame_generation" : InumaTraceSampleArray(
        snapshot->emergency_grace_drain_frame_generation_samples,
        snapshot->emergency_grace_drain_event_count),
    @"emergency_grace_residence_ns" : InumaTraceSampleArray(
        snapshot->emergency_grace_residence_samples,
        snapshot->emergency_grace_drain_event_count),
    @"emergency_grace_refuse_event_offset_ns" : InumaTraceSampleArray(
        snapshot->emergency_grace_refuse_event_offset_samples,
        snapshot->emergency_grace_refuse_event_count),
    @"emergency_grace_refuse_frame_timestamp_ns" :
        InumaTraceSignedSampleArray(
            snapshot->emergency_grace_refuse_frame_timestamp_ns_samples,
            snapshot->emergency_grace_refuse_event_count),
    @"emergency_grace_refuse_frame_generation" : InumaTraceSampleArray(
        snapshot->emergency_grace_refuse_frame_generation_samples,
        snapshot->emergency_grace_refuse_event_count),
    @"emergency_grace_refuse_reason" : InumaTraceByteSampleArray(
        snapshot->emergency_grace_refuse_reason_samples,
        snapshot->emergency_grace_refuse_event_count),
    @"emergency_grace_refuse_current_age_ns" : InumaTraceSampleArray(
        snapshot->emergency_grace_refuse_current_age_samples,
        snapshot->emergency_grace_refuse_event_count),
    @"emergency_grace_refuse_primary_age_ns" : InumaTraceSampleArray(
        snapshot->emergency_grace_refuse_primary_age_samples,
        snapshot->emergency_grace_refuse_event_count),
    @"emergency_grace_refuse_current_rescue_promoted" :
        InumaTraceByteSampleArray(
            snapshot
                ->emergency_grace_refuse_current_rescue_promoted_samples,
            snapshot->emergency_grace_refuse_event_count),
    @"emergency_grace_refuse_current_awaits_copy" :
        InumaTraceByteSampleArray(
            snapshot->emergency_grace_refuse_current_awaits_copy_samples,
            snapshot->emergency_grace_refuse_event_count),
    @"emergency_grace_refuse_reason_codes" : @{
      @"0" : @"none",
      @"1" : @"queue_shape",
      @"2" : @"not_repeat_deferred",
      @"3" : @"primary_below_minimum_age",
      @"4" : @"occupied",
      @"5" : @"conversion_failure",
      @"6" : @"burst_not_rearmed",
    },
  };
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:report
                                                 options:0
                                                   error:&error];
  if (data == nil || error != nil) {
    free(snapshot);
    return;
  }
  [data writeToFile:_inumaTracePath options:NSDataWritingAtomic error:&error];
  free(snapshot);
}
#endif

/**
 * Sets the size of the video frame to render.
 *
 * @param size The size of the video frame to render.
 */
- (void)setSize:(CGSize)size {
  os_unfair_lock_lock(&_lock);
  if (size.width != _frameSize.width || size.height != _frameSize.height) {
#if TARGET_OS_OSX
    _inumaRendererStateGeneration += 1;
    [self inumaCloseMainRunLoopNotificationTokenLockedForLifecycle];
    [self inumaCancelTextureHoldTimerLocked];
    [self inumaCancelRescueDisplayLinkLocked];
    [self inumaCancelDirectFrameDisplayRetryLocked];
    [self inumaClearPendingTextureFramesLocked];
    [self inumaReleaseAllCopiedBufferHoldsLockedAt:
              InumaMonotonicNanoseconds()];
#endif
    if (_pixelBufferRef) {
      CVBufferRelease(_pixelBufferRef);
      _pixelBufferRef = nil;
    }
#if TARGET_OS_OSX
    [self inumaResetStockBGRAPixelBufferPoolForSize:size];
    _inumaFrameReadyMonotonicNs = 0;
    _inumaLastCopyMonotonicNs = 0;
    _inumaLastCopiedFrameTimestampNs = 0;
    _inumaLastCopiedFrameGeneration = 0;
    _inumaFrameTimestampNs = 0;
    _inumaCurrentFrameGeneration = 0;
    _inumaCurrentFrameWasRescuePromoted = false;
    _inumaCurrentFrameRepeatDeferred = false;
    _inumaCurrentRepeatRetryFired = false;
    _inumaCurrentNormalNotificationRequired = false;
#else
    NSDictionary *pixelAttributes =
        @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
    CVPixelBufferCreate(
        kCFAllocatorDefault, size.width, size.height, kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)(pixelAttributes), &_pixelBufferRef);
#endif
    _frameAvailable = false;
    _frameSize = size;
  }
  os_unfair_lock_unlock(&_lock);
}

#pragma mark - FlutterStreamHandler methods

- (FlutterError *_Nullable)onCancelWithArguments:(id _Nullable)arguments {
  _eventSink = nil;
  return nil;
}

- (FlutterError *_Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:
                                           (nonnull FlutterEventSink)sink {
  _eventSink = sink;
  return nil;
}
@end

@implementation FlutterWebRTCPlugin (FlutterVideoRendererManager)

- (FlutterRTCVideoRenderer *)
    createWithTextureRegistry:(id<FlutterTextureRegistry>)registry
                    messenger:(NSObject<FlutterBinaryMessenger> *)messenger {
  return [[FlutterRTCVideoRenderer alloc] initWithTextureRegistry:registry
                                                        messenger:messenger];
}

- (void)rendererSetSrcObject:(FlutterRTCVideoRenderer *)renderer
                      stream:(RTCVideoTrack *)videoTrack {
  renderer.videoTrack = videoTrack;
}
@end
