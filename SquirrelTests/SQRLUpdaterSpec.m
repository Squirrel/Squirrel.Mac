//
//  SQRLUpdaterSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-07-21.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLUpdater+Private.h"
#import "SSZipArchive.h"

SpecBegin(SQRLUpdater)

it(@"should be a thing", ^{
	SQRLUpdater *updater = SQRLUpdater.sharedUpdater;
	expect(updater).notTo.beNil();
});

pending(@"should download an update when it doesn't match the current version");

pending(@"should unzip an update");

pending(@"should verify the code signature of an update");

pending(@"should install the update on relaunch");

pending(@"should fail to install a corrupt update");

it(@"should use the application's bundled version of Squirrel and update in-place", ^{
	NSURL *updateURL = [self createTestApplicationUpdate];
	NSURL *zippedUpdateURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"update.zip"];
	expect([SSZipArchive createZipFileAtPath:zippedUpdateURL.path withContentsOfDirectory:updateURL.URLByDeletingLastPathComponent.path]).to.beTruthy();

	NSDictionary *updateInfo = @{
		SQRLUpdaterJSONURLKey: zippedUpdateURL.absoluteString
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

	NSRunningApplication *app = [self launchTestApplicationWithEnvironment:environment];
	expect(app.terminated).will.beTruthy();
	expect(self.testApplicationBundle.infoDictionary[SQRLBundleShortVersionStringKey]).to.equal(SQRLTestApplicationUpdatedShortVersionString);
});

SpecEnd
