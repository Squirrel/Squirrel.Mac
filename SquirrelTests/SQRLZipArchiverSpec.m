//
//  SQRLZipArchiverSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-13.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLCodeSignatureVerifier.h"
#import "SQRLZipArchiver.h"

SpecBegin(SQRLZipArchiver)

it(@"should extract a zip archive created by the Finder", ^{
	NSURL *zipURL = [[NSBundle bundleForClass:self.class] URLForResource:@"TestApplication.app" withExtension:@"zip"];

	__block BOOL finished = NO;
	[SQRLZipArchiver unzipArchiveAtURL:zipURL intoDirectoryAtURL:self.temporaryDirectoryURL completion:^(BOOL success) {
		expect(success).to.beTruthy();
		finished = YES;
	}];

	expect(finished).will.beTruthy();

	NSURL *extractedAppURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"TestApplication 2.1.app"];
	expect([NSFileManager.defaultManager fileExistsAtPath:extractedAppURL.path]).to.beTruthy();

	NSError *error = nil;
	BOOL success = [self.testApplicationVerifier verifyCodeSignatureOfBundle:extractedAppURL error:&error];
	expect(success).to.beTruthy();
	expect(error).to.beNil();
});

it(@"should create a zip archive readable by itself", ^{
	NSURL *zipURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"TestApplication.zip"];

	__block BOOL finished = NO;
	[SQRLZipArchiver createZipArchiveAtURL:zipURL fromDirectoryAtURL:self.testApplicationURL completion:^(BOOL success) {
		expect(success).to.beTruthy();
		finished = YES;
	}];

	expect(finished).will.beTruthy();
	expect([NSFileManager.defaultManager fileExistsAtPath:zipURL.path]).to.beTruthy();

	finished = NO;
	[SQRLZipArchiver unzipArchiveAtURL:zipURL intoDirectoryAtURL:self.temporaryDirectoryURL completion:^(BOOL success) {
		expect(success).to.beTruthy();
		finished = YES;
	}];

	expect(finished).will.beTruthy();

	NSURL *extractedAppURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"TestApplication.app"];
	expect([NSFileManager.defaultManager fileExistsAtPath:extractedAppURL.path]).to.beTruthy();

	NSError *error = nil;
	BOOL success = [self.testApplicationVerifier verifyCodeSignatureOfBundle:extractedAppURL error:&error];
	expect(success).to.beTruthy();
	expect(error).to.beNil();
});

SpecEnd
