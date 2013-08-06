//
//  SQRLCodeSignatureVerfication.m
//  Squirrel
//
//  Created by Alan Rogers on 26/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLCodeSignatureVerification.h"
#import <Security/Security.h>

NSString * const SQRLCodeSignatureVerificationErrorDomain = @"SQRLCodeSignatureVerificationErrorDomain";

const NSInteger SQRLCodeSignatureVerificationErrorDidNotPass = -1;
const NSInteger SQRLCodeSignatureVerificationErrorCouldNotCreateStaticCode = -2;

@implementation SQRLCodeSignatureVerification

+ (BOOL)verifyCodeSignatureOfBundle:(NSURL *)bundleURL error:(NSError **)error {
	SecStaticCodeRef staticCode = NULL;
	
	OSStatus result = SecStaticCodeCreateWithPath((__bridge CFURLRef)bundleURL, kSecCSDefaultFlags, &staticCode);
	@onExit {
		if (staticCode != NULL) CFRelease(staticCode);
	};

	if (result != noErr) {
		if (error != NULL) {
			NSMutableDictionary *userInfo = [@{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Failed to get static code for bundle %@", nil), bundleURL],
			} mutableCopy];
			
			NSString *failureReason = CFBridgingRelease(SecCopyErrorMessageString(result, NULL));
			if (failureReason != nil) userInfo[NSLocalizedFailureReasonErrorKey] = failureReason;
			
			*error = [NSError errorWithDomain:SQRLCodeSignatureVerificationErrorDomain code:SQRLCodeSignatureVerificationErrorCouldNotCreateStaticCode userInfo:userInfo];
		}

		return NO;
	}
	
	CFErrorRef validityError = NULL;
	result = SecStaticCodeCheckValidityWithErrors(staticCode, kSecCSCheckAllArchitectures, NULL, &validityError);
	if (result != noErr) {
		if (error != NULL) {
			NSMutableDictionary *userInfo = [@{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Code signature at URL %@ did not pass validation", nil), bundleURL],
			} mutableCopy];
			
			NSString *failureReason = CFBridgingRelease(SecCopyErrorMessageString(result, NULL));
			if (failureReason != nil) userInfo[NSLocalizedFailureReasonErrorKey] = failureReason;
			if (validityError != NULL) userInfo[NSUnderlyingErrorKey] = (__bridge NSError *)validityError;
			
			*error = [NSError errorWithDomain:SQRLCodeSignatureVerificationErrorDomain code:SQRLCodeSignatureVerificationErrorDidNotPass userInfo:userInfo];
		}

		return NO;
	}
	
	return YES;
}

@end
