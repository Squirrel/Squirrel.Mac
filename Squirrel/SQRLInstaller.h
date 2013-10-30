//
//  SQRLInstaller.h
//  Squirrel
//
//  Created by Alan Rogers on 30/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

// There was an error copying the target bundle to the backup location.
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

@class RACCommand;
@class SQRLDirectoryManager;

// Performs the installation of an update, using the `SQRLShipItState` on disk,
// as located by `SQRLDirectoryManager`.
//
// This class is meant to be used only after the app that will be updated has
// terminated.
@interface SQRLInstaller : NSObject

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

// Initializes an installer using the given directory manager to read and write the
// state of the installation.
- (id)initWithDirectoryManager:(SQRLDirectoryManager *)directoryManager;

@end
