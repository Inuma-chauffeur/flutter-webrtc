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

/// Refreshes one fail-closed interface snapshot before a stats report is read.
/// System interface discovery is intentionally performed once per native
/// callback, rather than once for every historical local-candidate row.
BOOL InumaRefreshNetworkAdapterStatsAttestation(void);

/// Adds privacy-safe physical-interface attestation to one local-candidate row.
/// Candidate addresses and BSD interface names remain in-process only.
NSDictionary<NSString*, id>* InumaAttestLocalCandidateStatsValues(
    NSString* reportType, NSDictionary<NSString*, id>* values);

/// Pure snapshot seam used by the native contract tests.
NSDictionary<NSString*, id>*
InumaAttestLocalCandidateStatsValuesForTesting(
    NSString* reportType,
    NSDictionary<NSString*, id>* values,
    NSSet<NSString*>* interfaceAddresses,
    NSString* _Nullable physicalCategory);

NS_ASSUME_NONNULL_END
