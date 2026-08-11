#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html
#
Pod::Spec.new do |s|
  s.name             = 'flutter_webrtc'
  s.version          = '1.4.0'
  s.summary          = 'Flutter WebRTC plugin for macOS.'
  s.description      = <<-DESC
A new flutter plugin project.
                       DESC
  s.homepage         = 'https://github.com/cloudwebrtc/flutter-webrtc'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'CloudWebRTC' => 'duanweiwei1982@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = ['Classes/**/*']
  # This inline policy is consumed only by the renderer implementation. Keep
  # its source-tree forwarding header out of the generated public umbrella;
  # the relative common/ path does not exist after framework installation.
  s.private_header_files = [
    'Classes/InumaDecoderBoundaryTrace.h',
    'Classes/InumaDirectFrameDisplayRetryPolicy.h',
    'Classes/InumaEmergencyGracePolicy.h',
    'Classes/InumaFrameOwnershipPolicy.h',
    'Classes/InumaMainRunLoopNotificationPolicy.h',
    'Classes/InumaNativePresentationSeams.h',
    'Classes/InumaLowLatencyVideoPlayoutConfiguration.h',
    'Classes/InumaPrerendererSmoothingConfiguration.h',
    'Classes/InumaReceiverSchedulerTraceConfiguration.h',
    'Classes/InumaRepeatBoundaryPolicy.h',
  ]

  s.dependency 'FlutterMacOS'
  s.weak_frameworks = 'ScreenCaptureKit'
  s.dependency 'WebRTC-SDK', '144.7559.09'
  s.osx.deployment_target = '10.15'
end
