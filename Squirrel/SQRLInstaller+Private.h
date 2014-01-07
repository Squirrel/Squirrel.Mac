//
//  SQRLInstaller+Private.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-11-19.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLInstaller.h"

// A preferences key for the URL where the target bundle has been moved before
// installation.
//
// This is stored in preferences to prevent an attacker from rewriting the URL
// during the installation process.
//
// Note that this key must remain backwards compatible, so ShipIt doesn't fail
// confusingly on a newer version.
extern NSString * const SQRLInstallerOwnedTargetBundleURLKey;

// A preferences key for the URL where the update bundle has been moved before
// installation.
//
// This is stored in preferences to prevent an attacker from rewriting the URL
// during the installation process.
//
// Note that this key must remain backwards compatible, so ShipIt doesn't fail
// confusingly on a newer version.
extern NSString * const SQRLInstallerOwnedUpdateBundleURLKey;

// A preferences key for the code signature that the update _and_ target bundles
// must match in order to be valid.
//
// This is stored in preferences to prevent an attacker from spoofing the
// validity requirements.
//
// Note that this key must remain backwards compatible, so ShipIt doesn't fail
// confusingly on a newer version.
extern NSString * const SQRLInstallerCodeSignatureKey;
