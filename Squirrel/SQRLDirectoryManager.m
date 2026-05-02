//
//  SQRLDirectoryManager.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-08.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDirectoryManager.h"

#import <ReactiveObjC/RACSignal+Operations.h>

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

// Returns a signal to a URL with the given filename and job name inside of the storage folder
//
// filename - The name of the file in the storage folder to return in this URL
// jobname - The name to give the returned RACSignal
// ensureWritable - If set to true, we will append an integer to the end of the filename in order to find a writeable URL.
// 		This fixes an issue wherein the stdout and stderr files may have been owned by root, and thus prevented ShipIt from launching.
- (RACSignal *)URLForFileNamed:(NSString *)filename withJobNamed:(NSString *)jobname ensureWritable:(BOOL)ensureWritable {
	return [[[self
			  storageURL]
			 map:^(NSURL *folderURL) {
				 NSURL *fileURL = [folderURL URLByAppendingPathComponent:filename];
				 if (ensureWritable) {

					 int attempts = 0;
					 while (attempts < 100) {

						 NSNumber *writable = nil;
						 NSError *writableError = nil;
						 BOOL gotWritable = [fileURL getResourceValue:&writable forKey:NSURLIsWritableKey error:&writableError];

						 if (!gotWritable || writable.boolValue) {
							 return fileURL;
						 }

						 attempts++;
						 fileURL = [folderURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.%i", filename, attempts]];
					 }
					 
					 NSLog(@"Error: Unable to find writable log file after 100 attempts.");
				 }

				 return fileURL;
			 }]
			setNameWithFormat:@"%@ -%@", self, jobname];
}

- (RACSignal *)shipItStateURL {
	return [self URLForFileNamed:@"ShipItState.plist" withJobNamed:@"shipItStateURL" ensureWritable:false];
}

- (RACSignal *)shipItStdoutURL {
	return [self URLForFileNamed:@"ShipIt_stdout.log" withJobNamed:@"shipItStdoutURL" ensureWritable:true];
}

- (RACSignal *)shipItStderrURL {
	return [self URLForFileNamed:@"ShipIt_stderr.log" withJobNamed:@"shipItStderrURL" ensureWritable:true];
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
