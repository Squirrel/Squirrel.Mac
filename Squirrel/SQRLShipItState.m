//
//  SQRLShipItState.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-08.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLShipItState.h"
#import "SQRLDirectoryManager.h"
#import <ReactiveCocoa/ReactiveCocoa.h>

@implementation SQRLShipItState

#pragma mark Lifecycle

- (id)initWithDictionary:(NSDictionary *)dictionary error:(NSError **)error {
	self = [super initWithDictionary:dictionary error:error];
	if (self == nil) return nil;

	if (self.targetBundleURL == nil || self.updateBundleURL == nil || self.codeSignature == nil) {
		// TODO: Real error reporting.
		NSLog(@"%@ is missing required properties", self);
		return nil;
	}

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

+ (RACSignal *)readUsingDirectoryManager:(SQRLDirectoryManager *)directoryManager {
	NSParameterAssert(directoryManager != nil);

	return [[[[directoryManager
		shipItStateURL]
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
				// TODO: Better error.
				return [RACSignal error:nil];
			}

			return [RACSignal return:state];
		}]
		setNameWithFormat:@"+readUsingDirectoryManager: %@", directoryManager];
}

- (RACSignal *)writeUsingDirectoryManager:(SQRLDirectoryManager *)directoryManager {
	NSParameterAssert(directoryManager != nil);

	RACSignal *serialization = [[RACSignal
		defer:^{
			NSData *data = [NSKeyedArchiver archivedDataWithRootObject:self];
			if (data == nil) {
				// TODO: Better error.
				return [RACSignal error:nil];
			}

			return [RACSignal return:data];
		}]
		subscribeOn:[RACScheduler schedulerWithPriority:RACSchedulerPriorityHigh]];
	
	RACSignal *stateURL = [[directoryManager
		shipItStateURL]
		subscribeOn:[RACScheduler schedulerWithPriority:RACSchedulerPriorityHigh]];

	return [[[RACSignal
		zip:@[ stateURL, serialization ]
		reduce:^(NSURL *stateURL, NSData *data) {
			NSError *error = nil;
			if (![data writeToURL:stateURL options:NSDataWritingAtomic error:&error]) {
				return [RACSignal error:error];
			}

			return [RACSignal empty];
		}]
		flatten]
		setNameWithFormat:@"%@ -writeUsingDirectoryManager: %@", self, directoryManager];
}

@end
