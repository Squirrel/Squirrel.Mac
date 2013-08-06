//
//  SQRLCodeSignatureVerfication.m
//  Squirrel
//
//  Created by Alan Rogers on 26/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLCodeSignatureVerification.h"
#import <Security/Security.h>

NSSTRING_CONST(SQRLCodeSignatureVerificationErrorDomain);

const NSInteger SQRLCodeSignatureVerificationErrorCodeSigning = 1;

@implementation SQRLCodeSignatureVerification

+ (BOOL)verifyCodeSignatureOfBundle:(NSURL *)bundleURL error:(NSError **)error {
	__block SecStaticCodeRef staticCode = NULL;
	@onExit {
		if (staticCode != NULL) CFRelease(staticCode);
	};
	
	OSStatus result = SecStaticCodeCreateWithPath((__bridge CFURLRef)bundleURL, kSecCSDefaultFlags, &staticCode);
	if (result != noErr) {
		if (error != NULL) {
			*error = [self codeSigningErrorWithDescription:[NSString stringWithFormat:NSLocalizedString(@"Failed to get static code for bundle %@", nil), bundleURL] securityResult:result];
		}
		return NO;
	}
	
	CFErrorRef validityError = NULL;
	result = SecStaticCodeCheckValidityWithErrors(staticCode, kSecCSCheckAllArchitectures /* | kSecCSCheckNestedCode */, NULL, &validityError);
	if (result != noErr) {
		NSMutableDictionary *userInfo = [@{
			NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Code signature at URL %@ did not pass validation", nil), bundleURL],
		} mutableCopy];
		
		if (validityError != NULL) {
			userInfo[NSUnderlyingErrorKey] = CFBridgingRelease(validityError);
		}
		
		if (error != NULL) {
			*error = [NSError errorWithDomain:SQRLCodeSignatureVerificationErrorDomain code:SQRLCodeSignatureVerificationErrorCodeSigning userInfo:userInfo];
		}
		return NO;
	}
	
	return YES;
}

+ (NSError *)codeSigningErrorWithDescription:(NSString *)description securityResult:(OSStatus)result {
	NSParameterAssert(description != nil);
	
	NSMutableDictionary *userInfo = [@{
		NSLocalizedDescriptionKey: description,
	} mutableCopy];
	
	NSString *failureReason = CFBridgingRelease(SecCopyErrorMessageString(result, NULL));
	if (failureReason != nil) {
		userInfo[NSLocalizedFailureReasonErrorKey] = failureReason;
	}
	
	return [NSError errorWithDomain:SQRLCodeSignatureVerificationErrorDomain code:SQRLCodeSignatureVerificationErrorCodeSigning userInfo:userInfo];
}


@end
