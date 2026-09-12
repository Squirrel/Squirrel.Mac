//
//  SQRLZipArchiverSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-13.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Nimble/Nimble.h>
#import <Quick/Quick.h>
#import <ReactiveObjC/ReactiveObjC.h>
#import <Squirrel/Squirrel.h>

#import "QuickSpec+SQRLFixtures.h"
#import "SQRLCodeSignature.h"
#import "SQRLZipArchiver.h"

@interface SQRLZipArchiver (SQRLTestingHooks)
@property (nonatomic, strong, readonly) NSTask *dittoTask;
- (RACSignal *)launchWithArguments:(NSArray *)arguments;
@end

QuickSpecBegin(SQRLZipArchiverSpec)

it(@"should extract a zip archive created by the Finder", ^{
	NSURL *zipURL = [[NSBundle bundleForClass:self.class] URLForResource:@"TestApplication.app" withExtension:@"zip"];

	NSError *error = nil;
	BOOL success = [[SQRLZipArchiver unzipArchiveAtURL:zipURL intoDirectoryAtURL:self.temporaryDirectoryURL] asynchronouslyWaitUntilCompleted:&error];
	expect(@(success)).to(beTruthy());
	expect(error).to(beNil());

	NSURL *extractedAppURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"TestApplication 2.1.app"];
	expect(@([NSFileManager.defaultManager fileExistsAtPath:extractedAppURL.path])).to(beTruthy());

	success = [[self.testApplicationSignature verifyBundleAtURL:extractedAppURL] waitUntilCompleted:&error];
	expect(@(success)).to(beTruthy());
	expect(error).to(beNil());
});

it(@"should error (not throw) when the ditto task fails to launch", ^{
	SQRLZipArchiver *archiver = [[SQRLZipArchiver alloc] init];
	archiver.dittoTask.launchPath = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"does-not-exist"].path;

	NSError *error = nil;
	BOOL success = [[archiver launchWithArguments:@[ @"-xk", @"/nope.zip", self.temporaryDirectoryURL.path ]] asynchronouslyWaitUntilCompleted:&error];

	expect(@(success)).to(beFalsy());
	expect(error.domain).to(equal(SQRLZipArchiverErrorDomain));
	expect(@(error.code)).to(equal(@(SQRLZipArchiverShellTaskFailed)));
	expect(error.userInfo[NSLocalizedDescriptionKey]).notTo(beNil());
});

it(@"should fail to extract a nonexistent zip archive", ^{
	NSError *error = nil;
	BOOL success = [[SQRLZipArchiver unzipArchiveAtURL:[self.temporaryDirectoryURL URLByAppendingPathComponent:@"foo.zip"] intoDirectoryAtURL:self.temporaryDirectoryURL] asynchronouslyWaitUntilCompleted:&error];
	expect(@(success)).to(beFalsy());

	NSLog(@"%@", error);

	expect(error).notTo(beNil());
	expect(error.domain).to(equal(SQRLZipArchiverErrorDomain));
	expect(@(error.code)).to(equal(@(SQRLZipArchiverShellTaskFailed)));
	expect(error.userInfo[SQRLZipArchiverExitCodeErrorKey]).notTo(equal(0));
});

it(@"should bound error output retained from a failed task", ^{
	SQRLZipArchiver *archiver = [[SQRLZipArchiver alloc] init];
	archiver.dittoTask.launchPath = @"/bin/sh";
	NSString *command = [NSString stringWithFormat:@"%@%@%@",
		@"/usr/bin/yes x | /usr/bin/head -c 1048575 >&2; ",
		@"printf '\\360\\237\\230\\200' >&2; ",
		@"/usr/bin/yes x | /usr/bin/head -c 1048576 >&2; exit 1"];

	NSError *error = nil;
	BOOL success = [[archiver
		launchWithArguments:@[
			@"-c",
			command,
		]]
		asynchronouslyWaitUntilCompleted:&error];

	expect(@(success)).to(beFalsy());
	expect(error.domain).to(equal(SQRLZipArchiverErrorDomain));

	NSString *errorString = error.userInfo[NSLocalizedDescriptionKey];
	expect(errorString).notTo(beNil());
	expect(@(errorString.length)).to(beGreaterThan(@(512 * 1024)));
	expect(@(errorString.length)).to(beLessThanOrEqualTo(@(1024 * 1024)));
});

it(@"should create a zip archive readable by itself", ^{
	NSURL *zipURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"TestApplication.zip"];

	NSError *error = nil;
	BOOL success = [[SQRLZipArchiver createZipArchiveAtURL:zipURL fromDirectoryAtURL:self.testApplicationURL] asynchronouslyWaitUntilCompleted:&error];
	expect(@(success)).to(beTruthy());
	expect(error).to(beNil());

	expect(@([NSFileManager.defaultManager fileExistsAtPath:zipURL.path])).to(beTruthy());

	success = [[SQRLZipArchiver unzipArchiveAtURL:zipURL intoDirectoryAtURL:self.temporaryDirectoryURL] asynchronouslyWaitUntilCompleted:&error];
	expect(@(success)).to(beTruthy());
	expect(error).to(beNil());

	NSURL *extractedAppURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"TestApplication.app"];
	expect(@([NSFileManager.defaultManager fileExistsAtPath:extractedAppURL.path])).to(beTruthy());

	success = [[self.testApplicationSignature verifyBundleAtURL:extractedAppURL] waitUntilCompleted:&error];
	expect(@(success)).to(beTruthy());
	expect(error).to(beNil());
});

QuickSpecEnd
