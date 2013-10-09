//
//  SQRLUpdaterSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-07-21.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLZipArchiver.h"

SpecBegin(SQRLUpdater)

__block NSURL *JSONURL;

void (^writeUpdate)(SQRLUpdate *) = ^(SQRLUpdate *update) {
	NSDictionary *updateInfo = [MTLJSONAdapter JSONDictionaryFromModel:update];
	expect(updateInfo).notTo.beNil();

	NSError *error = nil;
	NSData *JSON = [NSJSONSerialization dataWithJSONObject:updateInfo options:NSJSONWritingPrettyPrinted error:&error];
	expect(JSON).notTo.beNil();
	expect(error).to.beNil();

	BOOL success = [JSON writeToURL:JSONURL options:NSDataWritingAtomic error:&error];
	expect(success).to.beTruthy();
	expect(error).to.beNil();
};

NSURL * (^zipUpdate)(NSURL *) = ^(NSURL *updateURL) {
	NSURL *zipFolderURL = [NSFileManager.defaultManager URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:self.temporaryDirectoryURL create:YES error:NULL];
	expect(zipFolderURL).notTo.beNil();

	NSURL *zippedUpdateURL = [[zipFolderURL URLByAppendingPathComponent:updateURL.lastPathComponent] URLByAppendingPathExtension:@"zip"];
	BOOL success = [[SQRLZipArchiver createZipArchiveAtURL:zippedUpdateURL fromDirectoryAtURL:updateURL] asynchronouslyWaitUntilCompleted:NULL];
	expect(success).to.beTruthy();

	return zippedUpdateURL;
};

NSRunningApplication * (^launchWithEnvironment)(NSDictionary *) = ^(NSDictionary *moreEnvironment) {
	NSMutableDictionary *environment = [moreEnvironment mutableCopy] ?: [NSMutableDictionary dictionary];
	environment[@"SQRLUpdateFromURL"] = JSONURL.absoluteString;

	return [self launchTestApplicationWithEnvironment:environment];
};

beforeEach(^{
	JSONURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"update.json"];
});

it(@"should use the application's bundled version of Squirrel and update in-place", ^{
	NSURL *updateURL = [self createTestApplicationUpdate];
	SQRLUpdate *update = [SQRLUpdate modelWithDictionary:@{
		@"updateURL": zipUpdate(updateURL),
		@"releaseName": @"Final"
	} error:NULL];

	writeUpdate(update);

	NSRunningApplication *app = launchWithEnvironment(nil);
	expect(app.terminated).will.beTruthy();
	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
});

it(@"should not install a corrupt update", ^{
	NSURL *updateURL = [self createTestApplicationUpdate];
	NSURL *codeSignatureURL = [updateURL URLByAppendingPathComponent:@"Contents/_CodeSignature"];
	expect([NSFileManager.defaultManager removeItemAtURL:codeSignatureURL error:NULL]).to.beTruthy();

	SQRLUpdate *update = [SQRLUpdate modelWithDictionary:@{
		@"updateURL": zipUpdate(updateURL),
		@"releaseName": @"Final"
	} error:NULL];

	writeUpdate(update);

	NSRunningApplication *app = launchWithEnvironment(nil);
	expect(app.terminated).will.beTruthy();

	// Give the update some time to finish installing.
	[NSThread sleepForTimeInterval:0.2];
	expect(self.testApplicationBundleVersion).to.equal(SQRLTestApplicationOriginalShortVersionString);
});

it(@"should update to the most recently enqueued job", ^{
	SQRLUpdate *update = [SQRLUpdate modelWithDictionary:@{
		@"updateURL": zipUpdate(self.testApplicationURL)
	} error:NULL];

	writeUpdate(update);

	NSRunningApplication *app = launchWithEnvironment(nil);

	// Now that Test Application is launched, it's going to keep checking the
	// JSON URL until it has the proper release name. So we'll wait a short bit,
	// and then add the correct name in.
	//
	// This exercises ShipIt's ability to discard previous commands and
	// install an even newer update.
	[NSThread sleepForTimeInterval:0.3];

	NSURL *updateURL = [self createTestApplicationUpdate];
	update = [SQRLUpdate modelWithDictionary:@{
		@"updateURL": zipUpdate(updateURL),
		@"releaseName": @"Final"
	} error:NULL];

	writeUpdate(update);

	expect(app.terminated).will.beTruthy();
	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
});

it(@"should use the application's bundled version of Squirrel and update in-place after a long time", ^{
	NSURL *updateURL = [self createTestApplicationUpdate];
	SQRLUpdate *update = [SQRLUpdate modelWithDictionary:@{
		@"updateURL": zipUpdate(updateURL),
		@"releaseName": @"Final"
	} error:NULL];

	writeUpdate(update);

	NSTimeInterval delay = 60;
	NSRunningApplication *app = launchWithEnvironment(@{ @"SQRLUpdateDelay": [NSString stringWithFormat:@"%f", delay] });

	Expecta.asynchronousTestTimeout = delay + 3;
	expect(app.terminated).will.beTruthy();

	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
});

SpecEnd
