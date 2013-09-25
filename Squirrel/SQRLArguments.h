//
//  SQRLArguments.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-05.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

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
//	- SQRLTargetBundleURLKey
//	- SQRLUpdateBundleURLKey
//	- SQRLShouldRelaunchKey
//	- SQRLWaitForConnectionKey
//
// If SQRLWaitForConnectionKey is set to `true`, ShipIt will respond
// immediately indicating whether the initial setup was successful, then begin
// installation shortly after the connection has been terminated by the client.
//
// If SQRLWaitForConnectionKey is set to `false`, ShipIt will begin installation
// immediately, and then reply with whether installation was successful.
extern const char * const SQRLShipItInstallCommand;

// Associated with a boolean, indicating whether ShipIt should wait for the
// connection to terminate before beginning installation.
//
// This argument is required.
extern const char * const SQRLWaitForConnectionKey;

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
