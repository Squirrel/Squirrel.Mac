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
	// Periods are problematic in the filesystem where they denote file type
	// a directory can become a package which can be undesirable.
	return [identifier stringByReplacingOccurrencesOfString:@"." withString:@"~"];
}

+ (RACSignal *)createDirectoryForURL:(RACSignal *)URLSignal {
	return [[URLSignal flattenMap:^ RACSignal * (NSURL *directory) {
		NSError *error = nil;
		BOOL create = [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error];
		if (!create) return [RACSignal error:error];

		return [RACSignal return:directory];
	}]
	setNameWithFormat:@"%@ +createDirectoryForURL: %@", self, URLSignal];
}

- (RACSignal *)applicationSupportURLNoCreate {
	return [[RACSignal
		defer:^{
			NSError *error = nil;
			NSURL *directoryURL = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:&error];
			if (directoryURL == nil) {
				return [RACSignal error:error];
			}

			directoryURL = [directoryURL URLByAppendingPathComponent:[self.class fileSystemNameForIdentifier:@"com.github.Squirrel"]];
			directoryURL = [directoryURL URLByAppendingPathComponent:[self.class fileSystemNameForIdentifier:self.applicationIdentifier]];

			return [RACSignal return:directoryURL];
		}]
		setNameWithFormat:@"%@ -applicationSupportURL", self];
}

- (RACSignal *)applicationSupportURL {
	return [self.class createDirectoryForURL:[self applicationSupportURLNoCreate]];
}

- (RACSignal *)downloadDirectoryURL {
	RACSignal *downloadDirectoryURL = [[[self
		applicationSupportURLNoCreate]
		map:^(NSURL *directoryURL) {
			return [directoryURL URLByAppendingPathComponent:@"download"];
		}]
		setNameWithFormat:@"%@ -downloadDirectoryURL", self];
	return [self.class createDirectoryForURL:downloadDirectoryURL];
}

- (RACSignal *)perUpdateDirectoryURL {
	return [[[self
		applicationSupportURLNoCreate]
		tryMap:^ NSURL * (NSURL *directoryURL, NSError **errorRef) {
			// noindex so that Spotlight doesn't pick up apps pending update and add
			// them to the Launch Services database
			NSURL *updateDirectory = [[directoryURL URLByAppendingPathComponent:NSProcessInfo.processInfo.globallyUniqueString] URLByAppendingPathExtension:@"noindex"];

			// Explicitly just provide the owner with permission, discarding the
			// current umask. This matches the `mkdtemp` behaviour.
			NSDictionary *directoryAttributes = @{
				NSFilePosixPermissions: @(S_IRWXU),
			};
			if (![NSFileManager.defaultManager createDirectoryAtURL:updateDirectory withIntermediateDirectories:YES attributes:directoryAttributes error:errorRef]) return nil;

			return updateDirectory;
		}]
		setNameWithFormat:@"%@ -perUpdateDirectoryURL", self];
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
