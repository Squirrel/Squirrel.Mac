//
//  SQRLCodeSignatureVerfication.h
//  Squirrel
//
//  Created by Alan Rogers on 26/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

extern NSString * const SQRLCodeSignatureVerficationErrorDomain;

// An error occurred validating the code signature of a downloaded update.
extern const NSInteger SQRLCodeSignatureVerficationErrorCodeSigning;

@interface SQRLCodeSignatureVerfication : NSObject

// Verifies the code signature of the specified bundle, which must be signed in
// the same way as the running application.
//
// Returns NO if the bundle's code signature could not be verified, and the
// error parameter will contain the specific error.
+ (BOOL)verifyCodeSignatureOfBundle:(NSBundle *)bundle error:(NSError **)error;

@end
