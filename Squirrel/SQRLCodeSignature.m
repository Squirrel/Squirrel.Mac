//
//  SQRLCodeSignature.m
//  Squirrel
//
//  Created by Alan Rogers on 26/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLCodeSignature.h"
#import <ReactiveCocoa/EXTScope.h>
#import <ReactiveCocoa/ReactiveCocoa.h>
#import <Security/Security.h>

NSString * const SQRLCodeSignatureErrorDomain = @"SQRLCodeSignatureErrorDomain";

const NSInteger SQRLCodeSignatureErrorDidNotPass = -1;
const NSInteger SQRLCodeSignatureErrorCouldNotCreateStaticCode = -2;

@interface SQRLCodeSignature ()

// A `SecRequirementRef` that tested bundles must satisfy.
@property (atomic, strong) id requirement;

@end

@implementation SQRLCodeSignature

#pragma mark Properties

- (NSData *)requirementData {
	CFDataRef data = NULL;
	SecRequirementCopyData((__bridge SecRequirementRef)self.requirement, kSecCSDefaultFlags, &data);
	return CFBridgingRelease(data);
}

#pragma mark Lifecycle

+ (instancetype)currentApplicationSignature:(NSError **)errorRef {
	SecCodeRef staticCode = NULL;
	OSStatus error = SecCodeCopySelf(kSecCSDefaultFlags, &staticCode);
	if (error != noErr) {
		if (errorRef != NULL) *errorRef = [NSError errorWithDomain:NSOSStatusErrorDomain code:error userInfo:nil];
		return nil;
	}

	@onExit {
		CFRelease(staticCode);
	};

	return [self signatureWithCode:staticCode error:errorRef];
}

+ (instancetype)signatureWithBundle:(NSURL *)bundleURL error:(NSError **)errorRef {
	SecStaticCodeRef bundleCode = NULL;
	OSStatus error = SecStaticCodeCreateWithPath((__bridge CFURLRef)bundleURL, kSecCSDefaultFlags, &bundleCode);
	if (error != noErr) {
		if (errorRef != NULL) *errorRef = [NSError errorWithDomain:NSOSStatusErrorDomain code:error userInfo:nil];
		return nil;
	}

	@onExit {
		CFRelease(bundleCode);
	};

	return [self signatureWithCode:bundleCode error:errorRef];
}

+ (instancetype)signatureWithCode:(SecStaticCodeRef)code error:(NSError **)errorRef {
	SecRequirementRef designatedRequirement = NULL;
	OSStatus error = SecCodeCopyDesignatedRequirement(code, kSecCSDefaultFlags, &designatedRequirement);
	if (error != noErr) {
		if (errorRef != NULL) *errorRef = [NSError errorWithDomain:NSOSStatusErrorDomain code:error userInfo:nil];
		return nil;
	}

	@onExit {
		CFRelease(designatedRequirement);
	};

	return [[SQRLCodeSignature alloc] initWithRequirement:designatedRequirement];
}

- (id)initWithRequirement:(SecRequirementRef)requirement {
	NSParameterAssert(requirement != NULL);

	return [self initWithDictionary:@{
		@keypath(self.requirement): (__bridge id)requirement
	} error:NULL];
}

#pragma mark Verification

- (RACSignal *)verifyBundleAtURL:(NSURL *)bundleURL {
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
			
			[subscriber sendError:[NSError errorWithDomain:SQRLCodeSignatureErrorDomain code:SQRLCodeSignatureErrorCouldNotCreateStaticCode userInfo:userInfo]];
			return nil;
		}
		
		CFErrorRef validityError = NULL;
		result = SecStaticCodeCheckValidityWithErrors(staticCode, kSecCSCheckAllArchitectures, (__bridge SecRequirementRef)self.requirement, &validityError);
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
			
			[subscriber sendError:[NSError errorWithDomain:SQRLCodeSignatureErrorDomain code:SQRLCodeSignatureErrorDidNotPass userInfo:userInfo]];
			return nil;
		}
		
		[subscriber sendCompleted];
		return nil;
	}] setNameWithFormat:@"-verifyCodeSignatureOfBundle: %@", bundleURL];
}

#pragma mark MTLModel

+ (NSDictionary *)encodingBehaviorsByPropertyKey {
	return [super.encodingBehaviorsByPropertyKey mtl_dictionaryByAddingEntriesFromDictionary:@{
		@keypath(SQRLCodeSignature.new, requirement): @(MTLModelEncodingBehaviorExcluded)
	}];
}

#pragma mark NSCoding

- (void)encodeWithCoder:(NSCoder *)coder {
	[super encodeWithCoder:coder];
	[coder encodeObject:self.requirementData forKey:@keypath(self.requirement)];
}

- (id)decodeRequirementWithCoder:(NSCoder *)coder modelVersion:(NSUInteger)version {
	NSData *data = [coder decodeObjectForKey:@keypath(self.requirement)];
	if (data == nil) return nil;

	SecRequirementRef requirement = NULL;
	SecRequirementCreateWithData((__bridge CFDataRef)data, kSecCSDefaultFlags, &requirement);
	return CFBridgingRelease(requirement);
}

@end
