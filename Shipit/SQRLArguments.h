//
//  SQRLArguments.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-05.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

/*
 * This file defines the names of command line arguments used by the `shipit`
 * executable.
 *
 * It is included in `shipit` and the Squirrel framework to reduce duplication.
 */

// Associated with the PID of the application process that wants to install an
// update.
//
// This argument is required.
extern NSString * const SQRLProcessIdentifierArgumentName;

// Associated with the bundle identifier of the application to update.
//
// This argument is required.
extern NSString * const SQRLBundleIdentifierArgumentName;

// Associated with a string representation of the URL to _replace_ on disk.
//
// There must be a valid bundle at this URL, and it must have the identifier
// provided for `SQRLBundleIdentifierArgumentName`.
//
// This argument is required.
extern NSString * const SQRLTargetBundleURLArgumentName;

// Associated with a string representation of the URL where the update lives on
// disk.
//
// There must be a valid bundle at this URL, and it must have the identifier
// provided for `SQRLBundleIdentifierArgumentName`.
//
// This argument is required.
extern NSString * const SQRLUpdateBundleURLArgumentName;

// Associated with a string representation of the URL to a directory in which
// the target bundle should be backed up before beginning installation.
//
// This argument is required.
extern NSString * const SQRLBackupURLArgumentName;

// Associated with a boolean which indicates whether the application should be
// launched after being updated.
//
// This argument is required.
extern NSString * const SQRLShouldRelaunchArgumentName;
