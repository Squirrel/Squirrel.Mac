//
//  SQRLInstaller+Private.h
//  Squirrel
//
//  Created by Keith Duncan on 08/01/2014.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import "SQRLInstaller.h"

@class RACSignal;
@class SQRLShipItRequest;

// The defaults key to store a `SQRLInstallerOwnedBundle` so that a moved bundle
// can be restored.
extern NSString * const SQRLInstallerOwnedBundleKey;

// The defaults key to store the number of installation attempts that have been
// made.
extern NSString * const SQRLShipItInstallationAttemptsKey;

@interface SQRLInstaller (Private)

// Moves a bundle that an earlier, unfinished install left in the temporary
// directory back to its original location, if there is one. Sends completed
// when there was nothing to restore or the bundle was restored, and errors if
// it could not be moved back.
- (RACSignal *)abortInstall;

// Creates a private snapshot without replacing the running application.
// The install still performs fresh strict signature verification.
- (RACSignal *)prepareRequest:(SQRLShipItRequest *)request;

// Removes committed obsolete bundles; never restores a committed backup.
- (RACSignal *)cleanupAfterInstallation;

// Whether SquirrelMacEnableEarlyStaging is enabled for the given request or
// in NSUserDefaults for the target application / ShipIt domain.
- (BOOL)isEarlyStagingEnabled;
- (BOOL)isEarlyStagingEnabledForRequest:(SQRLShipItRequest *)request;

@end
