//
//  SQRLStateManager.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-04.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

// The current state of ShipIt, for persistence across relaunches and for
// tolerance of system failures.
//
// SQRLShipItStateNothingToDo           - ShipIt has not started installing yet.
// SQRLShipItStateClearingQuarantine    - Clearing the quarantine flag on the
//                                        update bundle so it can used without
//                                        issue.
// SQRLShipItStateBackingUp             - Backing up the target bundle so it can
//                                        be restored in the event of failure.
// SQRLShipItStateInstalling            - Replacing the target bundle with the
//                                        update bundle.
// SQRLShipItStateVerifyingInPlace      - Verifying that the target bundle is
//                                        still valid after updating.
// SQRLShipItStateRelaunching           - Relaunching the updated application.
//                                        This state will be entered even if
//                                        there's no relaunching to do.
//
// Note that these values must remain backwards compatible, so ShipIt doesn't
// start up in a weird mode on a newer version.
typedef enum : NSInteger {
	SQRLShipItStateNothingToDo = 0,
	SQRLShipItStateClearingQuarantine,
	SQRLShipItStateBackingUp,
	SQRLShipItStateInstalling,
	SQRLShipItStateVerifyingInPlace,
	SQRLShipItStateRelaunching
} SQRLShipItState;

// Persists state about an enqueued or in-progress update installation, so
// ShipIt can be safely terminated and relaunched, then continue updating.
@interface SQRLStateManager : NSObject

// Finds the URL to the Application Support folder that would be used with the
// given identifier.
//
// identifier - A string that uniquely identifies the Application Support folder.
//              This must not be nil.
//
// Returns the URL for the Application Support folder, creating it if
// necessary, or nil if an error occurs.
+ (NSURL *)applicationSupportURLWithIdentifier:(NSString *)identifier;

// Initializes a state manager with the given unique identifier.
//
// identifier - A string to uniquely this application or job. This must not be
//              nil.
- (id)initWithIdentifier:(NSString *)identifier;

// Synchronizes all of the receiver's values to disk.
//
// Returns whether synchronization was successful.
- (BOOL)synchronize;

// The URL to an Application Support folder owned by ShipIt.
@property (nonatomic, copy, readonly) NSURL *applicationSupportURL;

// The current state of ShipIt.
//
// Setting this property will reset `installationStateAttempt` and synchronize
// all settings to disk.
@property (atomic, assign) SQRLShipItState state;

// The URL to the app bundle that should be replaced with an update.
@property (atomic, copy) NSURL *targetBundleURL;

// The URL to the downloaded update's app bundle.
@property (atomic, copy) NSURL *updateBundleURL;

// A serialized `SecRequirementRef` describing what the update bundle must
// satisfy in order to be valid.
@property (atomic, copy) NSData *requirementData;

// The number of installation attempts that have occurred for the current
// `state`.
//
// This will be set to 1 whenever `state` is set. Setting this property will
// synchronize all settings to disk.
@property (atomic, assign) NSUInteger installationStateAttempt;

// The bundle identifier of the application being updated.
//
// If not nil, the installer will wait for applications matching this identifier
// (and `targetBundleURL`) to terminate before continuing.
@property (atomic, copy) NSString *waitForBundleIdentifier;

// Whether to relaunch the application after an update is successfully
// installed.
@property (atomic, assign) BOOL relaunchAfterInstallation;

// The URL where the target bundle has been backed up to before installing the
// update.
//
// This property is set automatically during the course of installation. It
// should not be preset.
@property (atomic, copy) NSURL *backupBundleURL;

@end
