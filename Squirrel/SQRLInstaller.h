//
//  SQRLInstaller.h
//  Squirrel
//
//  Created by Alan Rogers on 30/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

// The domain for errors originating within SQRLInstaller.
extern NSString * const SQRLInstallerErrorDomain;

// There was an error copying the target bundle to the backup location.
extern const NSInteger SQRLInstallerErrorBackupFailed;

// There was an error replacing the target bundle with the update.
extern const NSInteger SQRLInstallerErrorReplacingTarget;

// The target URL could not be opened as a bundle.
extern const NSInteger SQRLInstallerErrorCouldNotOpenTarget;

// The target bundle has an invalid version set.
extern const NSInteger SQRLInstallerErrorInvalidBundleVersion;

// Performs the installation of an update.
//
// This class is meant to be used only after the app that will be updated has
// terminated.
@interface SQRLInstaller : NSObject

// Initializes the installer with the bundles to use.
//
// targetBundleURL - The URL to the app bundle that should be replaced with the
//                   update. This must not be nil.
// updateBundleURL - The URL to the downloaded update's app bundle. This must
//                   not be nil.
// backupURL       - A URL to a folder in which the target app will be backed up
//                   before updating. This must not be nil.
// requirementData - A serialized SecRequirementRef describing what the update
//                   bundle must satisfy in order to be valid. This must not be
//                   nil.
//
// Returns an initialized installer, or nil if an error occurred.
- (id)initWithTargetBundleURL:(NSURL *)targetBundleURL updateBundleURL:(NSURL *)updateBundleURL requirementData:(NSData *)requirementData;

// Attempts to install the update specified at the time of initialization.
- (BOOL)installUpdateWithError:(NSError **)errorPtr;

@end
