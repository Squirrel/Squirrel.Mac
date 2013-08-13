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
// error - If not NULL, set to any error that occurs.
//
// Returns the XPC connection established, or NULL if an error occurs. The
// connection will be automatically released once it has completed or received
// an error. Retain the connection if you'll still need it after that point.
- (xpc_connection_t)launch:(NSError **)error;

@end
