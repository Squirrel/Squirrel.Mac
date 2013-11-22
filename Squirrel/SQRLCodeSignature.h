//
//  SQRLCodeSignature.h
//  Squirrel
//
//  Created by Alan Rogers on 26/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <Mantle/Mantle.h>

// The domain for errors originating within SQRLCodeSignature.
extern NSString * const SQRLCodeSignatureErrorDomain;

// The bundle did not pass codesign verification.
extern const NSInteger SQRLCodeSignatureErrorDidNotPass;

// A static code object could not be created for the target bundle or running
// code.
extern const NSInteger SQRLCodeSignatureErrorCouldNotCreateStaticCode;

@class RACSignal;

// Implements the verification of Apple code signatures and requirements.
@interface SQRLCodeSignature : MTLModel

// A serialized version of the `SecRequirementRef` that the receiver was
// initialized with.
@property (nonatomic, copy, readonly) NSData *requirementData;

// Determines the designated requirement of the currently-executing application.
// The returned code signature can be used to verify that a bundle is code sign
// valid and meets the designated requirement of the current application.
//
// error - If not NULL, set to any error that occurs.
//
// Returns a `SQRLCodeSignature`, or nil if an error occurs retrieving the
// designated requirement for the running code.
+ (instancetype)currentApplicationSignature:(NSError **)error;

// Determines the designated requirement of the specified bundle. The returned
// code signature can be used to verify that an arbitrary bundle is valid and
// meets the designated requirement of `bundle`.
//
// bundleURL - Must not be nil, the location of a bundle directory structure
//             which has been code signed and includes a designated requirement.
//             This bundle's designated requirement is used when verifying other
//             bundles.
// error     - If not NULL, set to any error that occurs.
//
// Returns a `SQRLCodeSignature`, or nil if an error occurs retrieving the
// designated requirement of the bundle at `bundleURL`.
+ (instancetype)signatureWithBundle:(NSURL *)bundleURL error:(NSError **)error;

// Verifies the code signature of the specified bundle and verifies that the
// bundle meets the receiver's requirement.
//
// bundleURL - The URL to the bundle to verify on disk. This must not be nil.
//
// Returns a signal which will synchronously send completed on success, or error
// if the requirement was not verified successfully.
- (RACSignal *)verifyBundleAtURL:(NSURL *)bundleURL;

@end
