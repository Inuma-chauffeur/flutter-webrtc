#import "InumaNetworkAdapterClassification.h"

#import <SystemConfiguration/SystemConfiguration.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <os/lock.h>
#import <string.h>

static os_unfair_lock gInumaRequiredInterfaceLock = OS_UNFAIR_LOCK_INIT;
static NSString* gInumaRequiredInterfaceName = nil;
static NSSet<NSString*>* gInumaRequiredInterfaceAddresses = nil;
static NSString* gInumaRequiredInterfaceCategory = nil;
static BOOL gInumaRequiredInterfaceSnapshotValid = NO;

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
  gInumaRequiredInterfaceAddresses = nil;
  gInumaRequiredInterfaceCategory = nil;
  gInumaRequiredInterfaceSnapshotValid = NO;
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

static NSString* InumaNumericAddressForSockaddr(
    const struct sockaddr* socketAddress) {
  if (socketAddress == NULL) {
    return nil;
  }
  char buffer[INET6_ADDRSTRLEN] = {0};
  if (socketAddress->sa_family == AF_INET) {
    const struct sockaddr_in* current =
        (const struct sockaddr_in*)socketAddress;
    if (inet_ntop(AF_INET, &current->sin_addr, buffer, sizeof(buffer)) == NULL) {
      return nil;
    }
  } else if (socketAddress->sa_family == AF_INET6) {
    const struct sockaddr_in6* current =
        (const struct sockaddr_in6*)socketAddress;
    if (inet_ntop(AF_INET6, &current->sin6_addr, buffer, sizeof(buffer)) ==
        NULL) {
      return nil;
    }
  } else {
    return nil;
  }
  return [NSString stringWithUTF8String:buffer];
}

static NSSet<NSString*>* InumaAddressesForInterface(NSString* interfaceName) {
  struct ifaddrs* interfaces = NULL;
  if (getifaddrs(&interfaces) != 0 || interfaces == NULL) {
    return nil;
  }
  NSMutableSet<NSString*>* addresses = [NSMutableSet set];
  const char* requiredName = interfaceName.UTF8String;
  for (const struct ifaddrs* current = interfaces; current != NULL;
       current = current->ifa_next) {
    if (current->ifa_name == NULL || current->ifa_addr == NULL ||
        requiredName == NULL || strcmp(current->ifa_name, requiredName) != 0 ||
        (current->ifa_flags & IFF_UP) == 0) {
      continue;
    }
    NSString* address = InumaNumericAddressForSockaddr(current->ifa_addr);
    if (address.length > 0) {
      [addresses addObject:InumaNormalizedNumericAddress(address)];
    }
  }
  freeifaddrs(interfaces);
  return [addresses copy];
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

BOOL InumaRefreshNetworkAdapterStatsAttestation(void) {
  NSString* requiredInterface = InumaRequiredNetworkInterface();
  if (requiredInterface.length == 0) {
    return YES;
  }
  NSSet<NSString*>* addresses =
      InumaAddressesForInterface(requiredInterface);
  NSString* physicalCategory =
      InumaAdapterCategoryForInterface(requiredInterface);
  BOOL valid = addresses.count > 0 && physicalCategory.length > 0;

  os_unfair_lock_lock(&gInumaRequiredInterfaceLock);
  if ([gInumaRequiredInterfaceName isEqualToString:requiredInterface]) {
    gInumaRequiredInterfaceAddresses = valid ? [addresses copy] : nil;
    gInumaRequiredInterfaceCategory = valid ? [physicalCategory copy] : nil;
    gInumaRequiredInterfaceSnapshotValid = valid;
  } else {
    valid = NO;
  }
  os_unfair_lock_unlock(&gInumaRequiredInterfaceLock);
  return valid;
}

NSDictionary<NSString*, id>* InumaAttestLocalCandidateStatsValues(
    NSString* reportType, NSDictionary<NSString*, id>* values) {
  if (![reportType.lowercaseString isEqualToString:@"local-candidate"]) {
    return values;
  }
  os_unfair_lock_lock(&gInumaRequiredInterfaceLock);
  NSString* requiredInterface = [gInumaRequiredInterfaceName copy];
  NSSet<NSString*>* addresses =
      gInumaRequiredInterfaceSnapshotValid
          ? [gInumaRequiredInterfaceAddresses copy]
          : nil;
  NSString* physicalCategory =
      gInumaRequiredInterfaceSnapshotValid
          ? [gInumaRequiredInterfaceCategory copy]
          : nil;
  os_unfair_lock_unlock(&gInumaRequiredInterfaceLock);
  if (requiredInterface.length == 0) {
    return values;
  }
  return InumaAttestLocalCandidateStatsValuesForTesting(
      reportType, values, addresses ?: [NSSet set], physicalCategory);
}

NSDictionary<NSString*, id>*
InumaAttestLocalCandidateStatsValuesForTesting(
    NSString* reportType,
    NSDictionary<NSString*, id>* values,
    NSSet<NSString*>* interfaceAddresses,
    NSString* physicalCategory) {
  if (![reportType.lowercaseString isEqualToString:@"local-candidate"]) {
    return values;
  }
  id addressValue = values[@"address"] ?: values[@"ip"];
  NSString* normalizedAddress =
      [addressValue isKindOfClass:[NSString class]]
          ? InumaNormalizedNumericAddress((NSString*)addressValue)
          : nil;
  if (normalizedAddress.length == 0 ||
      ![interfaceAddresses containsObject:normalizedAddress]) {
    return values;
  }
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
