//
//  SQRLUpdateOperation.h
//  Squirrel
//
//  Created by Keith Duncan on 25/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

#import <Squirrel/Squirrel-Constants.h>

@class SQRLUpdate;
@class SQRLCodeSignatureVerifier;

// Error domain for errors originating from `SQRLUpdateOperation`.
extern NSString * const SQRLUpdateOperationErrorDomain;

// Error codes in the `SQRLUpdateOperationErrorDomain` domain.
//
// SQRLUpdateOperationErrorMissingUpdateBundle - no update found in the
//                                               unarchived update
enum {
	SQRLUpdateOperationErrorMissingUpdateBundle = -1,
};

// Checks for and downloads updates.
@interface SQRLUpdateOperation : NSOperation

// Intialiser.
//
// updateRequest - Must not be nil, response expected to conform to the
//                 SQRLUpdate schema.
// verifier      - Must not be nil, downloaded updates are verified before they
//                 are returned.
- (instancetype)initWithUpdateRequest:(NSURLRequest *)updateRequest verifier:(SQRLCodeSignatureVerifier *)verifier;

// The current state of the operation, this property is KVO compliant.
@property (readonly, assign, atomic) SQRLUpdaterState state;

// When the operation `isFinished` this will be non nil and return the result of
// the update.
//
// Returns a block which can be invoked to get the completion status
//  - errorRef, can be NULL
//  - Returns a downloaded and ready to install SQRLUpdate
@property (readonly, copy, atomic) SQRLUpdate * (^completionProvider)(NSError **errorRef);

@end
