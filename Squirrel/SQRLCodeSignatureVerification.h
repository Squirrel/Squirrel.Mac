//
//  SQRLCodeSignatureVerfication.h
//  Squirrel
//
//  Created by Alan Rogers on 26/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

// The domain for errors originating within SQRLCodeSignatureVerification.
extern NSString * const SQRLCodeSignatureVerificationErrorDomain;

// The bundle did not pass codesign verification.
extern const NSInteger SQRLCodeSignatureVerificationErrorDidNotPass;

// A static code object could not be created for the target bundle.
extern const NSInteger SQRLCodeSignatureVerificationErrorCouldNotCreateStaticCode;

// Implements the verification of Apple code signatures.
@interface SQRLCodeSignatureVerification : NSObject

// Verifies the code signature of the specified bundle, which must be signed in
// the same way as the running application.
//
// Returns NO if the bundle's code signature could not be verified, and the
// error parameter will contain the specific error.
+ (BOOL)verifyCodeSignatureOfBundle:(NSURL *)bundleLocation error:(NSError **)error;

@end
