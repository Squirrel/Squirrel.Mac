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

__block NSURL *JSONURL;

void (^writeUpdateInfo)(NSDictionary *) = ^(NSDictionary *updateInfo) {
	NSError *error = nil;
	NSData *JSON = [NSJSONSerialization dataWithJSONObject:updateInfo options:NSJSONWritingPrettyPrinted error:&error];
	expect(JSON).notTo.beNil();
	expect(error).to.beNil();

	BOOL success = [JSON writeToURL:JSONURL options:NSDataWritingAtomic error:&error];
	expect(success).to.beTruthy();
	expect(error).to.beNil();
};

NSRunningApplication * (^launchWithMockUpdates)(NSURL *) = ^(NSURL *updateURL) {
	NSURL *zippedUpdateURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"update.zip"];
	BOOL success = [[SQRLZipArchiver createZipArchiveAtURL:zippedUpdateURL fromDirectoryAtURL:updateURL] asynchronouslyWaitUntilCompleted:NULL];
	expect(success).to.beTruthy();

	NSMutableDictionary *updateInfo = [NSMutableDictionary dictionary];
	updateInfo[SQRLUpdateJSONURLKey] = zippedUpdateURL.absoluteString;
	writeUpdateInfo(updateInfo);

	NSDictionary *environment = @{
		@"SQRLUpdateFromURL": JSONURL.absoluteString
	};

	NSRunningApplication *app = [self launchTestApplicationWithEnvironment:environment];

	// Now that Test Application is launched, it's going to keep checking the
	// JSON URL until it has the proper release name. So we'll wait a short bit,
	// and then add the correct name in.
	//
	// This exercises ShipIt's ability to discard previous commands and
	// install an even newer update.
	[NSThread sleepForTimeInterval:0.3];

	updateInfo[SQRLUpdateJSONNameKey] = @"Final";
	writeUpdateInfo(updateInfo);

	return app;
};

beforeEach(^{
	JSONURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"update.json"];
});

it(@"should use the application's bundled version of Squirrel and update in-place", ^{
	NSURL *updateURL = [self createTestApplicationUpdate];
	NSRunningApplication *app = launchWithMockUpdates(updateURL);
	expect(app.terminated).will.beTruthy();
	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
});

it(@"should not install a corrupt update", ^{
	NSURL *updateURL = [self createTestApplicationUpdate];
	NSURL *codeSignatureURL = [updateURL URLByAppendingPathComponent:@"Contents/_CodeSignature"];
	expect([NSFileManager.defaultManager removeItemAtURL:codeSignatureURL error:NULL]).to.beTruthy();

	NSRunningApplication *app = launchWithMockUpdates(updateURL);
	expect(app.terminated).will.beTruthy();

	// Give the update some time to finish installing.
	[NSThread sleepForTimeInterval:0.2];
	expect(self.testApplicationBundleVersion).to.equal(SQRLTestApplicationOriginalShortVersionString);
});

SpecEnd
