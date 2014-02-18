//
//  SQRLShipItConnection.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-12.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

@class RACSignal;
@class SQRLShipItRequest;

// The domain for errors originating within SQRLShipItConnection.
extern NSString * const SQRLShipItConnectionErrorDomain;

// The ShipIt service could not be started.
extern const NSInteger SQRLShipItConnectionErrorCouldNotStartService;

// Installing an update requires the coordination of multiple processes,
// `SQRLShipItConnection` is responsible for submitting the launchd jobs
// required to perform an installation request.
//
// The multiprocess approach to waiting for termination and installing is
// designed to keep uses of AppKit API (i.e. `NSRunningApplication`) out of the
// installer process - which may be running in the root bootstrap context - and
// put them in a process running in the user bootstrap context. These processes
// can then communicate using the file system as a message bus.
//
// Frustratingly although LaunchServices is daemon and root safe since 10.5, the
// LaunchServices API for querying the running applications isn't public
// (internally `NSRunningApplication` uses this LaunchServices private API,
// though of course this is subject to change and `NSRunningApplication` could
// also do other non-root safe things).
//
// When a user application running Squirrel wants to install an update, Squirrel
// submits two launchd jobs, one which will wait for application termination and
// write an empty file to the given location when the criteria are met, and the
// other which will wait for that file to appear and then perform the install as
// before. The "wait for termination" job is always submitted to the user
// domain, but the installer job is submitted to a domain based on whether the
// install location is writable by the current user.
//
// To perform the relaunch when the install is complete, it is safe to use the
// LaunchServices API from the installer process, the app will be launched in
// the user's GUI session.
//
// From <https://developer.apple.com/library/mac/technotes/tn2083/>
//
// > If the EUID of the calling process is zero, the application is launched in
// > the context of the currently active GUI login session. If there is no
// > currently active GUI login session (no one is logged in, or a logged in
// > user has fast user switched to the login window), the behavior is
// > unspecified (r. 5321293).
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
- (instancetype)initWithRootPrivileges:(BOOL)rootPrivileges;

// Attempts to launch ShipIt.
//
// request - The install parameters, target bundle, update bundle, whether to
//           launch when install is complete etc.
//
// Returns a signal which will complete, or error, on a background scheduler.
- (RACSignal *)sendRequest:(SQRLShipItRequest *)request;

@end
