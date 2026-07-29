# Inuma Patch Ledger

## macOS decoded-buffer instrumentation and native NV12 A/B

- Upstream baseline: `flutter-webrtc/flutter-webrtc` tag `v1.5.2`, commit
  `073aaca52af9f50fc354b8fb2341f157fc849eff`.
- Scope: the shared Darwin renderer is guarded with `TARGET_OS_OSX`; the iOS
  build keeps the upstream rendering path.
- Default behavior: `stock_bgra`. The upstream I420-to-BGRA conversion and
  Flutter texture handoff remain unchanged unless an explicit A/B mode is
  selected.
- Trace opt-in:
  `INUMA_FLUTTER_WEBRTC_TEXTURE_TRACE_PATH=/private/scalar/path.json`.
  The renderer retains only bounded scalar counts and nanosecond timing
  samples. It never retains pixel or tensor payloads.
- Tail diagnostics v3 retain the WebRTC frame timestamp beside each native
  render callback and successful Flutter raster-thread texture copy, plus the
  copy event's Mac monotonic offset. This distinguishes decoder/plugin
  acceptance from raster consumption without retaining media bytes.
- A/B opt-in:
  `INUMA_FLUTTER_WEBRTC_MACOS_PIXEL_MODE=native_nv12`.
  This path is used only when the decoded frame is an uncropped, unscaled,
  unrotated, IOSurface-backed native NV12 `RTCCVPixelBuffer`. Otherwise the
  renderer falls back to the upstream conversion path and counts the fallback.
- Ownership: native buffers are retained and released with Core Video
  ownership calls. Flutter receives them through the existing
  `FlutterTexture.copyPixelBuffer` contract.
- Evidence required before promotion: stock and native one-minute traces,
  complete source/accepted/copy counts, zero unexpected fallback, real
  start/middle/end compositor pixels, CRC cadence, Flutter frame timing,
  WebRTC loss/drop/freeze counters, color/geometry review, cleanup, and the
  Jetson runtime gate.
- Platform claim: this experiment provides no Android, iOS, Linux, Windows,
  physical-panel, or human-undetectable-stutter evidence.
