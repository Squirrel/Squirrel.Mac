//
//  Squirrel-Constants.h
//  Squirrel
//
//  Created by Keith Duncan on 30/10/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

// Error domain for errors originating in Squirrel.
extern NSString * const SQRLErrorDomain;

// Error codes for errors originating in Squirrel.
//
// SQRLCodeSignatureErrorDidNotPass - The bundle did not pass codesign
// verification.
//
// SQRLCodeSignatureErrorCouldNotCreateStaticCode - A static code object could
// not be created for the target bundle or running code.
//
// SQRLShipItStateErrorMissingRequiredProperty - A required property was `nil`
// upon initialization. Includes `SQRLShipItStatePropertyErrorKey` in the
// error's `userInfo` dictionary.
//
// SQRLShipItStateErrorUnarchiving - The saved state on disk could not be
// unarchived, possibly because it's invalid.
//
// SQRLShipItStateErrorArchiving - The state object could not be archived.
//
// SQRLUpdaterErrorMissingUpdateBundle - The downloaded update does not contain
// an app bundle, or it was deleted on disk before we could get to it.
//
// SQRLUpdaterErrorPreparingUpdateJob - An error occurred in the out-of-process
// updater while it was setting up.
//
// SQRLUpdaterErrorRetrievingCodeSigningRequirement - The code signing
// requirement for the running application could not be retrieved.
//
// SQRLUpdaterErrorInvalidServerResponse - The server sent a response that we
// didn't understand. Includes `SQRLUpdaterServerDataErrorKey` in the error's
// `userInfo` dictionary.
//
// SQRLUpdaterErrorInvalidJSON - The server sent update JSON that we didn't
// understand. Includes `SQRLUpdaterJSONObjectErrorKey` in the error's
// `userInfo` dictionary.
//
// SQRLZipArchiverShellTaskFailed - `SQRLZipArchiver` tried to invoke the shell
// and failed. Includes `SQRLZipArchiverExitStatusErrorKey` in the error's
// `userInfo` dictionary.
//
// SQRLShipItLauncherErrorCouldNotStartService - The ShipIt service could not be
// started.
typedef enum : NSInteger {
	SQRLCodeSignatureErrorDidNotPass = -1,
	SQRLCodeSignatureErrorCouldNotCreateStaticCode = -2,

	SQRLShipItStateErrorMissingRequiredProperty = -100,
	SQRLShipItStateErrorUnarchiving = -101,
	SQRLShipItStateErrorArchiving = -102,

	SQRLUpdaterErrorMissingUpdateBundle = -200,
	SQRLUpdaterErrorPreparingUpdateJob = -201,
	SQRLUpdaterErrorRetrievingCodeSigningRequirement = -202,
	SQRLUpdaterErrorInvalidServerResponse = -203,
	SQRLUpdaterErrorInvalidJSON = -204,

	SQRLZipArchiverShellTaskFailed = -300,

	SQRLShipItLauncherErrorCouldNotStartService = -400,
} SQRLErrorCode;
