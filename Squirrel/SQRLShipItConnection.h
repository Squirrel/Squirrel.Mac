//
//  SQRLShipItConnection.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-12.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

@class RACSignal;
@class SQRLShipItState;

// The domain for errors originating within SQRLShipItConnection.
extern NSString * const SQRLShipItConnectionErrorDomain;

// The ShipIt service could not be started.
extern const NSInteger SQRLShipItConnectionErrorCouldNotStartService;

// Responsible for launching the ShipIt service to actually install an update.
@interface SQRLShipItConnection : NSObject

// Returns the label for the ShipIt launchd job.
+ (NSString *)shipItJobLabel;

// Designated initialiser.
//
// privileged - Determines which launchd domain to launch the job in.
//              If YES, ShipIt is launched in the root domain, otherwise it is
//              launched in the current user’s domain.
//
// Returns an initialised connection which can be used to start an install.
- (instancetype)initForPrivileged:(BOOL)privileged;

// Attempts to launch ShipIt.
//
// request - The install parameters, target bundle, update bundle, whether to
//           launch when install is complete etc.
//
// Returns a signal which will complete, or error, on a background scheduler.
- (RACSignal *)sendRequest:(SQRLShipItState *)request;

@end
