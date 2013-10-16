//
//  SQRLZipArchiver.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-13.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLZipArchiver.h"
#import <ReactiveCocoa/EXTScope.h>
#import <ReactiveCocoa/ReactiveCocoa.h>

NSString * const SQRLZipArchiverErrorDomain = @"SQRLZipArchiverErrorDomain";
NSString * const SQRLZipArchiverExitCodeErrorKey = @"SQRLZipArchiverExitCodeErrorKey";
const NSInteger SQRLZipArchiverShellTaskFailed = 1;

@interface SQRLZipArchiver () {
	RACSubject *_taskTerminated;
}

// A configurable task responsible for launching `ditto`.
//
// This should be considered a one-shot object. Multiple operations should be
// represented by multiple `SQRLZipArchiver` instances.
@property (nonatomic, strong, readonly) NSTask *dittoTask;

// Sends the exit status of `dittoTask` when it has terminated.
@property (nonatomic, strong, readonly) RACSignal *taskTerminated;

// A pipe used for reading error logging from `dittoTask`.
@property (nonatomic, strong, readonly) NSPipe *standardErrorPipe;

// Sends an NSData representing the error logging from `dittoTask` once the task
// has terminated.
@property (nonatomic, strong, readonly) RACSignal *standardErrorData;

// Launches the receiver's `dittoTask` with the given command line arguments.
//
// Returns a signal which sends completed or error on an unspecified thread.
- (RACSignal *)launchWithArguments:(NSArray *)arguments;

@end

@implementation SQRLZipArchiver

#pragma mark Lifecycle

- (id)init {
	self = [super init];
	if (self == nil) return nil;

	_taskTerminated = [[RACSubject subject] setNameWithFormat:@"taskTerminated"];
	_standardErrorPipe = [[NSPipe alloc] init];

	_dittoTask = [[NSTask alloc] init];
	_dittoTask.launchPath = @"/usr/bin/ditto";
	_dittoTask.environment = @{ @"DITTOABORT": @1 };
	_dittoTask.standardError = self.standardErrorPipe;

	@weakify(self);
	_dittoTask.terminationHandler = ^(NSTask *task) {
		@strongify(self);
		if (self == nil) return;

		[self->_taskTerminated sendNext:@(task.terminationStatus)];
	};

	RACSubject *errorDataChunks = [[RACSubject subject] setNameWithFormat:@"errorDataChunks"];
	self.standardErrorPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
		[errorDataChunks sendNext:handle.availableData];
	};

	_standardErrorData = [[[[[[errorDataChunks
		takeUntil:self.taskTerminated]
		collect]
		flattenMap:^(NSArray *chunks) {
			NSMutableData *combined = [NSMutableData data];
			for (NSData *data in chunks) {
				[combined appendData:data];
			}

			return [RACSignal return:combined];
		}]
		repeat]
		takeUntil:self.rac_willDeallocSignal]
		setNameWithFormat:@"standardErrorData"];

	return self;
}

- (void)dealloc {
	[_taskTerminated sendCompleted];
	[self.standardErrorPipe.fileHandleForReading closeFile];
}

#pragma mark Archiving/Unarchiving

+ (RACSignal *)createZipArchiveAtURL:(NSURL *)zipArchiveURL fromDirectoryAtURL:(NSURL *)directoryURL {
	NSParameterAssert(zipArchiveURL != nil);
	NSParameterAssert([zipArchiveURL isFileURL]);
	NSParameterAssert(directoryURL != nil);
	NSParameterAssert([directoryURL isFileURL]);

	SQRLZipArchiver *archiver = [[self alloc] init];
	archiver.dittoTask.currentDirectoryPath = directoryURL.URLByDeletingLastPathComponent.path;

	return [[archiver
		launchWithArguments:@[ @"-ck", @"--keepParent", directoryURL.lastPathComponent, zipArchiveURL.path ]]
		setNameWithFormat:@"+createZipArchiveAtURL: %@ fromDirectoryAtURL: %@", zipArchiveURL, directoryURL];
}

+ (RACSignal *)unzipArchiveAtURL:(NSURL *)zipArchiveURL intoDirectoryAtURL:(NSURL *)directoryURL {
	NSParameterAssert(zipArchiveURL != nil);
	NSParameterAssert([zipArchiveURL isFileURL]);
	NSParameterAssert(directoryURL != nil);
	NSParameterAssert([directoryURL isFileURL]);

	SQRLZipArchiver *archiver = [[self alloc] init];
	return [[archiver
		launchWithArguments:@[ @"-xk", zipArchiveURL.path, directoryURL.path ]]
		setNameWithFormat:@"+unzipArchiveAtURL: %@ intoDirectoryAtURL: %@", zipArchiveURL, directoryURL];
}

#pragma mark Task Launching

- (RACSignal *)launchWithArguments:(NSArray *)arguments {
	RACSignal *signal = [[[[[[RACSignal
		// Ensures that `self` remains alive while this signal exists.
		//
		// This is important because the signals on `self` complete upon
		// dealloc.
		return:self]
		then:^{
			return [RACSignal
				zip:@[ self.taskTerminated, self.standardErrorData ]
				reduce:^(NSNumber *exitStatus, NSData *errorData) {
					if (exitStatus.intValue == 0) return [RACSignal empty];

					NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
					userInfo[SQRLZipArchiverExitCodeErrorKey] = exitStatus;

					NSString *errorString = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
					errorString = [errorString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
					if (errorString.length > 0) userInfo[NSLocalizedDescriptionKey] = errorString;

					return [RACSignal error:[NSError errorWithDomain:SQRLZipArchiverErrorDomain code:SQRLZipArchiverShellTaskFailed userInfo:userInfo]];
				}];
		}]
		take:1]
		flatten]
		replay]
		setNameWithFormat:@"-launchWithArguments: %@", arguments];

	self.dittoTask.arguments = arguments;
	[self.dittoTask launch];

	return signal;
}

@end
