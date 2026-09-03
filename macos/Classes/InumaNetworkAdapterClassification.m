#import "InumaNetworkAdapterClassification.h"

#import <SystemConfiguration/SystemConfiguration.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <os/lock.h>
#import <string.h>

static os_unfair_lock gInumaRequiredInterfaceLock = OS_UNFAIR_LOCK_INIT;
static NSString* gInumaRequiredInterfaceName = nil;

static BOOL InumaInterfaceNameIsValid(NSString* value) {
  if (value.length == 0 || value.length >= IFNAMSIZ ||
      ![value canBeConvertedToEncoding:NSASCIIStringEncoding]) {
    return NO;
  }
  static NSCharacterSet* disallowed = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSMutableCharacterSet* allowed =
        [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@"._-"];
    disallowed = [allowed invertedSet];
  });
  return [value rangeOfCharacterFromSet:disallowed].location == NSNotFound;
}

InumaRequiredNetworkInterfaceParseResult
InumaParseRequiredNetworkInterface(NSDictionary* options,
                                   NSString** interfaceName) {
  if (interfaceName == NULL) {
    return InumaRequiredNetworkInterfaceParseResultInvalid;
  }
  *interfaceName = nil;
  id value = options[@"networkRequiredInterfaceName"];
  if (value == nil) {
    return InumaRequiredNetworkInterfaceParseResultAbsent;
  }
  if (![value isKindOfClass:[NSString class]] ||
      !InumaInterfaceNameIsValid((NSString*)value)) {
    return InumaRequiredNetworkInterfaceParseResultInvalid;
  }
  *interfaceName = [(NSString*)value copy];
  return InumaRequiredNetworkInterfaceParseResultValid;
}

void InumaSetRequiredNetworkInterface(NSString* interfaceName) {
  os_unfair_lock_lock(&gInumaRequiredInterfaceLock);
  gInumaRequiredInterfaceName = [interfaceName copy];
  os_unfair_lock_unlock(&gInumaRequiredInterfaceLock);
}

static NSString* InumaRequiredNetworkInterface(void) {
  os_unfair_lock_lock(&gInumaRequiredInterfaceLock);
  NSString* value = [gInumaRequiredInterfaceName copy];
  os_unfair_lock_unlock(&gInumaRequiredInterfaceLock);
  return value;
}

static NSString* InumaNormalizedNumericAddress(NSString* value) {
  NSString* normalized = [value stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([normalized hasPrefix:@"["] && [normalized hasSuffix:@"]"] &&
      normalized.length > 2) {
    normalized = [normalized substringWithRange:
        NSMakeRange(1, normalized.length - 2)];
  }
  NSRange scope = [normalized rangeOfString:@"%"];
  if (scope.location != NSNotFound) {
    normalized = [normalized substringToIndex:scope.location];
  }
  return normalized;
}

static BOOL InumaSockaddrMatchesAddress(const struct sockaddr* socketAddress,
                                        NSString* candidateAddress) {
  NSString* normalized = InumaNormalizedNumericAddress(candidateAddress);
  const char* encoded = normalized.UTF8String;
  if (encoded == NULL || socketAddress == NULL) {
    return NO;
  }
  if (socketAddress->sa_family == AF_INET) {
    struct in_addr candidate = {0};
    if (inet_pton(AF_INET, encoded, &candidate) != 1) {
      return NO;
    }
    const struct sockaddr_in* current =
        (const struct sockaddr_in*)socketAddress;
    return memcmp(&candidate, &current->sin_addr, sizeof(candidate)) == 0;
  }
  if (socketAddress->sa_family == AF_INET6) {
    struct in6_addr candidate = {0};
    if (inet_pton(AF_INET6, encoded, &candidate) != 1) {
      return NO;
    }
    const struct sockaddr_in6* current =
        (const struct sockaddr_in6*)socketAddress;
    return memcmp(&candidate, &current->sin6_addr, sizeof(candidate)) == 0;
  }
  return NO;
}

static BOOL InumaCandidateAddressBelongsToInterface(NSString* address,
                                                    NSString* interfaceName) {
  struct ifaddrs* interfaces = NULL;
  if (getifaddrs(&interfaces) != 0 || interfaces == NULL) {
    return NO;
  }
  BOOL matched = NO;
  const char* requiredName = interfaceName.UTF8String;
  for (const struct ifaddrs* current = interfaces; current != NULL;
       current = current->ifa_next) {
    if (current->ifa_name == NULL || current->ifa_addr == NULL ||
        requiredName == NULL || strcmp(current->ifa_name, requiredName) != 0 ||
        (current->ifa_flags & IFF_UP) == 0) {
      continue;
    }
    if (InumaSockaddrMatchesAddress(current->ifa_addr, address)) {
      matched = YES;
      break;
    }
  }
  freeifaddrs(interfaces);
  return matched;
}

static NSString* InumaAdapterCategoryForInterface(NSString* interfaceName) {
  NSArray* interfaces = CFBridgingRelease(SCNetworkInterfaceCopyAll());
  for (id item in interfaces) {
    SCNetworkInterfaceRef interface = (__bridge SCNetworkInterfaceRef)item;
    NSString* name = (__bridge NSString*)SCNetworkInterfaceGetBSDName(interface);
    if (![name isEqualToString:interfaceName]) {
      continue;
    }
    CFStringRef type = SCNetworkInterfaceGetInterfaceType(interface);
    if (type != NULL && CFEqual(type, kSCNetworkInterfaceTypeEthernet)) {
      return @"ethernet";
    }
    if (type != NULL && CFEqual(type, kSCNetworkInterfaceTypeIEEE80211)) {
      return @"wifi";
    }
    return nil;
  }
  return nil;
}

NSDictionary<NSString*, id>* InumaAttestLocalCandidateStatsValues(
    NSString* reportType, NSDictionary<NSString*, id>* values) {
  if (![reportType.lowercaseString isEqualToString:@"local-candidate"]) {
    return values;
  }
  NSString* requiredInterface = InumaRequiredNetworkInterface();
  if (requiredInterface.length == 0) {
    return values;
  }
  id addressValue = values[@"address"] ?: values[@"ip"];
  if (![addressValue isKindOfClass:[NSString class]] ||
      !InumaCandidateAddressBelongsToInterface(
          (NSString*)addressValue, requiredInterface)) {
    return values;
  }
  NSString* physicalCategory =
      InumaAdapterCategoryForInterface(requiredInterface);
  NSString* reportedCategory =
      [values[@"networkAdapterType"] isKindOfClass:[NSString class]]
          ? [values[@"networkAdapterType"] lowercaseString]
          : @"";
  if (physicalCategory.length == 0 ||
      (reportedCategory.length > 0 &&
       ![reportedCategory isEqualToString:@"unknown"] &&
       ![reportedCategory isEqualToString:physicalCategory])) {
    return values;
  }
  NSMutableDictionary<NSString*, id>* attested = [values mutableCopy];
  attested[@"networkAdapterType"] = physicalCategory;
  NSString* networkType =
      [values[@"networkType"] isKindOfClass:[NSString class]]
          ? [values[@"networkType"] lowercaseString]
          : @"";
  if (networkType.length == 0 || [networkType isEqualToString:@"unknown"]) {
    attested[@"networkType"] = physicalCategory;
  }
  attested[@"inumaNetworkInterfaceBindingVerified"] = @YES;
  attested[@"inumaNetworkAdapterClassificationSource"] =
      @"system_configuration_candidate_address_binding";
  return attested;
}
