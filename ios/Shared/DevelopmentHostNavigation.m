#import "DevelopmentHostNavigation.h"
#import <objc/message.h>
#import <objc/runtime.h>

// Runtime research references (no third-party dependency):
// https://github.com/getdictus/dictus-ios/blob/main/DictusKeyboard/HostAppResolver.swift
// https://github.com/JackAIStudio/AgenBoard/blob/main/AgenBoard/ContentView.swift
#if DEBUG
static id VDReadObject(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL VDEnabled(id object, SEL selector) { return YES; }
static BOOL VDArbiterInstalled = NO;
static void VDActivateArbiter(void) {
    if (VDArbiterInstalled) return;
    Class cls = NSClassFromString(@"_UIKeyboardArbiterClient");
    Method method = class_getClassMethod(cls, NSSelectorFromString(@"enabled"));
    if (!method || method_getNumberOfArguments(method) != 2) return;
    char type[8] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (type[0] != 'B' && type[0] != 'c') return;
    // Replace only this class's method, never an inherited superclass implementation.
    class_replaceMethod(object_getClass(cls), NSSelectorFromString(@"enabled"), (IMP)VDEnabled, method_getTypeEncoding(method));
    VDArbiterInstalled = YES;
}

__attribute__((constructor)) static void VDPrepareAtLoad(void) {
    @autoreleasepool {
        if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.voicedraft.ios.keyboard"]) VDActivateArbiter();
    }
}
#endif

@implementation VDHostNavigation
+ (void)prepareKeyboard {
#if DEBUG
    @try {
        VDActivateArbiter();
        id client = VDReadObject(NSClassFromString(@"_UIKeyboardArbiterClient"), @"automaticSharedArbiterClient");
        SEL start = NSSelectorFromString(@"startConnection");
        NSMethodSignature *signature = [client methodSignatureForSelector:start];
        if (client && !VDReadObject(client, @"connection") && signature.numberOfArguments == 2 &&
            signature.methodReturnType[0] == 'v') {
            ((void (*)(id, SEL))objc_msgSend)(client, start);
        }
    } @catch (NSException *exception) { /* Unsupported OS: manual return remains available. */ }
#endif
}

+ (NSString *)hostBundleIdentifierForController:(UIInputViewController *)controller {
#if DEBUG
    @try {
        id client = VDReadObject(NSClassFromString(@"_UIKeyboardArbiterClient"), @"automaticSharedArbiterClient");
        id state = VDReadObject(client, @"currentClientState");
        // KVC boxes integer getters. Exceptions are caught here, never across Swift.
        NSNumber *hostPID = [controller valueForKey:@"_hostProcessIdentifier"];
        NSNumber *statePID = [state valueForKey:@"processIdentifier"];
        NSString *bundle = VDReadObject(state, @"sourceBundleIdentifier");
        // No cache: a previous app's arbiter state must never become a return destination.
        if ([hostPID isKindOfClass:NSNumber.class] && [statePID isKindOfClass:NSNumber.class] &&
            hostPID.intValue > 0 && [hostPID isEqualToNumber:statePID] && [bundle isKindOfClass:NSString.class] &&
            bundle.length > 0 && ![bundle hasPrefix:@"com.voicedraft."]) return bundle;
    } @catch (NSException *exception) { }
#endif
    return nil;
}

+ (NSString *)hostDiagnosticForController:(UIInputViewController *)controller {
#if DEBUG
    @try {
        id client = VDReadObject(NSClassFromString(@"_UIKeyboardArbiterClient"), @"automaticSharedArbiterClient");
        id state = VDReadObject(client, @"currentClientState");
        return [NSString stringWithFormat:@"hostPID=%@ arbiterPID=%@ bundle=%@ enabled=%d",
                [controller valueForKey:@"_hostProcessIdentifier"], [state valueForKey:@"processIdentifier"],
                VDReadObject(state, @"sourceBundleIdentifier"), VDArbiterInstalled];
    } @catch (NSException *exception) { return @"unsupported-runtime"; }
#endif
    return @"disabled";
}

+ (NSString *)returnToHost:(NSString *)bundleIdentifier application:(UIApplication *)application {
#if DEBUG
    @try {
        // A validated host is preferred; it does not depend on the host exposing a URL scheme.
        if (bundleIdentifier.length > 0) {
            id workspace = VDReadObject(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
            SEL open = NSSelectorFromString(@"openApplicationWithBundleID:");
            NSMethodSignature *signature = [workspace methodSignatureForSelector:open];
            if (signature.numberOfArguments == 3 &&
                [signature getArgumentTypeAtIndex:2][0] == '@' &&
                (signature.methodReturnType[0] == 'B' || signature.methodReturnType[0] == 'c')) {
                BOOL accepted = ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(workspace, open, bundleIdentifier);
                if (accepted) return @"bundle.accepted";
            }
        }
        // The system's current back destination is a fallback for hosts the arbiter cannot resolve.
        // Caller restricts this to one fresh keyboard hand-off, never ordinary app launches.
        id action = VDReadObject(application, @"_systemNavigationAction");
        if (!action) {
            Ivar ivar = class_getInstanceVariable(UIApplication.class, "_systemNavigationAction");
            if (ivar && ivar_getTypeEncoding(ivar)[0] == '@') action = object_getIvar(application, ivar);
        }
        NSArray *destinations = VDReadObject(action, @"destinations");
        SEL canSend = NSSelectorFromString(@"canSendResponse");
        NSMethodSignature *canSendSignature = [action methodSignatureForSelector:canSend];
        if (canSendSignature.numberOfArguments == 2 &&
            (canSendSignature.methodReturnType[0] == 'B' || canSendSignature.methodReturnType[0] == 'c') &&
            !((BOOL (*)(id, SEL))objc_msgSend)(action, canSend)) return @"unavailable";
        if (![destinations isKindOfClass:NSArray.class] || destinations.count != 1 ||
            ![destinations.firstObject isKindOfClass:NSNumber.class]) return @"unavailable";
        SEL send = NSSelectorFromString(@"sendResponseForDestination:");
        NSMethodSignature *signature = [action methodSignatureForSelector:send];
        if (signature.numberOfArguments != 3) return @"unavailable";
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = action;
        invocation.selector = send;
        NSUInteger destination = [destinations.firstObject unsignedIntegerValue];
        if (strcmp([signature getArgumentTypeAtIndex:2], @encode(NSUInteger)) != 0) return @"unsupported-signature";
        [invocation setArgument:&destination atIndex:2];
        [invocation invoke];
        return @"system-back.sent";
    } @catch (NSException *exception) { return @"unsupported-runtime"; }
#endif
    return @"unavailable";
}
@end
