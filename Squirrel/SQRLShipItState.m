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

	return self;
}

- (id)initWithTargetBundleURL:(NSURL *)targetBundleURL updateBundleURL:(NSURL *)updateBundleURL bundleIdentifier:(NSString *)bundleIdentifier {
	return [self initWithDictionary:@{
		@keypath(self.targetBundleURL): targetBundleURL,
		@keypath(self.updateBundleURL): updateBundleURL,
		@keypath(self.bundleIdentifier): bundleIdentifier ?: NSNull.null,
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
			return [self readFromData:data];
		}]
		setNameWithFormat:@"+readUsingURL: %@", URL];
}

+ (RACSignal *)readFromDefaults:(NSString *)defaultsKey {
	NSParameterAssert(defaultsKey != nil);

	return [[[[[RACSignal
		return:defaultsKey]
		map:^(NSString *key) {
			return [NSUserDefaults.standardUserDefaults dataForKey:key];
		}]
		tryMap:^ NSData * (NSData *data, NSError **errorRef) {
			if (data == nil) {
				if (errorRef != NULL) {
					NSDictionary *errorInfo = @{
						NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn’t read saved state", @"SQRLShipItState read from defaults error description"),
						NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"", @"SQRLShipItState read from defaults error recovery suggestion"),
					};
					*errorRef = [NSError errorWithDomain:SQRLShipItStateErrorDomain code:SQRLShipItStateErrorUnarchiving userInfo:errorInfo];
				}
				return nil;
			}

			return data;
		}]
		flattenMap:^(NSData *data) {
			return [self readFromData:data];
		}]
		setNameWithFormat:@"+readFromDefaults: %@", defaultsKey];
}

+ (RACSignal *)readFromData:(NSData *)data {
	return [[[RACSignal
		return:data]
		tryMap:^ SQRLShipItState * (NSData *data, NSError **errorRef) {
			SQRLShipItState *state = [NSKeyedUnarchiver unarchiveObjectWithData:data];
			if (![state isKindOfClass:SQRLShipItState.class]) {
				if (errorRef != NULL) {
					NSDictionary *userInfo = @{
						NSLocalizedDescriptionKey: NSLocalizedString(@"Could not read saved state", nil),
						NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"An unknown error occurred while unarchiving.", nil)
					};
					*errorRef = [NSError errorWithDomain:SQRLShipItStateErrorDomain code:SQRLShipItStateErrorUnarchiving userInfo:userInfo];
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
			NSError *error = nil;
			if (![data writeToURL:stateURL options:NSDataWritingAtomic error:&error]) {
				return [RACSignal error:error];
			}

			return [RACSignal empty];
		}]
		flatten]
		setNameWithFormat:@"%@ -writeUsingURL: %@", self, URL];
}

- (RACSignal *)writeToDefaults:(NSString *)defaultsKey {
	return [[[self
		serialization]
		flattenMap:^(NSData *data) {
			[NSUserDefaults.standardUserDefaults setObject:data forKey:defaultsKey];

			return [RACSignal empty];
		}]
		setNameWithFormat:@"%@ writeToDefaults: %@", self, defaultsKey];
}

- (RACSignal *)serialization {
	return [[[RACSignal
		return:self]
		tryMap:^ NSData * (SQRLShipItState *state, NSError **errorRef) {
			NSData *data = [NSKeyedArchiver archivedDataWithRootObject:self];
			if (data == nil) {
				if (errorRef != NULL) {
					NSDictionary *userInfo = @{
						NSLocalizedDescriptionKey: NSLocalizedString(@"Could not save state", nil),
						NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"An unknown error occurred while archiving.", nil)
					};
					*errorRef = [NSError errorWithDomain:SQRLShipItStateErrorDomain code:SQRLShipItStateErrorArchiving userInfo:userInfo];
				}
				return nil;
			}

			return data;
		}]
		setNameWithFormat:@"%@ serialization", self];
}

@end
