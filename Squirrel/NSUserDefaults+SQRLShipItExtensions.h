//
//  NSUserDefaults+SQRLShipItExtensions.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-02.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

// The current state of ShipIt, for persistence across relaunches and for
// tolerance of system failures.
//
// SQRLShipItStateNothingToDo           - ShipIt has not been instructed to do
//                                        anything yet.
// SQRLShipItStateWaitingForTermination - Waiting for the parent application to
//                                        exit.
// SQRLShipItStateClearingQuarantine    - Clearing the quarantine flag on the
//                                        update bundle so it can used without
//                                        issue.
// SQRLShipItStateBackingUp             - Backing up the target bundle so it can
//                                        be restored in the event of failure.
// SQRLShipItStateInstalling            - Replacing the target bundle with the
//                                        update bundle.
// SQRLShipItStateVerifyingInPlace      - Verifying that the target bundle is
//                                        still valid after updating.
//
// Note that these values must remain backwards compatible, so ShipIt doesn't
// start up in a weird mode on a newer version.
typedef enum : NSInteger {
	SQRLShipItStateNothingToDo = 0,
	SQRLShipItStateWaitingForTermination,
	SQRLShipItStateClearingQuarantine,
	SQRLShipItStateBackingUp,
	SQRLShipItStateInstalling,
	SQRLShipItStateVerifyingInPlace
} SQRLShipItState;

// User defaults settings to hold state about an enqueued or in-progress update
// installation, so ShipIt can be safely terminated and relaunched, then continue
// updating.
@interface NSUserDefaults (SQRLShipItExtensions)

// The URL to the app bundle that should be replaced with an update.
@property (atomic, copy) NSURL *sqrl_targetBundleURL;

// The URL to the downloaded update's app bundle.
@property (atomic, copy) NSURL *sqrl_updateBundleURL;

// The URL where the target bundle has been backed up to before installing the
// update.
@property (atomic, copy) NSURL *sqrl_backupBundleURL;

// The URL to an Application Support folder owned by ShipIt.
@property (atomic, copy) NSURL *sqrl_applicationSupportURL;

// A serialized `SecRequirementRef` describing what the update bundle must
// satisfy in order to be valid.
@property (atomic, copy) NSData *sqrl_requirementData;

// The current state of ShipIt.
//
// Setting this property will synchronize the user defaults to disk.
@property (atomic, assign) SQRLShipItState sqrl_state;

// The number of failures that have occurred during the current installation
// attempt.
//
// TODO
//@property (atomic, assign) NSUInteger sqrl_installationFailures;

// The bundle identifier of the application being updated.
@property (atomic, copy) NSString *sqrl_bundleIdentifier;

@end
