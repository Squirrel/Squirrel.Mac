//
//  SQRLShipItState.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-08.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Mantle/Mantle.h>

// Associated with an NSString indicating the required property key that did not
// have a value upon initialization.
extern NSString * const SQRLShipItStatePropertyErrorKey;

// The current state of the installer, for persistence across relaunches and for
// tolerance of system failures.
//
// SQRLInstallerStateNothingToDo        - ShipIt has not started installing yet.
// SQRLInstallerStateClearingQuarantine - Clearing the quarantine flag on the
//                                        update bundle so it can used without
//                                        issue.
// SQRLInstallerStateBackingUp          - Backing up the target bundle so it can
//                                        be restored in the event of failure.
// SQRLInstallerStateInstalling         - Replacing the target bundle with the
//                                        update bundle.
// SQRLInstallerStateVerifyingInPlace   - Verifying that the target bundle is
//                                        still valid after updating.
// SQRLInstallerStateRelaunching        - Relaunching the updated application.
//                                        This state will be entered even if
//                                        there's no relaunching to do.
//
// Note that these values must remain backwards compatible, so ShipIt doesn't
// start up in a weird mode on a newer version.
typedef enum : NSInteger {
	SQRLInstallerStateNothingToDo = 0,
	SQRLInstallerStateClearingQuarantine,
	SQRLInstallerStateBackingUp,
	SQRLInstallerStateInstalling,
	SQRLInstallerStateVerifyingInPlace,
	SQRLInstallerStateRelaunching
} SQRLInstallerState;

@class RACSignal;
@class SQRLCodeSignature;

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

// Initializes the receiver with the arguments that will not change during
// installation.
- (id)initWithTargetBundleURL:(NSURL *)targetBundleURL updateBundleURL:(NSURL *)updateBundleURL bundleIdentifier:(NSString *)bundleIdentifier codeSignature:(SQRLCodeSignature *)codeSignature;

// Writes the receiver to disk, at the location specified by the given URL
// signal.
//
// URL - Determines the file location to write to. The signal should send an
//       `NSURL` object then complete, or error. This must not be nil.
//
// Returns a signal which will synchronously complete or error.
- (RACSignal *)writeUsingURL:(RACSignal *)URL;

// The URL to the app bundle that should be replaced with an update.
@property (nonatomic, copy, readonly) NSURL *targetBundleURL;

// The URL to the downloaded update's app bundle.
@property (nonatomic, copy, readonly) NSURL *updateBundleURL;

// A code signature that the update bundle must match in order to be valid.
@property (nonatomic, copy, readonly) SQRLCodeSignature *codeSignature;

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

// The URL where the target bundle has been backed up to before installing the
// update.
//
// This property is set automatically during the course of installation. It
// should not be preset.
@property (atomic, copy) NSURL *backupBundleURL;

@end
