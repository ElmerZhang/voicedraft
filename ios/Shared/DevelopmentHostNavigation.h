#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
/// Development-build compatibility experiment; release implementations are inert.
@interface VDHostNavigation : NSObject
+ (void)prepareKeyboard;
+ (nullable NSString *)hostBundleIdentifierForController:(UIInputViewController *)controller NS_SWIFT_NAME(hostBundleIdentifier(for:));
+ (NSString *)hostDiagnosticForController:(UIInputViewController *)controller NS_SWIFT_NAME(hostDiagnostic(for:));
+ (NSString *)returnToHost:(nullable NSString *)bundleIdentifier application:(UIApplication *)application NS_SWIFT_NAME(returnToHost(_:application:));
@end
NS_ASSUME_NONNULL_END
