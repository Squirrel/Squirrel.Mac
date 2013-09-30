//
//  SQRLCodeSignatureVerifier.m
//  Squirrel
//
//  Created by Alan Rogers on 26/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLCodeSignatureVerifier.h"
#import <ReactiveCocoa/EXTScope.h>
#import <ReactiveCocoa/ReactiveCocoa.h>
#import <Security/Security.h>

NSString * const SQRLCodeSignatureVerifierErrorDomain = @"SQRLCodeSignatureVerifierErrorDomain";

const NSInteger SQRLCodeSignatureVerifierErrorDidNotPass = -1;
const NSInteger SQRLCodeSignatureVerifierErrorCouldNotCreateStaticCode = -2;

@interface SQRLCodeSignatureVerifier ()

// A requirement that tested bundles must satisfy.
@property (nonatomic, readonly) SecRequirementRef requirement;

@end

@implementation SQRLCodeSignatureVerifier

#pragma mark Properties

- (NSData *)requirementData {
	CFDataRef data = NULL;
	SecRequirementCopyData(self.requirement, kSecCSDefaultFlags, &data);
	return CFBridgingRelease(data);
}

#pragma mark Lifecycle

- (id)init {
	SecCodeRef staticCode = NULL;
	OSStatus result = SecCodeCopySelf(kSecCSDefaultFlags, &staticCode);
	@onExit {
		if (staticCode != NULL) CFRelease(staticCode);
	};

	if (result != noErr) return nil;

	SecRequirementRef requirement = NULL;
	result = SecCodeCopyDesignatedRequirement(staticCode, kSecCSDefaultFlags, &requirement);
	@onExit {
		if (requirement != NULL) CFRelease(requirement);
	};

	if (result != noErr) return nil;
	return [self initWithRequirement:requirement];
}

- (id)initWithRequirement:(SecRequirementRef)requirement {
	NSParameterAssert(requirement != NULL);

	self = [super init];
	if (self == nil) return nil;

	_requirement = (SecRequirementRef)CFRetain(requirement);

	return self;
}

- (void)dealloc {
	if (_requirement != NULL) {
		CFRelease(_requirement);
		_requirement = NULL;
	}
}

#pragma mark Verification

- (RACSignal *)verifyCodeSignatureOfBundle:(NSURL *)bundleURL {
	NSParameterAssert(bundleURL != nil);

	return [[RACSignal createSignal:^ RACDisposable * (id<RACSubscriber> subscriber) {
		SecStaticCodeRef staticCode = NULL;
		
		OSStatus result = SecStaticCodeCreateWithPath((__bridge CFURLRef)bundleURL, kSecCSDefaultFlags, &staticCode);
		@onExit {
			if (staticCode != NULL) CFRelease(staticCode);
		};

		if (result != noErr) {
			NSMutableDictionary *userInfo = [@{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Failed to get static code for bundle %@", nil), bundleURL],
			} mutableCopy];
			
			NSString *failureReason = CFBridgingRelease(SecCopyErrorMessageString(result, NULL));
			if (failureReason != nil) userInfo[NSLocalizedFailureReasonErrorKey] = failureReason;
			
			[subscriber sendError:[NSError errorWithDomain:SQRLCodeSignatureVerifierErrorDomain code:SQRLCodeSignatureVerifierErrorCouldNotCreateStaticCode userInfo:userInfo]];
			return nil;
		}
		
		CFErrorRef validityError = NULL;
		result = SecStaticCodeCheckValidityWithErrors(staticCode, kSecCSCheckAllArchitectures, self.requirement, &validityError);
		@onExit {
			if (validityError != NULL) CFRelease(validityError);
		};

		if (result != noErr) {
			NSMutableDictionary *userInfo = [@{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Code signature at URL %@ did not pass validation", nil), bundleURL],
			} mutableCopy];
			
			NSString *failureReason = CFBridgingRelease(SecCopyErrorMessageString(result, NULL));
			if (failureReason != nil) userInfo[NSLocalizedFailureReasonErrorKey] = failureReason;
			if (validityError != NULL) userInfo[NSUnderlyingErrorKey] = (__bridge NSError *)validityError;
			
			[subscriber sendError:[NSError errorWithDomain:SQRLCodeSignatureVerifierErrorDomain code:SQRLCodeSignatureVerifierErrorDidNotPass userInfo:userInfo]];
			return nil;
		}
		
		[subscriber sendCompleted];
		return nil;
	}] setNameWithFormat:@"-verifyCodeSignatureOfBundle: %@", bundleURL];
}

@end
