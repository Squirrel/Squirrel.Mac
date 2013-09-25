//
//  SQRLShipItLauncher.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-12.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

// The domain for errors originating within SQRLShipItLauncher.
extern NSString * const SQRLShipItLauncherErrorDomain;

// The ShipIt service could not be started.
extern const NSInteger SQRLShipItLauncherErrorCouldNotStartService;

// Responsible for launching the ShipIt service to actually install an update.
@interface SQRLShipItLauncher : NSObject

// Attempts to launch the ShipIt service.
//
// privileged - Determines which launchd domain to launch the job in.
//              If true, shipit is launched in the root domain, otherwise it is
//              launched in the current user’s domain.
// error      - If not NULL, set to any error that occurs.
//
// Returns the XPC connection established, or NULL if an error occurs. The
// connection will be automatically released once it has completed or received
// an error. Retain the connection if you'll still need it after that point.
+ (xpc_connection_t)launchPrivileged:(BOOL)privileged error:(NSError **)error;

@end
