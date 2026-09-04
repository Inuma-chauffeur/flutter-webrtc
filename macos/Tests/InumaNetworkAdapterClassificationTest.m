#import <Foundation/Foundation.h>

#include <stdlib.h>

#import "../Classes/InumaNetworkAdapterClassification.h"

static void Require(BOOL condition, NSString* message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    abort();
  }
}

int main(void) {
  @autoreleasepool {
    NSString* interfaceName = @"unchanged";
    Require(InumaParseRequiredNetworkInterface(@{}, &interfaceName) ==
                InumaRequiredNetworkInterfaceParseResultAbsent,
            @"an absent exact interface must preserve the default path");
    Require(interfaceName == nil, @"an absent interface must return nil");
    Require(InumaParseRequiredNetworkInterface(
                @{@"networkRequiredInterfaceName" : @"en11"},
                &interfaceName) ==
                InumaRequiredNetworkInterfaceParseResultValid,
            @"a bounded BSD interface name must parse");
    Require([interfaceName isEqualToString:@"en11"],
            @"the exact interface name must be preserved in-process");
    for (id value in @[@"", @" en11", @"en/11", @"abcdefghijklmnop", @1,
                        @[], @{}, [NSNull null]]) {
      Require(InumaParseRequiredNetworkInterface(
                  @{@"networkRequiredInterfaceName" : value},
                  &interfaceName) ==
                  InumaRequiredNetworkInterfaceParseResultInvalid,
              @"malformed interface names must fail closed");
    }
    Require(InumaParseRequiredNetworkInterface(
                @{@"networkRequiredInterfaceName" : @"en11"}, NULL) ==
                InumaRequiredNetworkInterfaceParseResultInvalid,
            @"a missing parser output must fail closed");

    NSDictionary* untouched = @{@"address" : @"10.88.0.2",
                                @"networkAdapterType" : @"unknown"};
    InumaSetRequiredNetworkInterface(nil);
    Require(InumaAttestLocalCandidateStatsValues(@"local-candidate",
                                                  untouched) == untouched,
            @"the default path must not mutate candidate stats");
    InumaSetRequiredNetworkInterface(@"inuma_missing0");
    Require(!InumaRefreshNetworkAdapterStatsAttestation(),
            @"an unavailable exact interface must fail closed");
    InumaSetRequiredNetworkInterface(@"en11");
    Require(InumaAttestLocalCandidateStatsValues(@"remote-candidate",
                                                  untouched) == untouched,
            @"remote candidates must never be attested as local");
    NSDictionary* wrongAddress = InumaAttestLocalCandidateStatsValues(
        @"local-candidate",
        @{@"address" : @"192.0.2.1", @"networkAdapterType" : @"unknown"});
    Require(wrongAddress[@"inumaNetworkInterfaceBindingVerified"] == nil,
            @"an address outside the exact interface must remain unverified");

    NSSet<NSString*>* addresses = [NSSet setWithArray:@[
      @"10.88.0.2",
      @"fe80::1234",
    ]];
    NSDictionary* attested =
        InumaAttestLocalCandidateStatsValuesForTesting(
            @"local-candidate", untouched, addresses, @"ethernet");
    Require([attested[@"inumaNetworkInterfaceBindingVerified"] boolValue],
            @"an exact cached address must be attested");
    Require([attested[@"networkAdapterType"] isEqualToString:@"ethernet"],
            @"the physical category must replace unknown");
    Require([attested[@"networkType"] isEqualToString:@"ethernet"],
            @"an unknown network type must use the physical category");
    NSDictionary* scopedV6 =
        InumaAttestLocalCandidateStatsValuesForTesting(
            @"local-candidate",
            @{
              @"address" : @"[fe80::1234%en11]",
              @"networkAdapterType" : @"unknown",
            },
            addresses,
            @"ethernet");
    Require([scopedV6[@"inumaNetworkInterfaceBindingVerified"] boolValue],
            @"a scoped numeric address must normalize before matching");
    NSDictionary* conflicting =
        InumaAttestLocalCandidateStatsValuesForTesting(
            @"local-candidate",
            @{
              @"address" : @"10.88.0.2",
              @"networkAdapterType" : @"wifi",
            },
            addresses,
            @"ethernet");
    Require(conflicting[@"inumaNetworkInterfaceBindingVerified"] == nil,
            @"a reported physical-category conflict must fail closed");
    NSDictionary* missingSnapshot =
        InumaAttestLocalCandidateStatsValuesForTesting(
            @"local-candidate", untouched, [NSSet set], nil);
    Require(missingSnapshot[@"inumaNetworkInterfaceBindingVerified"] == nil,
            @"a missing cached snapshot must fail closed");
  }
  return 0;
}
