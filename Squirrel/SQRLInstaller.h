//
//  SQRLInstaller.h
//  Squirrel
//
//  Created by Alan Rogers on 30/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "SQRLShipItState.h"

// The domain for errors originating within SQRLInstaller.
extern NSString * const SQRLInstallerErrorDomain;

// There was an error copying the target or update bundle to a backup location.
extern const NSInteger SQRLInstallerErrorBackupFailed;

// There was an error replacing the target bundle with the update.
extern const NSInteger SQRLInstallerErrorReplacingTarget;

// The target URL could not be opened as a bundle.
extern const NSInteger SQRLInstallerErrorCouldNotOpenTarget;

// The target bundle has an invalid version set.
extern const NSInteger SQRLInstallerErrorInvalidBundleVersion;

// The `SQRLShipItState` read from disk does not contain the information we need
// to perform an installation.
extern const NSInteger SQRLInstallerErrorMissingInstallationData;

// The `SQRLShipItState` read from disk is invalid, so installation cannot
// safely resume.
extern const NSInteger SQRLInstallerErrorInvalidState;

// There was an error moving a bundle across volumes.
extern const NSInteger SQRLInstallerErrorMovingAcrossVolumes;

// There was an error changing the file permissions of the update.
extern const NSInteger SQRLInstallerErrorChangingPermissions;

@class RACCommand;
@class SQRLDirectoryManager;

// Performs the installation of an update, using the `SQRLShipItState` from
// user defaults, as located by defaultsKey.
//
// This class is meant to be used only after the app that will be updated has
// terminated.
@interface SQRLInstaller : NSObject

// The first state that `SQRLInstaller` wants to perform for fresh state
// objects.
//
// A `SQRLShipItState` that hasn't been read from disk should be given this
// state.
+ (SQRLInstallerState)initialInstallerState;

// When executed with a `SQRLShipItState`, attempts to install the update or
// resume an in-progress installation.
//
// Each execution will complete or error on an unspecified scheduler when
// installation has completed or failed.
@property (nonatomic, strong, readonly) RACCommand *installUpdateCommand;

// When executed with a `SQRLShipItState`, aborts an installation, and attempts
// to restore the old version of the application if necessary.
//
// This must not be executed while `installUpdateCommand` is executing.
//
// Each execution will complete or error on an unspecified scheduler once
// aborting/recovery has finished.
@property (nonatomic, strong, readonly) RACCommand *abortInstallationCommand;

// Initializes an installer using the given application identifier, which is
// used to scope resumable state stored to user defaults.
//
// applicationIdentifier - The defaults domain in which to store resumable
//                         state. Must not be nil.
// stateDefaultsKey      - The defaults key in which to read/write the
//                         `SQRLShipItState`. Must not be nil.
- (id)initWithApplicationIdentifier:(NSString *)applicationIdentifier stateDefaultsKey:(NSString *)stateDefaultsKey;

@end
