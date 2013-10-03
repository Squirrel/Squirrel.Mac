//
//  SQRLShipItLauncher.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-12.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

@class RACSignal;

// The domain for errors originating within SQRLShipItLauncher.
extern NSString * const SQRLShipItLauncherErrorDomain;

// The ShipIt service could not be started.
extern const NSInteger SQRLShipItLauncherErrorCouldNotStartService;

// Responsible for launching the ShipIt service to actually install an update.
@interface SQRLShipItLauncher : NSObject

// Returns the label for the ShipIt launchd job.
+ (NSString *)shipItJobLabel;

// Creates an Application Support directory suitable for use by ShipIt (if
// necessary) and returns its URL.
+ (NSURL *)shipItApplicationSupportURL;

// Attempts to launch the ShipIt service.
//
// privileged - Determines which launchd domain to launch the job in.
//              If true, shipit is launched in the root domain, otherwise it is
//              launched in the current user’s domain.
//
// Returns a signal which will send a `SQRLXPCConnection` then complete, or
// error, on a background scheduler. The underlying `xpc_connection_t` will be
// automatically retained while the connection remains open. If you need to
// retain it for longer, hang on to the `SQRLXPCConnection`.
+ (RACSignal *)launchPrivileged:(BOOL)privileged;

@end
