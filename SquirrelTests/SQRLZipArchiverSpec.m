//
//  SQRLZipArchiverSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-13.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Nimble/Nimble.h>
#import <Quick/Quick.h>
#import <ReactiveCocoa/ReactiveCocoa.h>
#import <Squirrel/Squirrel.h>

#import "QuickSpec+SQRLFixtures.h"
#import "SQRLCodeSignature.h"
#import "SQRLZipArchiver.h"

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
