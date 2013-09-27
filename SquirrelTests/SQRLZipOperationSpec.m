//
//  SQRLZipArchiverSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-13.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLCodeSignatureVerifier.h"
#import "SQRLZipOperation.h"

SpecBegin(SQRLZipOperation)

it(@"should extract a zip archive created by the Finder", ^{
	NSURL *zipURL = [[NSBundle bundleForClass:self.class] URLForResource:@"TestApplication.app" withExtension:@"zip"];

	SQRLZipOperation *operation = [SQRLZipOperation unzipArchiveAtURL:zipURL intoDirectoryAtURL:self.temporaryDirectoryURL];
	[operation start];
	expect(operation.isFinished).will.beTruthy();

	NSError *error = nil;
	BOOL result = operation.completionProvider(&error);
	expect(result).to.beTruthy();
	expect(error).to.beNil();

	NSURL *extractedAppURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"TestApplication 2.1.app"];
	expect([NSFileManager.defaultManager fileExistsAtPath:extractedAppURL.path]).to.beTruthy();

	BOOL success = [self.testApplicationVerifier verifyCodeSignatureOfBundle:extractedAppURL error:&error];
	expect(success).to.beTruthy();
	expect(error).to.beNil();
});

it(@"should create a zip archive readable by itself", ^{
	NSURL *zipURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"TestApplication.zip"];

	SQRLZipOperation *zip = [SQRLZipOperation createZipArchiveAtURL:zipURL fromDirectoryAtURL:self.testApplicationURL];
	[zip start];
	expect(zip.isFinished).will.beTruthy();

	NSError *error = nil;
	BOOL result = zip.completionProvider(&error);
	expect(result).to.beTruthy();
	expect(error).to.beNil();

	expect([NSFileManager.defaultManager fileExistsAtPath:zipURL.path]).to.beTruthy();

	SQRLZipOperation *unzip = [SQRLZipOperation unzipArchiveAtURL:zipURL intoDirectoryAtURL:self.temporaryDirectoryURL];
	[unzip start];
	expect(unzip.isFinished).will.beTruthy();

	result = unzip.completionProvider(&error);
	expect(result).to.beTruthy();
	expect(error).to.beNil();

	NSURL *extractedAppURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"TestApplication.app"];
	expect([NSFileManager.defaultManager fileExistsAtPath:extractedAppURL.path]).to.beTruthy();

	BOOL success = [self.testApplicationVerifier verifyCodeSignatureOfBundle:extractedAppURL error:&error];
	expect(success).to.beTruthy();
	expect(error).to.beNil();
});

SpecEnd
