#import "FlutterWebRTCPlugin.h"

@interface RTCPeerConnection (Flutter) <FlutterStreamHandler>
@property(nonatomic, strong, nonnull) NSMutableDictionary<NSString*, RTCDataChannel*>* dataChannels;
@property(nonatomic, strong, nonnull)
    NSMutableDictionary<NSString*, RTCMediaStream*>* remoteStreams;
@property(nonatomic, strong, nonnull)
    NSMutableDictionary<NSString*, RTCMediaStreamTrack*>* remoteTracks;
@property(nonatomic, strong, nonnull) NSString* flutterId;
// Accessors serialize block acquisition and replacement across native callbacks.
@property(nonatomic, copy, nullable) FlutterEventSink eventSink;
@property(nonatomic, strong, nullable) FlutterEventChannel* eventChannel;
@end

@interface FlutterWebRTCPlugin (RTCPeerConnection)

// Platform-thread teardown shared by close, dispose and engine detach.
// Native WebRTC Close must execute without holding a plugin/peer/channel lock.
- (void)peerConnectionClose:(nonnull RTCPeerConnection*)peerConnection;

- (void)peerConnectionCreateOffer:(nonnull NSDictionary*)constraints
                   peerConnection:(nonnull RTCPeerConnection*)peerConnection
                           result:(nonnull FlutterResult)result;

- (void)peerConnectionCreateAnswer:(nonnull NSDictionary*)constraints
                    peerConnection:(nonnull RTCPeerConnection*)peerConnection
                            result:(nonnull FlutterResult)result;

- (void)peerConnectionSetLocalDescription:(nonnull RTCSessionDescription*)sdp
                           peerConnection:(nonnull RTCPeerConnection*)peerConnection
                                   result:(nonnull FlutterResult)result;

- (void)peerConnectionSetRemoteDescription:(nonnull RTCSessionDescription*)sdp
                            peerConnection:(nonnull RTCPeerConnection*)peerConnection
                                    result:(nonnull FlutterResult)result;

- (void)peerConnectionAddICECandidate:(nonnull RTCIceCandidate*)candidate
                       peerConnection:(nonnull RTCPeerConnection*)peerConnection
                               result:(nonnull FlutterResult)result;

- (void)peerConnectionGetStats:(nonnull RTCPeerConnection*)peerConnection
                        result:(nonnull FlutterResult)result;

- (void)peerConnectionGetStatsForTrackId:(nonnull NSString*)trackID
                          peerConnection:(nonnull RTCPeerConnection*)peerConnection
                                  result:(nonnull FlutterResult)result;

- (nonnull RTCMediaConstraints*)parseMediaConstraints:(nonnull NSDictionary*)constraints;

- (void)peerConnectionSetConfiguration:(nonnull RTCConfiguration*)configuration
                        peerConnection:(nonnull RTCPeerConnection*)peerConnection;

- (void)peerConnectionGetRtpReceiverCapabilities:(nonnull NSDictionary*)argsMap
                                          result:(nonnull FlutterResult)result;

- (void)peerConnectionGetRtpSenderCapabilities:(nonnull NSDictionary*)argsMap
                                        result:(nonnull FlutterResult)result;

- (void)transceiverSetCodecPreferences:(nonnull NSDictionary*)argsMap
                                result:(nonnull FlutterResult)result;

- (nullable NSString*)stringForSignalingState:(RTCSignalingState)state;

- (nullable NSString*)stringForICEGatheringState:(RTCIceGatheringState)state;

- (nullable NSString*)stringForICEConnectionState:(RTCIceConnectionState)state;

- (nullable NSString*)stringForPeerConnectionState:(RTCPeerConnectionState)state;

@end
