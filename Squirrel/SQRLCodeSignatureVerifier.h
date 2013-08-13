//
//  SQRLCodeSignatureVerifier.h
//  Squirrel
//
//  Created by Alan Rogers on 26/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

// The domain for errors originating within SQRLCodeSignatureVerifier.
extern NSString * const SQRLCodeSignatureVerifierErrorDomain;

// The bundle did not pass codesign verification.
extern const NSInteger SQRLCodeSignatureVerifierErrorDidNotPass;

// A static code object could not be created for the target bundle or running
// code.
extern const NSInteger SQRLCodeSignatureVerifierErrorCouldNotCreateStaticCode;

// Implements the verification of Apple code signatures.
@interface SQRLCodeSignatureVerifier : NSObject

// A serialized version of the requirements that the receiver was initialized
// with.
@property (nonatomic, copy, readonly) NSData *requirementData;

// Initializes the receiver to verify bundles based on the code signature of the
// currently-executing code.
//
// Returns nil if an error occurs retrieving the signature for the running code.
- (id)init;

// Initializes the receiver to verify bundles based on the given requirement.
//
// This is the designated initializer for this class.
//
// requirement - The code requirement for tested bundles. This must not be NULL.
- (id)initWithRequirement:(SecRequirementRef)requirement;

// Verifies the code signature of the specified bundle.
//
// bundleURL - The URL to the bundle to verify on disk.
// error     - If not NULL, set to any error that occurs.
//
// Returns NO if the bundle's code signature did not pass verification.
- (BOOL)verifyCodeSignatureOfBundle:(NSURL *)bundleURL error:(NSError **)error;

@end
