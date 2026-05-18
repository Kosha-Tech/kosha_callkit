#import "ConnectycubeFlutterCallKitPlugin.h"
#if __has_include(<kosha_callkit/kosha_callkit-Swift.h>)
#import <kosha_callkit/kosha_callkit-Swift.h>
#else
// Support project import fallback if the generated compatibility header
// is not copied when this plugin is created as a library.
// https://forums.swift.org/t/swift-static-libraries-dont-copy-generated-objective-c-header/19816
#import "kosha_callkit-Swift.h"
#endif

@implementation ConnectycubeFlutterCallKitPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [SwiftConnectycubeFlutterCallKitPlugin registerWithRegistrar:registrar];
}
@end
