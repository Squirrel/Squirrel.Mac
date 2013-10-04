//
//  SQRLZipArchiver.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-13.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLZipOperation.h"

#import "EXTKeyPathCoding.h"
#import "EXTScope.h"

NSString * const SQRLZipOperationErrorDomain = @"SQRLZipOperationErrorDomain";

@interface SQRLZipOperation ()
// Operation state
@property (nonatomic, assign) BOOL isExecuting;
// Operation state
@property (nonatomic, assign) BOOL isFinished;

typedef enum : NSInteger {
	SQRLZipArchiverTypeArchive,
	SQRLZipArchiverTypeUnarchive,
} SQRLZipArchiverType;
// Whether the operation was initialised as an archiver or unarchiver
@property (nonatomic, assign, readonly) SQRLZipArchiverType type;

// The ditto task's currentDirectory is set to this
@property (nonatomic, copy) NSURL *taskDirectory;
// The ditto task's arguments are set to this
@property (nonatomic, copy) NSArray *taskArguments;

// Serial queue for managing operation state
@property (nonatomic, strong) NSOperationQueue *controlQueue;

// A configurable task responsible for launching `ditto`.
@property (nonatomic, strong) NSTask *dittoTask;

@property (readwrite, copy, atomic) BOOL (^completionProvider)(NSError **errorRef);
@end

@implementation SQRLZipOperation

#pragma mark Lifecycle

- (id)initWithType:(SQRLZipArchiverType)type {
	self = [super init];
	if (self == nil) return nil;

	_type = type;

	_controlQueue = [[NSOperationQueue alloc] init];
	_controlQueue.maxConcurrentOperationCount = 1;
	_controlQueue.name = @"com.github.Squirrel.SQRLZipOperation.controlQueue";

	_completionProvider = [^ BOOL (NSError **errorRef) {
		if (errorRef != NULL) *errorRef = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
		return NO;
	} copy];

	return self;
}

+ (instancetype)createZipArchiveAtURL:(NSURL *)zipArchiveURL fromDirectoryAtURL:(NSURL *)directoryURL {
	NSParameterAssert(zipArchiveURL != nil);
	NSParameterAssert([zipArchiveURL isFileURL]);
	NSParameterAssert(directoryURL != nil);
	NSParameterAssert([directoryURL isFileURL]);

	SQRLZipOperation *archiver = [[self alloc] initWithType:SQRLZipArchiverTypeArchive];
	archiver.taskDirectory = directoryURL.URLByDeletingLastPathComponent;
	archiver.taskArguments = @[ @"-ck", @"--keepParent", directoryURL.lastPathComponent, zipArchiveURL.path ];
	return archiver;
}

+ (instancetype)unzipArchiveAtURL:(NSURL *)zipArchiveURL intoDirectoryAtURL:(NSURL *)directoryURL {
	NSParameterAssert(zipArchiveURL != nil);
	NSParameterAssert([zipArchiveURL isFileURL]);
	NSParameterAssert(directoryURL != nil);
	NSParameterAssert([directoryURL isFileURL]);

	SQRLZipOperation *archiver = [[self alloc] initWithType:SQRLZipArchiverTypeUnarchive];
	archiver.taskArguments = @[ @"-xk", zipArchiveURL.path, directoryURL.path ];
	return archiver;
}

#pragma mark Operation

- (BOOL)isConcurrent {
	return YES;
}

- (void)start {
	[self.controlQueue addOperationWithBlock:^{
		if (self.isCancelled) {
			[self finish];
			return;
		}

		[self willChangeValueForKey:@keypath(self, isExecuting)];
		self.isExecuting = YES;
		[self didChangeValueForKey:@keypath(self, isExecuting)];

		[self startTask];
	}];
}

- (void)cancel {
	[super cancel];

	[self.controlQueue addOperationWithBlock:^{
		if (self.dittoTask == nil) return;

		[self.dittoTask terminate];
		// Wait until the task terminates before going isFinished
	}];
}

- (void)finish {
	[self willChangeValueForKey:@keypath(self, isExecuting)];
	self.isExecuting = NO;
	[self didChangeValueForKey:@keypath(self, isExecuting)];

	[self willChangeValueForKey:@keypath(self, isFinished)];
	self.isFinished = YES;
	[self didChangeValueForKey:@keypath(self, isFinished)];
}

- (void)completeWithTerminationStatus:(int)terminationStatus {
	SQRLZipArchiverType type = self.type;

	self.completionProvider = ^ BOOL (NSError **errorRef) {
		if (terminationStatus != 0) {
			if (errorRef != NULL) {
				NSDictionary *errorInfo = @{
					NSLocalizedDescriptionKey: (type == SQRLZipArchiverTypeArchive ? NSLocalizedString(@"Couldn’t create the zip archive", nil) : NSLocalizedString(@"Couldn’t unarchive the zip contents", nil)),
				};
				*errorRef = [NSError errorWithDomain:SQRLZipOperationErrorDomain code:0 userInfo:errorInfo];
			}
			return NO;
		}

		return YES;
	};

	[self finish];
}

#pragma mark Task Launching

- (void)startTask {
	self.dittoTask = [[NSTask alloc] init];
	self.dittoTask.launchPath = @"/usr/bin/ditto";
	self.dittoTask.environment = @{ @"DITTOABORT": @1 };

	if (self.taskDirectory != nil) {
		self.dittoTask.currentDirectoryPath = self.taskDirectory.path;
	}
	if (self.taskArguments != nil) {
		self.dittoTask.arguments = self.taskArguments;
	}

	@weakify(self);
	self.dittoTask.terminationHandler = ^(NSTask *task) {
		@strongify(self);
		[self completeWithTerminationStatus:task.terminationStatus];
	};
	[self.dittoTask launch];
}

@end
