#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, InumaRequiredNetworkInterfaceParseResult) {
  InumaRequiredNetworkInterfaceParseResultAbsent = 0,
  InumaRequiredNetworkInterfaceParseResultValid = 1,
  InumaRequiredNetworkInterfaceParseResultInvalid = 2,
};

/// Parses the optional exact BSD interface used to attest selected ICE stats.
InumaRequiredNetworkInterfaceParseResult
InumaParseRequiredNetworkInterface(NSDictionary* _Nullable options,
                                   NSString* _Nullable* _Nullable interfaceName);

/// Stores the process-scoped exact interface selected before factory creation.
void InumaSetRequiredNetworkInterface(NSString* _Nullable interfaceName);

/// Adds privacy-safe physical-interface attestation to one local-candidate row.
/// Candidate addresses and BSD interface names remain in-process only.
NSDictionary<NSString*, id>* InumaAttestLocalCandidateStatsValues(
    NSString* reportType, NSDictionary<NSString*, id>* values);

NS_ASSUME_NONNULL_END
