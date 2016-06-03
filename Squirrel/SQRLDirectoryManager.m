//
//  SQRLDirectoryManager.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-08.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDirectoryManager.h"

#import <ReactiveCocoa/RACSignal+Operations.h>

@implementation SQRLDirectoryManager

#pragma mark Lifecycle

+ (instancetype)currentApplicationManager {
	static id singleton;
	static dispatch_once_t pred;

	dispatch_once(&pred, ^{
		NSString *identifier = NSBundle.mainBundle.bundleIdentifier ?: [NSBundle.mainBundle objectForInfoDictionaryKey:(__bridge id)kCFBundleNameKey];

		// Should only fallback to when running under otest, where
		// NSBundle.mainBundle doesn't return useful data.
		if (identifier == nil) {
			identifier = NSProcessInfo.processInfo.environment[@"FORCE_APP_IDENTIFIER"];
		}

		NSAssert(identifier != nil, @"Could not automatically determine the current application's identifier");
		singleton = [[self alloc] initWithApplicationIdentifier:identifier];
	});

	return singleton;
}

- (instancetype)initWithApplicationIdentifier:(NSString *)appIdentifier {
	NSParameterAssert(appIdentifier != nil);

	self = [self init];
	if (self == nil) return nil;

	_applicationIdentifier = [appIdentifier copy];

	return self;
}

#pragma mark Folder URLs

- (RACSignal *)storageURL {
	return [[RACSignal
		defer:^{
			NSError *error = nil;
			NSURL *folderURL = [NSFileManager.defaultManager URLForDirectory:NSCachesDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:&error];
			if (folderURL == nil) {
				return [RACSignal error:error];
			}

			folderURL = [folderURL URLByAppendingPathComponent:self.applicationIdentifier];
			if (![NSFileManager.defaultManager createDirectoryAtURL:folderURL withIntermediateDirectories:YES attributes:nil error:&error]) {
				return [RACSignal error:error];
			}

			return [RACSignal return:folderURL];
		}]
		setNameWithFormat:@"%@ -storageURL", self];
}

- (RACSignal *)shipItStateURL {
	return [[[self
		storageURL]
		map:^(NSURL *folderURL) {
			return [folderURL URLByAppendingPathComponent:@"ShipItState.plist"];
		}]
		setNameWithFormat:@"%@ -shipItStateURL", self];
}

- (RACSignal *)shipItStdoutURL {
	return [[[self
		storageURL]
		map:^(NSURL *folderURL) {
			return [folderURL URLByAppendingPathComponent:@"ShipIt_stdout.log"];
		}]
		setNameWithFormat:@"%@ -shipItStdoutURL", self];
}

- (RACSignal *)shipItStderrURL {
	return [[[self
		storageURL]
		map:^(NSURL *folderURL) {
			return [folderURL URLByAppendingPathComponent:@"ShipIt_stderr.log"];
		}]
		setNameWithFormat:@"%@ -shipItStderrURL", self];
}

#pragma mark NSObject

- (NSString *)description {
	return [NSString stringWithFormat:@"<%@: %p>{ applicationIdentifier: %@ }", self.class, self, self.applicationIdentifier];
}

- (NSUInteger)hash {
	return self.applicationIdentifier.hash;
}

- (BOOL)isEqual:(SQRLDirectoryManager *)manager {
	if (self == manager) return YES;
	if (![manager isKindOfClass:SQRLDirectoryManager.class]) return NO;

	return [self.applicationIdentifier isEqual:manager.applicationIdentifier];
}

@end
