// Verifies the public Darwin dispatch/QoS primitives used by the macOS
// renderer's bounded, app-owned execution handoff.

#import <Foundation/Foundation.h>

#include <dispatch/dispatch.h>
#include <pthread/qos.h>
#include <stdio.h>

static const void *kQueueSpecificKey = &kQueueSpecificKey;

int main(void) {
  @autoreleasepool {
    dispatch_queue_attr_t attributes =
        dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    dispatch_queue_t queue = dispatch_queue_create(
        "dev.inuma.flutter-webrtc.render-qos-test", attributes);
    dispatch_queue_set_specific(queue, kQueueSpecificKey,
                                (void *)kQueueSpecificKey, NULL);

    __block bool ownerMatched = false;
    __block qos_class_t executingQoS = QOS_CLASS_UNSPECIFIED;
    dispatch_block_t work = dispatch_block_create_with_qos_class(
        DISPATCH_BLOCK_ENFORCE_QOS_CLASS, QOS_CLASS_USER_INTERACTIVE, 0, ^{
      ownerMatched = dispatch_get_specific(kQueueSpecificKey) ==
                     kQueueSpecificKey;
      executingQoS = qos_class_self();
    });
    dispatch_sync(queue, work);

    int relativePriority = 0;
    const dispatch_qos_class_t configuredQoS =
        dispatch_queue_get_qos_class(queue, &relativePriority);
    if (!ownerMatched || executingQoS != QOS_CLASS_USER_INTERACTIVE ||
        configuredQoS != QOS_CLASS_USER_INTERACTIVE ||
        relativePriority != 0) {
      fprintf(stderr, "owner=%d executing=%u configured=%u relative=%d\n",
              ownerMatched, (unsigned int)executingQoS,
              (unsigned int)configuredQoS, relativePriority);
      return 1;
    }

    NSDictionary* trace = @{
      @"render_qos_queue_configured" : queue != nil ? @YES : @NO,
    };
    NSError* encodeError = nil;
    NSData* encoded = [NSJSONSerialization dataWithJSONObject:trace
                                                      options:0
                                                        error:&encodeError];
    NSError* decodeError = nil;
    NSDictionary* decoded =
        encoded == nil
            ? nil
            : [NSJSONSerialization JSONObjectWithData:encoded
                                               options:0
                                                 error:&decodeError];
    id configured = decoded[@"render_qos_queue_configured"];
    if (encodeError != nil || decodeError != nil ||
        ![configured isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)configured) != CFBooleanGetTypeID() ||
        ![configured boolValue]) {
      fprintf(stderr, "queue-configured trace did not retain JSON Boolean true\n");
      return 1;
    }
  }
  return 0;
}
