//
//  SQRLUpdaterSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-07-21.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLZipArchiver.h"
#import "SQRLUpdate+Private.h"

SpecBegin(SQRLUpdater)

NSRunningApplication * (^launchWithMockUpdate)(NSURL *) = ^(NSURL *updateURL) {
	__block BOOL finished = NO;

	NSURL *zippedUpdateURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"update.zip"];
	[SQRLZipArchiver createZipArchiveAtURL:zippedUpdateURL fromDirectoryAtURL:updateURL completion:^(BOOL success) {
		expect(success).to.beTruthy();
		finished = YES;
	}];

	expect(finished).will.beTruthy();

	NSDictionary *updateInfo = @{
		SQRLUpdateJSONURLKey: zippedUpdateURL.absoluteString
	};

	NSError *error = nil;
	NSData *JSON = [NSJSONSerialization dataWithJSONObject:updateInfo options:NSJSONWritingPrettyPrinted error:&error];
	expect(JSON).notTo.beNil();
	expect(error).to.beNil();

	NSURL *JSONURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"update.json"];
	BOOL success = [JSON writeToURL:JSONURL options:NSDataWritingAtomic error:&error];
	expect(success).to.beTruthy();
	expect(error).to.beNil();

	NSDictionary *environment = @{
		@"SQRLUpdateFromURL": JSONURL.absoluteString
	};

	return [self launchTestApplicationWithEnvironment:environment];
};

it(@"should use the application's bundled version of Squirrel and update in-place", ^{
	NSURL *updateURL = [self createTestApplicationUpdate];
	NSRunningApplication *app = launchWithMockUpdate(updateURL);
	expect(app.terminated).will.beTruthy();
	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
});

it(@"should not install a corrupt update", ^{
	NSURL *updateURL = [self createTestApplicationUpdate];
	NSURL *codeSignatureURL = [updateURL URLByAppendingPathComponent:@"Contents/_CodeSignature"];
	expect([NSFileManager.defaultManager removeItemAtURL:codeSignatureURL error:NULL]).to.beTruthy();

	NSRunningApplication *app = launchWithMockUpdate(updateURL);
	expect(app.terminated).will.beTruthy();

	// Give the update some time to finish installing.
	[NSThread sleepForTimeInterval:0.2];
	expect(self.testApplicationBundleVersion).to.equal(SQRLTestApplicationOriginalShortVersionString);
});

SpecEnd
