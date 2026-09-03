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
    InumaSetRequiredNetworkInterface(@"en11");
    Require(InumaAttestLocalCandidateStatsValues(@"remote-candidate",
                                                  untouched) == untouched,
            @"remote candidates must never be attested as local");
    NSDictionary* wrongAddress = InumaAttestLocalCandidateStatsValues(
        @"local-candidate",
        @{@"address" : @"192.0.2.1", @"networkAdapterType" : @"unknown"});
    Require(wrongAddress[@"inumaNetworkInterfaceBindingVerified"] == nil,
            @"an address outside the exact interface must remain unverified");
  }
  return 0;
}
