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
#import "Squirrel-Constants.h"

@interface SQRLCodeSignature ()

// A `SecRequirementRef` that tested bundles must satisfy.
//
// This property is automatically retained.
@property (atomic) id requirement;

@end

@implementation SQRLCodeSignature

#pragma mark Properties

- (NSData *)requirementData {
	CFDataRef data = NULL;
	SecRequirementCopyData((__bridge SecRequirementRef)self.requirement, kSecCSDefaultFlags, &data);
	return CFBridgingRelease(data);
}

#pragma mark Lifecycle

+ (instancetype)currentApplicationSignature:(NSError **)error {
	return [self modelWithDictionary:nil error:error];
}

- (id)initWithRequirement:(SecRequirementRef)requirement {
	NSParameterAssert(requirement != NULL);

	return [self initWithDictionary:@{
		@keypath(self.requirement): (__bridge id)requirement
	} error:NULL];
}

- (id)initWithDictionary:(NSDictionary *)dictionary error:(NSError **)error {
	self = [super initWithDictionary:dictionary error:error];
	if (self == nil) return nil;

	if (self.requirement == nil) {
		SecCodeRef staticCode = NULL;
		OSStatus result = SecCodeCopySelf(kSecCSDefaultFlags, &staticCode);
		@onExit {
			if (staticCode != NULL) CFRelease(staticCode);
		};

		if (result != noErr) {
			if (error != NULL) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:nil];
			return nil;
		}

		SecRequirementRef req = NULL;
		result = SecCodeCopyDesignatedRequirement(staticCode, kSecCSDefaultFlags, &req);
		self.requirement = CFBridgingRelease(req);

		if (result != noErr) {
			if (error != NULL) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:nil];
			return nil;
		}
	}

	return self;
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
			
			[subscriber sendError:[NSError errorWithDomain:SQRLErrorDomain code:SQRLCodeSignatureErrorCouldNotCreateStaticCode userInfo:userInfo]];
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
			
			[subscriber sendError:[NSError errorWithDomain:SQRLErrorDomain code:SQRLCodeSignatureErrorDidNotPass userInfo:userInfo]];
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
