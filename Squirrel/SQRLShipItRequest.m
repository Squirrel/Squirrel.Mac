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

+ (RACSignal *)readUsingURL:(RACSignal *)URL {
	NSParameterAssert(URL != nil);

	return [[[URL
		flattenMap:^(NSURL *stateURL) {
			NSError *error;
			NSData *data = [self readFromURL:stateURL error:&error];
			if (data == nil) {
				return [RACSignal error:error];
			}

			return [RACSignal return:data];
		}]
		flattenMap:^(NSData *data) {
			return [self readFromData:data];
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
	return [[[RACSignal
		return:data]
		tryMap:^ SQRLShipItRequest * (NSData *data, NSError **errorRef) {
			SQRLShipItRequest *state = [NSKeyedUnarchiver unarchiveObjectWithData:data];
			if (![state isKindOfClass:SQRLShipItRequest.class]) {
				if (errorRef != NULL) {
					NSDictionary *userInfo = @{
						NSLocalizedDescriptionKey: NSLocalizedString(@"Could not read saved state", nil),
						NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"An unknown error occurred while unarchiving.", nil)
					};
					*errorRef = [NSError errorWithDomain:SQRLShipItRequestErrorDomain code:SQRLShipItRequestErrorUnarchiving userInfo:userInfo];
				}
				return nil;
			}

			return state;
		}]
		setNameWithFormat:@"+readFromData: <NSData %p>", data];
}

- (RACSignal *)writeUsingURL:(RACSignal *)URL {
	NSParameterAssert(URL != nil);

	return [[[RACSignal
		zip:@[
			URL,
			[self serialization]
		] reduce:^(NSURL *stateURL, NSData *data) {
			NSError *error;
			BOOL write = [self writeData:data toURL:stateURL error:&error];
			if (!write) {
				return [RACSignal error:error];
			}

			return [RACSignal empty];
		}]
		flatten]
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
	return [[[RACSignal
		return:self]
		tryMap:^ NSData * (SQRLShipItRequest *request, NSError **errorRef) {
			NSData *data = [NSKeyedArchiver archivedDataWithRootObject:request];
			if (data == nil) {
				if (errorRef != NULL) {
					NSDictionary *userInfo = @{
						NSLocalizedDescriptionKey: NSLocalizedString(@"Could not save state", nil),
						NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"An unknown error occurred while archiving.", nil)
					};
					*errorRef = [NSError errorWithDomain:SQRLShipItRequestErrorDomain code:SQRLShipItRequestErrorArchiving userInfo:userInfo];
				}
				return nil;
			}

			return data;
		}]
		setNameWithFormat:@"%@ serialization", self];
}

@end
