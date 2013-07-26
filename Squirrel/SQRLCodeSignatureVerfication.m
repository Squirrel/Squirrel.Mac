//
//  SQRLCodeSignatureVerfication.m
//  Squirrel
//
//  Created by Alan Rogers on 26/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLCodeSignatureVerfication.h"
#import <Security/Security.h>

NSSTRING_CONST(SQRLCodeSignatureVerficationErrorDomain);

const NSInteger SQRLCodeSignatureVerficationErrorCodeSigning = 1;

@implementation SQRLCodeSignatureVerfication

+ (BOOL)verifyCodeSignatureOfBundle:(NSBundle *)bundle error:(NSError **)error {
    __block SecStaticCodeRef staticCode = NULL;
    @onExit {
        if (staticCode != NULL) CFRelease(staticCode);
    };
    
    OSStatus result = SecStaticCodeCreateWithPath((__bridge CFURLRef)bundle.executableURL, kSecCSDefaultFlags, &staticCode);
    if (result != noErr) {
        if (error != NULL) {
            *error = [self codeSigningErrorWithDescription:NSLocalizedString(@"Failed to get static code", nil) securityResult:result];
        }
        return NO;
    }
    
    CFErrorRef errorRef = NULL;
    result = SecStaticCodeCheckValidityWithErrors(staticCode, kSecCSCheckAllArchitectures | kSecCSCheckNestedCode, NULL, &errorRef);
    if (result == noErr) {
        return YES;
    } else {
        NSMutableDictionary *userInfo = [@{
                                           NSLocalizedDescriptionKey: NSLocalizedString(@"Code signature did not pass validation", nil)
                                           } mutableCopy];
        
        if (errorRef != NULL) {
            userInfo[NSUnderlyingErrorKey] = CFBridgingRelease(errorRef);
        }
        
        if (error != NULL) {
            *error = [NSError errorWithDomain:SQRLCodeSignatureVerficationErrorDomain code:SQRLCodeSignatureVerficationErrorCodeSigning userInfo:userInfo];
        }
    }
    return NO;
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
    
	return [NSError errorWithDomain:SQRLCodeSignatureVerficationErrorDomain code:SQRLCodeSignatureVerficationErrorCodeSigning userInfo:userInfo];
}


@end
