//
//  SQRLDirectoryManager.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-08.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDirectoryManager.h"
#import <ReactiveCocoa/ReactiveCocoa.h>
#import <ReactiveCocoa/EXTScope.h>

@interface SQRLDirectoryManager ()

// The application identifier to use in file locations.
@property (nonatomic, copy, readonly) NSString *applicationIdentifier;

@end

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
			identifier = NSRunningApplication.currentApplication.localizedName;
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

+ (NSString *)fileSystemNameForIdentifier:(NSString *)identifier {
	// Periods are problematic in the filesystem because they denote file type.
	// A directory can become a package which can be undesirable.
	return [identifier stringByReplacingOccurrencesOfString:@"." withString:@"~"];
}

+ (RACSignal *)createDirectoryForURL:(RACSignal *)URLSignal {
	return [[URLSignal
		try:^(NSURL *directoryURL, NSError **errorRef) {
			return [NSFileManager.defaultManager createDirectoryAtURL:directoryURL withIntermediateDirectories:YES attributes:nil error:errorRef];
		}]
		setNameWithFormat:@"%@ +createDirectoryForURL: %@", self, URLSignal];
}

- (RACSignal *)applicationSupportURL {
	RACSignal *applicationSupportURL = [[[RACSignal
		defer:^{
			NSError *error = nil;
			NSURL *directoryURL = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:&error];
			if (directoryURL == nil) {
				return [RACSignal error:error];
			}

			return [RACSignal return:directoryURL];
		}]
		map:^ (NSURL *directoryURL) {
			NSArray *pathComponents = [[@[ self.applicationIdentifier, @"com.github.Squirrel" ].rac_signal
				map:^(NSString *name) {
					return [self.class fileSystemNameForIdentifier:name];
				}]
				array];

			return [NSURL fileURLWithPathComponents:[directoryURL.pathComponents arrayByAddingObjectsFromArray:pathComponents]];
		}]
		setNameWithFormat:@"%@ -applicationSupportURL", self];
	return [self.class createDirectoryForURL:applicationSupportURL];
}

- (RACSignal *)downloadDirectoryURL {
	RACSignal *downloadDirectoryURL = [[[self
		applicationSupportURL]
		map:^(NSURL *directoryURL) {
			return [directoryURL URLByAppendingPathComponent:@"downloads"];
		}]
		setNameWithFormat:@"%@ -downloadDirectoryURL", self];
	return [self.class createDirectoryForURL:downloadDirectoryURL];
}

- (RACSignal *)uniqueUpdateDirectoryURL {
	return [[[[self
		applicationSupportURL]
		map:^ (NSURL *directoryURL) {
			// noindex so that Spotlight doesn't pick up apps pending update and
			// add them to the Launch Services database.
			return [[directoryURL URLByAppendingPathComponent:NSProcessInfo.processInfo.globallyUniqueString] URLByAppendingPathExtension:@"noindex"];
		}]
		tryMap:^ NSURL * (NSURL *directoryURL, NSError **errorRef) {
			// Explicitly just provide the owner with permission, discarding the
			// current umask. This matches the `mkdtemp` behaviour.
			NSDictionary *directoryAttributes = @{
				NSFilePosixPermissions: @(S_IRWXU),
			};
			if (![NSFileManager.defaultManager createDirectoryAtURL:directoryURL withIntermediateDirectories:YES attributes:directoryAttributes error:errorRef]) return nil;

			return directoryURL;
		}]
		setNameWithFormat:@"%@ -uniqueUpdateDirectoryURL", self];
}

- (RACSignal *)shipItStateURL {
	return [[[self
		applicationSupportURL]
		map:^(NSURL *folderURL) {
			return [folderURL URLByAppendingPathComponent:@"ShipItState.plist"];
		}]
		setNameWithFormat:@"%@ -shipItStateURL", self];
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
