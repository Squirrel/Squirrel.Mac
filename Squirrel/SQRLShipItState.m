//
//  SQRLShipItState.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-08.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLShipItState.h"
#import <ReactiveCocoa/ReactiveCocoa.h>

NSString * const SQRLShipItStateErrorDomain = @"SQRLShipItStateErrorDomain";
NSString * const SQRLShipItStatePropertyErrorKey = @"SQRLShipItStatePropertyErrorKey";

const NSInteger SQRLShipItStateErrorMissingRequiredProperty = 1;
const NSInteger SQRLShipItStateErrorUnarchiving = 2;
const NSInteger SQRLShipItStateErrorArchiving = 3;

@implementation SQRLShipItState

#pragma mark Lifecycle

- (id)initWithDictionary:(NSDictionary *)dictionary error:(NSError **)error {
	self = [super initWithDictionary:dictionary error:error];
	if (self == nil) return nil;

	BOOL (^validateKey)(NSString *) = ^(NSString *key) {
		if ([self valueForKey:key] != nil) return YES;

		if (error != NULL) {
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: NSLocalizedString(@"Missing required value", nil),
				NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:NSLocalizedString(@"\"%@\" must not be set to nil.", nil), key]
			};

			*error = [NSError errorWithDomain:SQRLShipItStateErrorDomain code:SQRLShipItStateErrorMissingRequiredProperty userInfo:userInfo];
		}

		return NO;
	};

	if (!validateKey(@keypath(self.targetBundleURL))) return nil;
	if (!validateKey(@keypath(self.updateBundleURL))) return nil;
	if (!validateKey(@keypath(self.codeSignature))) return nil;

	return self;
}

- (id)initWithTargetBundleURL:(NSURL *)targetBundleURL updateBundleURL:(NSURL *)updateBundleURL bundleIdentifier:(NSString *)bundleIdentifier codeSignature:(SQRLCodeSignature *)codeSignature {
	return [self initWithDictionary:@{
		@keypath(self.targetBundleURL): targetBundleURL,
		@keypath(self.updateBundleURL): updateBundleURL,
		@keypath(self.bundleIdentifier): bundleIdentifier ?: NSNull.null,
		@keypath(self.codeSignature): codeSignature,
	} error:NULL];
}

#pragma mark Serialization

+ (RACSignal *)readUsingURL:(RACSignal *)URL {
	NSParameterAssert(URL != nil);

	return [[[URL
		flattenMap:^(NSURL *stateURL) {
			NSError *error = nil;
			NSData *data = [NSData dataWithContentsOfURL:stateURL options:NSDataReadingUncached error:&error];
			if (data == nil) {
				return [RACSignal error:error];
			}

			return [RACSignal return:data];
		}]
		flattenMap:^(NSData *data) {
			SQRLShipItState *state = [NSKeyedUnarchiver unarchiveObjectWithData:data];
			if (![state isKindOfClass:SQRLShipItState.class]) {
				NSDictionary *userInfo = @{
					NSLocalizedDescriptionKey: NSLocalizedString(@"Could not read saved state", nil),
					NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"An unknown error occurred while unarchiving.", nil)
				};

				return [RACSignal error:[NSError errorWithDomain:SQRLShipItStateErrorDomain code:SQRLShipItStateErrorUnarchiving userInfo:userInfo]];
			}

			return [RACSignal return:state];
		}]
		setNameWithFormat:@"+readUsingURL: %@", URL];
}

- (RACSignal *)writeUsingURL:(RACSignal *)URL {
	NSParameterAssert(URL != nil);

	RACSignal *serialization = [RACSignal defer:^{
		NSData *data = [NSKeyedArchiver archivedDataWithRootObject:self];
		if (data == nil) {
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: NSLocalizedString(@"Could not save state", nil),
				NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"An unknown error occurred while archiving.", nil)
			};

			return [RACSignal error:[NSError errorWithDomain:SQRLShipItStateErrorDomain code:SQRLShipItStateErrorArchiving userInfo:userInfo]];
		}

		return [RACSignal return:data];
	}];

	return [[[RACSignal
		zip:@[
			URL,
			serialization
		] reduce:^(NSURL *stateURL, NSData *data) {
			NSError *error = nil;
			if (![data writeToURL:stateURL options:NSDataWritingAtomic error:&error]) {
				return [RACSignal error:error];
			}

			return [RACSignal empty];
		}]
		flatten]
		setNameWithFormat:@"%@ -writeUsingURL: %@", self, URL];
}

@end
