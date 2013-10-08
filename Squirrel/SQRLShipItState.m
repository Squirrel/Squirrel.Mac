//
//  SQRLShipItState.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-08.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLShipItState.h"
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

@end
