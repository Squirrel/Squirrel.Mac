//
//  SQRLArguments.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-05.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

// The label for the ShipIt XPC service.
extern const char * const SQRLShipItServiceLabel;

// A key in an XPC reply, associated with a boolean indicating whether the
// requested command was successful.
extern const char * const SQRLShipItSuccessKey;

// A key in an XPC reply, associated with a string describing any error that
// occurred.
extern const char * const SQRLShipItErrorKey;

// An XPC event key, associated with a string describing what the ShipIt service
// should do.
extern const char * const SQRLShipItCommandKey;

// Specified for SQRLShipItCommandKey to indicate that an update should be
// installed.
//
// The event can contain the following keys to configure the installation:
//
//	- SQRLProcessIdentifierKey
//	- SQRLBundleIdentifierKey
//	- SQRLTargetBundleURLKey
//	- SQRLUpdateBundleURLKey
//	- SQRLBackupURLKey
//	- SQRLShouldRelaunchKey
extern const char * const SQRLShipItInstallCommand;

// Associated with the PID of the application process that wants to install an
// update.
//
// This key is required.
extern const char * const SQRLProcessIdentifierKey;

// Associated with the bundle identifier of the application to update.
//
// This argument is required.
extern const char * const SQRLBundleIdentifierKey;

// Associated with a string representation of the URL to _replace_ on disk.
//
// There must be a valid bundle at this URL, and it must have the identifier
// provided for `SQRLBundleIdentifierKey`.
//
// This argument is required.
extern const char * const SQRLTargetBundleURLKey;

// Associated with a string representation of the URL where the update lives on
// disk.
//
// There must be a valid bundle at this URL, and it must have the identifier
// provided for `SQRLBundleIdentifierKey`.
//
// This argument is required.
extern const char * const SQRLUpdateBundleURLKey;

// Associated with a string representation of the URL to a directory in which
// the target bundle should be backed up before beginning installation.
//
// This argument is required.
extern const char * const SQRLBackupURLKey;

// Associated with a boolean which indicates whether the application should be
// launched after being updated.
//
// This argument is required.
extern const char * const SQRLShouldRelaunchKey;
