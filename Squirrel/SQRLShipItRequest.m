//
//  SQRLShipItRequest.m
//  Squirrel
//
//  Created by Keith Duncan on 08/01/2014.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import "SQRLShipItRequest.h"

#import <ReactiveCocoa/ReactiveCocoa.h>

NSString * const SQRLShipItRequestErrorDomain = @"SQRLShipItRequestErrorDomain";

NSString * const SQRLShipItRequestPropertyErrorKey = @"SQRLShipItRequestPropertyErrorKey";

@interface SQRLShipItRequest () <MTLJSONSerializing>
@end

@implementation SQRLShipItRequest

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

			*error = [NSError errorWithDomain:SQRLShipItRequestErrorDomain code:SQRLShipItRequestErrorMissingRequiredProperty userInfo:userInfo];
		}

		return NO;
	};

	if (!validateKey(@keypath(self.targetBundleURL))) return nil;
	if (!validateKey(@keypath(self.updateBundleURL))) return nil;

	return self;
}

- (instancetype)initWithUpdateBundleURL:(NSURL *)updateBundleURL targetBundleURL:(NSURL *)targetBundleURL bundleIdentifier:(NSString *)bundleIdentifier launchAfterInstallation:(BOOL)launchAfterInstallation {
	return [self initWithDictionary:@{
		@keypath(self.updateBundleURL): updateBundleURL,
		@keypath(self.targetBundleURL): targetBundleURL,
		@keypath(self.bundleIdentifier): bundleIdentifier ?: NSNull.null,
		@keypath(self.launchAfterInstallation): @(launchAfterInstallation),
	} error:NULL];
}

#pragma mark Serialization

+ (NSDictionary *)JSONKeyPathsByPropertyKey {
	return @{};
}

+ (NSValueTransformer *)updateBundleURLJSONTransformer {
	return [NSValueTransformer valueTransformerForName:MTLURLValueTransformerName];
}

+ (NSValueTransformer *)targetBundleURLJSONTransformer {
	return [NSValueTransformer valueTransformerForName:MTLURLValueTransformerName];
}

+ (RACSignal *)readUsingURL:(NSURL *)URL {
	NSParameterAssert(URL != nil);

	return [[[[RACSignal
		defer:^{
			NSError *error;
			NSData *data = [self readFromURL:URL error:&error];
			if (data == nil) {
				return [RACSignal error:error];
			}

			return [RACSignal return:data];
		}]
		flattenMap:^(NSData *data) {
			return [self readFromData:data];
		}]
		catch:^(NSError *error) {
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: NSLocalizedString(@"Could not read update request", nil),
			};
			if (error != nil) {
				userInfo = [userInfo mtl_dictionaryByAddingEntriesFromDictionary:@{
					NSUnderlyingErrorKey: error,
				}];
			}
			return [RACSignal error:[NSError errorWithDomain:SQRLShipItRequestErrorDomain code:SQRLShipItRequestErrorUnarchiving userInfo:userInfo]];
		}]
		setNameWithFormat:@"+readUsingURL: %@", URL];
}

+ (NSData *)readFromURL:(NSURL *)URL error:(NSError **)errorRef {
	__block NSData *data = nil;

	NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
	[coordinator coordinateReadingItemAtURL:URL options:NSFileCoordinatorReadingWithoutChanges error:errorRef byAccessor:^(NSURL *newURL) {
		data = [NSData dataWithContentsOfURL:newURL options:NSDataReadingUncached error:errorRef];
	}];

	return data;
}

+ (RACSignal *)readFromData:(NSData *)data {
	return [[RACSignal
		defer:^{
			NSError *error;
			NSDictionary *JSONDictionary = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
			if (JSONDictionary == nil) {
				return [RACSignal error:error];
			}

			SQRLShipItRequest *request = [MTLJSONAdapter modelOfClass:SQRLShipItRequest.class fromJSONDictionary:JSONDictionary error:&error];
			if (request == nil) {
				return [RACSignal error:error];
			}

			return [RACSignal return:request];

		}]
		setNameWithFormat:@"+readFromData: <NSData %p>", data];
}

- (RACSignal *)writeToURL:(NSURL *)URL {
	NSParameterAssert(URL != nil);

	return [[[[self
		serialization]
		flattenMap:^(NSData *data) {
			NSError *error;
			BOOL write = [self writeData:data toURL:URL error:&error];
			if (!write) {
				return [RACSignal error:error];
			}

			return [RACSignal empty];
		}]
		catch:^(NSError *error) {
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: NSLocalizedString(@"Could not write update request", nil),
				NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"An unknown error occurred while archiving.", nil),
			};
			if (error != nil) {
				userInfo = [userInfo mtl_dictionaryByAddingEntriesFromDictionary:@{
					NSUnderlyingErrorKey: error,
				}];
			}
			return [RACSignal error:[NSError errorWithDomain:SQRLShipItRequestErrorDomain code:SQRLShipItRequestErrorArchiving userInfo:userInfo]];
		}]
		setNameWithFormat:@"%@ -writeUsingURL: %@", self, URL];
}

- (BOOL)writeData:(NSData *)data toURL:(NSURL *)URL error:(NSError **)errorRef {
	__block BOOL success = NO;

	NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
	[coordinator coordinateWritingItemAtURL:URL options:0 error:errorRef byAccessor:^(NSURL *newURL) {
		success = [data writeToURL:newURL options:NSDataWritingAtomic error:errorRef];
	}];

	return success;
}

- (RACSignal *)serialization {
	return [[RACSignal
		defer:^{
			NSDictionary *JSONDictionary = [MTLJSONAdapter JSONDictionaryFromModel:self];

			NSError *error;
			NSData *data = [NSJSONSerialization dataWithJSONObject:JSONDictionary options:0 error:&error];
			if (data == nil) {
				return [RACSignal error:error];
			}

			return [RACSignal return:data];
		}]
		setNameWithFormat:@"%@ serialization", self];
}

@end
