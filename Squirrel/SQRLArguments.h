//
//  SQRLArguments.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-05.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

// A key in an XPC reply, associated with a boolean indicating whether the
// requested command was successful.
extern const char * const SQRLReplySuccessKey;

// A key in an XPC reply, associated with a string describing any error that
// occurred.
extern const char * const SQRLReplyErrorKey;

// An XPC event key, associated with a string describing what the ShipIt service
// should do.
extern const char * const SQRLShipItCommandKey;

// Specified for SQRLShipItCommandKey to indicate that an update should be
// installed.
//
// ShipIt will respond immediately indicating whether the initial setup was
// successful, wait for the client to also respond with `SQRLReplySuccessKey`,
// then begin installation after the target application (if any) has terminated.
extern const char * const SQRLShipItInstallCommand;

// Associated with a string containing the bundle identifier of the parent
// application, if ShipIt should wait for it to terminate before beginning
// installation.
//
// This argument is optional. If not provided, installation will begin
// immediately.
extern const char * const SQRLWaitForBundleIdentifierKey;

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

// Associated with a boolean which indicates whether the application should be
// launched after being updated.
//
// This argument is required.
extern const char * const SQRLShouldRelaunchKey;

// Associated with a data object describing the code signing requirement that
// the application must satisfy in order to be valid.
//
// This argument is required.
extern const char * const SQRLCodeSigningRequirementKey;
