//
//  SQRLFileManager.m
//  Squirrel
//
//  Created by Keith Duncan on 26/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLFileManager.h"

@interface SQRLFileManager ()
@property (nonatomic, copy, readonly) NSString *appIdentifier;
@end

@implementation SQRLFileManager

+ (instancetype)fileManagerForCurrentApplication {
	NSString *identifier = nil;

	NSRunningApplication *currentApplication = NSRunningApplication.currentApplication;
	identifier = currentApplication.bundleIdentifier;

	if (identifier == nil) {
		NSDictionary *infoPlist = CFBridgingRelease(CFBundleCopyInfoDictionaryForURL((__bridge CFURLRef)currentApplication.bundleURL));
		identifier = infoPlist[(id)kCFBundleNameKey];
	}

	if (identifier == nil) {
		identifier = currentApplication.localizedName;
	}

	NSAssert(identifier != nil, @"could not automatically determine the current application identifier");

	return [[self alloc] initWithAppIdentifier:identifier];
}

- (instancetype)initWithAppIdentifier:(NSString *)appIdentifier {
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
	directory = [directory URLByAppendingPathComponent:subdirectoryName];
	[NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL];
	return directory;
}

- (NSURL *)URLForDownloadDirectory {
	return [self cacheSubdirectoryWithName:@"download"];
}

- (NSURL *)URLForUnpackDirectory {
	// noindex so that Spotlight doesn't pick up apps pending update
	return [self cacheSubdirectoryWithName:@"unpack.noindex"];
}

@end
