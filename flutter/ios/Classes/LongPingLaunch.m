#import <UIKit/UIKit.h>

// Static library builds expose the generated header by file name; frameworks by module path.
#if __has_include(<long_ping/long_ping-Swift.h>)
#import <long_ping/long_ping-Swift.h>
#else
#import "long_ping-Swift.h"
#endif

/// Tracking must resume at every launch, including background relaunches by region or significant-change
/// monitoring, where iOS starts the app without a window and Flutter may never register plugins or run Dart.
/// +load runs while the binary loads, so the observer is in place before didFinishLaunching.
@interface LongPingLaunch : NSObject
@end

@implementation LongPingLaunch

+ (void)load
{
  [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                    object:nil
                                                     queue:[NSOperationQueue mainQueue]
                                                usingBlock:^(NSNotification *_Nonnull notification) {
                                                  @try {
                                                    [LongPingEngine.shared resumeIfEnabled];
                                                  } @catch (NSException *exception) {
                                                    NSLog(@"[LongPing] resume failed: %@", exception);
                                                  }
                                                }];
}

@end
