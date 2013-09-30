//
//  SQRLFileManager.m
//  Squirrel
//
//  Created by Keith Duncan on 26/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDirectoryManager.h"

@interface SQRLDirectoryManager ()
@property (nonatomic, copy, readonly) NSString *appIdentifier;
@end

@implementation SQRLDirectoryManager

+ (instancetype)directoryManagerForCurrentApplication {
	NSString *identifier = NSBundle.mainBundle.bundleIdentifier ?: [NSBundle.mainBundle objectForInfoDictionaryKey:(__bridge NSString *)kCFBundleNameKey];

	// Should only fallback to when running under otest where
	// NSBundle.mainBundle doesn't return useful data
	if (identifier == nil) {
		NSRunningApplication *currentApplication = NSRunningApplication.currentApplication;
		identifier = currentApplication.localizedName;
	}

	NSAssert(identifier != nil, @"could not automatically determine the current application identifier");

	return [[self alloc] initWithAppIdentifier:identifier];
}

- (instancetype)initWithAppIdentifier:(NSString *)appIdentifier {
	NSParameterAssert(appIdentifier != nil);

	self = [self init];
	if (self == nil) return nil;

	_appIdentifier = [appIdentifier copy];

	return self;
}

+ (NSURL *)cacheDirectory {
	NSURL *cacheDirectory = [NSFileManager.defaultManager URLForDirectory:NSCachesDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:NULL];
	return [cacheDirectory URLByAppendingPathComponent:@"com~github~Squirrel"];
}

- (NSURL *)cacheSubdirectoryWithName:(NSString *)subdirectoryName {
	NSURL *directory = self.class.cacheDirectory;
	directory = [directory URLByAppendingPathComponent:[self.appIdentifier stringByReplacingOccurrencesOfString:@"." withString:@"~"]];
	if (subdirectoryName != nil) directory = [directory URLByAppendingPathComponent:subdirectoryName];
	return directory;
}

- (NSURL *)URLForContainerDirectory {
	return [self cacheSubdirectoryWithName:nil];
}

- (NSURL *)URLForDownloadDirectory {
	return [self cacheSubdirectoryWithName:@"download"];
}

- (NSURL *)URLForUnpackDirectory {
	// noindex so that Spotlight doesn't pick up apps pending update and add
	// them to the Launch Services database
	return [self cacheSubdirectoryWithName:@"unpack.noindex"];
}

@end
