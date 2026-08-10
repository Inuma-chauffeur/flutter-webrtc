#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, InumaReceiverSchedulerTraceParseResult) {
  InumaReceiverSchedulerTraceParseResultAbsent = 0,
  InumaReceiverSchedulerTraceParseResultValid = 1,
  InumaReceiverSchedulerTraceParseResultInvalid = 2,
};

FOUNDATION_EXPORT InumaReceiverSchedulerTraceParseResult
InumaParseReceiverSchedulerTraceConfiguration(
    NSDictionary* _Nullable options,
    BOOL* _Nullable enabled);

NS_ASSUME_NONNULL_END
