//
//  SQRLInstaller+Private.h
//  Squirrel
//
//  Created by Keith Duncan on 08/01/2014.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import "SQRLInstaller.h"

@class RACSignal;

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

@end
