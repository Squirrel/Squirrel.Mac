//
//  SQRLCodeSignature.h
//  Squirrel
//
//  Created by Alan Rogers on 26/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <Mantle/Mantle.h>

@class RACSignal;

// Implements the verification of Apple code signatures.
@interface SQRLCodeSignature : MTLModel

// A serialized version of the `SecRequirementRef` that the receiver was
// initialized with.
@property (nonatomic, copy, readonly) NSData *requirementData;

// Determines the code signature of the currently-executing application.
//
// error - If not NULL, set to any error that occurs.
//
// Returns a `SQRLCodeSignature`, or nil if an error occurs retrieving the
// signature for the running code.
+ (instancetype)currentApplicationSignature:(NSError **)error;

// Initializes the receiver with the given requirement.
//
// requirement - The code requirement for tested bundles. This must not be NULL.
- (id)initWithRequirement:(SecRequirementRef)requirement;

// Verifies that the code signature of the specified bundle matches the receiver.
//
// bundleURL - The URL to the bundle to verify on disk. This must not be nil.
//
// Returns a signal which will synchronously send completed on success, or error
// if the code signature was not verified successfully.
- (RACSignal *)verifyBundleAtURL:(NSURL *)bundleURL;

@end
