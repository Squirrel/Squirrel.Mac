//
//  SQRLZipArchiver.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-13.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLZipArchiver.h"
#import <ReactiveObjC/EXTScope.h>
#import <ReactiveObjC/ReactiveObjC.h>

NSString * const SQRLZipArchiverErrorDomain = @"SQRLZipArchiverErrorDomain";
NSString * const SQRLZipArchiverExitCodeErrorKey = @"SQRLZipArchiverExitCodeErrorKey";
const NSInteger SQRLZipArchiverShellTaskFailed = 1;

// `ditto` writes diagnostics for input it cannot process. Keep the retained
// untrusted output bounded so a failed archive operation cannot exhaust memory.
static const NSUInteger SQRLZipArchiverMaximumStandardErrorDataLength = 1024 * 1024;

static NSUInteger SQRLUTF8TruncationBoundary(const uint8_t *bytes, NSUInteger length) {
	NSUInteger codePointStart = length;
	while (codePointStart > 0 && (bytes[codePointStart - 1] & 0xC0) == 0x80) {
		codePointStart--;
	}

	if (codePointStart == 0) return 0;

	codePointStart--;
	uint8_t leadingByte = bytes[codePointStart];
	NSUInteger codePointLength = 1;
	if ((leadingByte & 0xE0) == 0xC0) {
		codePointLength = 2;
	} else if ((leadingByte & 0xF0) == 0xE0) {
		codePointLength = 3;
	} else if ((leadingByte & 0xF8) == 0xF0) {
		codePointLength = 4;
	}

	return codePointStart + codePointLength <= length ? length : codePointStart;
}

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

// Sends up to 1 MiB of error logging from `dittoTask` once the task has
// terminated.
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
	_dittoTask.environment = @{ @"DITTOABORT": @"1" };
	_dittoTask.standardError = self.standardErrorPipe;

	@weakify(self);
	_dittoTask.terminationHandler = ^(NSTask *task) {
		@strongify(self);
		if (self == nil) return;

		[self->_taskTerminated sendNext:@(task.terminationStatus)];
		[self.standardErrorPipe.fileHandleForReading closeFile];
	};

	RACSubject *errorDataChunks = [[RACSubject subject] setNameWithFormat:@"errorDataChunks"];
	self.standardErrorPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
		NSData *data = handle.availableData;
		if (data.length == 0) {
			handle.readabilityHandler = nil;
			return;
		}

		[errorDataChunks sendNext:data];
	};

	_standardErrorData = [[[[[[errorDataChunks
		takeUntil:self.taskTerminated]
		aggregateWithStartFactory:^id {
			return [@{
				@"data": [NSMutableData data],
				@"truncated": @NO,
			} mutableCopy];
		} reduce:^id(NSMutableDictionary *aggregate, NSData *data) {
			if ([aggregate[@"truncated"] boolValue]) {
				return aggregate;
			}

			NSMutableData *combined = aggregate[@"data"];
			NSUInteger remainingLength =
				SQRLZipArchiverMaximumStandardErrorDataLength - combined.length;
			NSUInteger appendLength = MIN(data.length, remainingLength);
			[combined appendBytes:data.bytes length:appendLength];

			if (appendLength < data.length) {
				combined.length = SQRLUTF8TruncationBoundary(combined.bytes, combined.length);
				aggregate[@"truncated"] = @YES;
			}

			return aggregate;
		}]
		map:^id(NSDictionary *aggregate) {
			return aggregate[@"data"];
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
					if (exitStatus.intValue == 0) return [RACSignal return:self];

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

	NSError *launchError = nil;

	if (![self.dittoTask launchAndReturnError:&launchError]) {
		NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
		userInfo[NSLocalizedDescriptionKey] = launchError.localizedDescription;

		NSLog(@"Starting ditto task failed with error: %@", launchError.localizedDescription);

		return [RACSignal error:[NSError errorWithDomain:SQRLZipArchiverErrorDomain code:SQRLZipArchiverShellTaskFailed userInfo:userInfo]];
	}

	return signal;
}

@end
