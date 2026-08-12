import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/src/native/media_stream_track_impl.dart';
import 'package:flutter_webrtc/src/native/rtc_video_platform_view_controller.dart';
import 'package:flutter_webrtc/src/native/utils.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('FlutterWebRTC.Method');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    WebRTC.initialized = false;
    channel.setMockMethodCallHandler((call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    channel.setMockMethodCallHandler(null);
  });

  test('binds and clears an exact remote video track', () async {
    final controller = RTCVideoPlatformViewController(41);
    final track = MediaStreamTrackNative(
      'remote-video-track',
      'remote-video-track',
      'video',
      true,
      'peer-connection-owner',
    );

    await controller.setVideoTrack(track);

    expect(controller.renderVideo, isTrue);
    expect(calls.map((call) => call.method), <String>[
      'initialize',
      'videoPlatformViewRendererSetVideoTrack',
    ]);
    expect(calls.last.arguments, <String, dynamic>{
      'viewId': 41,
      'trackId': 'remote-video-track',
      'peerConnectionId': 'peer-connection-owner',
    });

    await controller.setVideoTrack(null);

    expect(controller.renderVideo, isFalse);
    expect(calls.last.method, 'videoPlatformViewRendererSetVideoTrack');
    expect(calls.last.arguments, <String, dynamic>{
      'viewId': 41,
      'trackId': '',
      'peerConnectionId': '',
    });
  });

  test('rejects a non-native track before platform invocation', () async {
    final controller = RTCVideoPlatformViewController(42);
    final track = _NonNativeVideoTrack();

    await expectLater(
      controller.setVideoTrack(track),
      throwsA(isA<ArgumentError>()),
    );

    expect(calls, isEmpty);
  });

  test('rolls back local binding when native lookup fails', () async {
    channel.setMockMethodCallHandler((call) async {
      calls.add(call);
      if (call.method == 'videoPlatformViewRendererSetVideoTrack') {
        throw PlatformException(code: 'track-not-found');
      }
      return null;
    });
    final controller = RTCVideoPlatformViewController(43);
    final track = MediaStreamTrackNative(
      'missing-video-track',
      'missing-video-track',
      'video',
      true,
      'peer-connection-owner',
    );

    await expectLater(controller.setVideoTrack(track), throwsA(isA<String>()));

    expect(controller.renderVideo, isFalse);
    expect(calls.last.method, 'videoPlatformViewRendererSetVideoTrack');
  });
}

class _NonNativeVideoTrack extends MediaStreamTrack {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
