//
//  SQRLZipArchiver.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-13.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLZipArchiver.h"

typedef void (^SQRLZipArchiverCompletionHandler)(BOOL success);

@interface SQRLZipArchiver ()

// A configurable task responsible for launching `ditto`.
@property (nonatomic, strong, readonly) NSTask *dittoTask;

@end

@implementation SQRLZipArchiver

#pragma mark Lifecycle

- (id)initWithCompletionHandler:(SQRLZipArchiverCompletionHandler)completionHandler {
	NSParameterAssert(completionHandler != nil);

	self = [super init];
	if (self == nil) return nil;

	_dittoTask = [[NSTask alloc] init];
	_dittoTask.launchPath = @"/usr/bin/ditto";
	_dittoTask.environment = @{ @"DITTOABORT": @1 };
	_dittoTask.terminationHandler = ^(NSTask *task) {
		completionHandler((task.terminationStatus == 0));
	};

	return self;
}

+ (void)createZipArchiveAtURL:(NSURL *)zipArchiveURL fromDirectoryAtURL:(NSURL *)directoryURL completion:(void (^)(BOOL success))completionHandler {
	NSParameterAssert(zipArchiveURL != nil);
	NSParameterAssert([zipArchiveURL isFileURL]);
	NSParameterAssert(directoryURL != nil);
	NSParameterAssert([directoryURL isFileURL]);

	SQRLZipArchiver *archiver = [[self alloc] initWithCompletionHandler:completionHandler];
	archiver.dittoTask.currentDirectoryPath = directoryURL.URLByDeletingLastPathComponent.path;
	[archiver launchWithArguments:@[ @"-ck", @"--keepParent", directoryURL.lastPathComponent, zipArchiveURL.path ]];
}

+ (void)unzipArchiveAtURL:(NSURL *)zipArchiveURL intoDirectoryAtURL:(NSURL *)directoryURL completion:(void (^)(BOOL success))completionHandler {
	NSParameterAssert(zipArchiveURL != nil);
	NSParameterAssert([zipArchiveURL isFileURL]);
	NSParameterAssert(directoryURL != nil);
	NSParameterAssert([directoryURL isFileURL]);

	SQRLZipArchiver *archiver = [[self alloc] initWithCompletionHandler:completionHandler];
	[archiver launchWithArguments:@[ @"-xk", zipArchiveURL.path, directoryURL.path ]];
}

#pragma mark Task Launching

- (void)launchWithArguments:(NSArray *)arguments {
	self.dittoTask.arguments = arguments;
	[self.dittoTask launch];

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		// This blocking isn't actually necessary, but we don't want the task to
		// deallocate before it finishes.
		[self.dittoTask waitUntilExit];
	});
}

@end
