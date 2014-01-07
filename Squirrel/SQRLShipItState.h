//
//  SQRLShipItState.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-08.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Mantle/Mantle.h>

// The domain for errors originating within `SQRLShipItState`.
extern NSString * const SQRLShipItStateErrorDomain;

// A required property was `nil` upon initialization.
//
// The `userInfo` dictionary for this error will contain
// `SQRLShipItStatePropertyErrorKey`.
extern const NSInteger SQRLShipItStateErrorMissingRequiredProperty;

// The saved state on disk could not be unarchived, possibly because it's
// invalid.
extern const NSInteger SQRLShipItStateErrorUnarchiving;

// The state object could not be archived.
extern const NSInteger SQRLShipItStateErrorArchiving;

// Associated with an NSString indicating the required property key that did not
// have a value upon initialization.
extern NSString * const SQRLShipItStatePropertyErrorKey;

// The current state of the installer, for persistence across relaunches and for
// tolerance of system failures.
//
// SQRLInstallerStateNothingToDo          - ShipIt has not started installing
//                                          yet.
// SQRLInstallerStateReadingCodeSignature - Reading the code signature
//                                          from the target bundle, so we
//                                          know the designated
//                                          requirement that any update
//                                          must satisfy.
// SQRLInstallerStateVerifyingUpdate      - Checking that the update bundle meets
//                                          the designated requirement of the
//                                          target bundle. This ensures that
//                                          the update is a suitable replacement.
// SQRLInstallerStateBackingUp            - Backing up the target bundle so it
//                                          can be restored in the event of
//                                          failure.
// SQRLInstallerStateClearingQuarantine   - Clearing the quarantine flag on the
//                                          update bundle so it can used without
//                                          issue.
// SQRLInstallerStateInstalling           - Replacing the target bundle with the
//                                          update bundle.
// SQRLInstallerStateVerifyingInPlace     - Verifying that the target bundle is
//                                          still valid after updating.
//
// Note that these values must remain backwards compatible, so ShipIt doesn't
// start up in a weird mode on a newer version.
typedef enum : NSInteger {
	// These are purposely out-of-order, for compatibility with in-progress
	// installs on older ShipIt versions.
	//
	// The canonical order is that of the documentation above.
	SQRLInstallerStateNothingToDo = 0,
	SQRLInstallerStateClearingQuarantine,
	SQRLInstallerStateBackingUp,
	SQRLInstallerStateInstalling,
	SQRLInstallerStateVerifyingInPlace,
	SQRLInstallerStateReadingCodeSignature,
	SQRLInstallerStateVerifyingUpdate,
} SQRLInstallerState;

@class RACSignal;

// Encapsulates all the state needed by the ShipIt process.
@interface SQRLShipItState : MTLModel

// Reads a `SQRLShipItState` from disk, at the location specified by the given
// URL signal.
//
// URLSignal - Determines the file location to read from, the signal should send
//             an `NSURL` object then complete, or error. This must not be nil.
//
// Returns a signal which will synchronously send a `SQRLShipItState` then
// complete, or error.
+ (RACSignal *)readUsingURL:(RACSignal *)URL;

// Reads a `SQRLShipItState` from user defaults, using the given key.
//
// key - Determins the user defaults key to read from.
//
// Returns a signal which sends an `SQRLShipItState` object then complete, or
// error if no state is present in the defaults.
+ (RACSignal *)readFromDefaults:(NSString *)defaultsKey;

// Initializes the receiver with the arguments that will not change during
// installation.
- (id)initWithTargetBundleURL:(NSURL *)targetBundleURL updateBundleURL:(NSURL *)updateBundleURL bundleIdentifier:(NSString *)bundleIdentifier;

// Writes the receiver to disk, at the location specified by the given URL
// signal.
//
// URL - Determines the file location to write to. The signal should send an
//       `NSURL` object then complete, or error. This must not be nil.
//
// Returns a signal which will synchronously complete or error.
- (RACSignal *)writeUsingURL:(RACSignal *)URL;

// Writes the receiver to user defaults under the given key.
//
// key - Determines the user defaults key to write to.
//
// Returns a signal which completes, or errors.
- (RACSignal *)writeToDefaults:(NSString *)defaultsKey;

// The URL to the app bundle that should be replaced with an update.
@property (nonatomic, copy, readonly) NSURL *targetBundleURL;

// The URL to the downloaded update's app bundle.
@property (nonatomic, copy, readonly) NSURL *updateBundleURL;

// The bundle identifier of the application being updated.
//
// If not nil, the installer will wait for applications matching this identifier
// (and `targetBundleURL`) to terminate before continuing.
@property (nonatomic, copy, readonly) NSString *bundleIdentifier;

// The current state of the installer.
@property (atomic, assign) SQRLInstallerState installerState;

// The number of installation attempts that have occurred for the current
// `state`.
@property (atomic, assign) NSUInteger installationStateAttempt;

// Whether to relaunch the application after an update is successfully
// installed.
@property (atomic, assign) BOOL relaunchAfterInstallation;

@end
