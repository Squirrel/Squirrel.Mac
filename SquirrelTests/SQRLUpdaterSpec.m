//
//  SQRLUpdaterSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-07-21.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLTestUpdate.h"
#import "SQRLZipArchiver.h"
#import "OHHTTPStubs/OHHTTPStubs.h"
#import "SQRLDirectoryManager.h"
#import "SQRLURLConnection.h"
#import "SQRLDownloadManager.h"

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

	NSError *error = nil;
	SQRLTestUpdate *update = [SQRLTestUpdate modelWithDictionary:@{
		@"updateURL": zipUpdate(updateURL),
		@"final": @YES
	} error:&error];
	expect(update).notTo.beNil();
	expect(error).to.beNil();

	writeUpdate(update);

	NSRunningApplication *app = launchWithEnvironment(nil);
	expect(app.terminated).will.beTruthy();
	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
});

it(@"should not install a corrupt update", ^{
	NSURL *updateURL = [self createTestApplicationUpdate];
	NSURL *codeSignatureURL = [updateURL URLByAppendingPathComponent:@"Contents/_CodeSignature"];
	expect([NSFileManager.defaultManager removeItemAtURL:codeSignatureURL error:NULL]).to.beTruthy();

	SQRLTestUpdate *update = [SQRLTestUpdate modelWithDictionary:@{
		@"updateURL": zipUpdate(updateURL),
		@"final": @YES
	} error:NULL];

	writeUpdate(update);

	NSRunningApplication *app = launchWithEnvironment(nil);
	expect(app.terminated).will.beTruthy();

	// Give the update some time to finish installing.
	[NSThread sleepForTimeInterval:0.2];
	expect(self.testApplicationBundleVersion).to.equal(SQRLTestApplicationOriginalShortVersionString);
});

it(@"should update to the most recently enqueued job", ^{
	SQRLTestUpdate *update = [SQRLTestUpdate modelWithDictionary:@{
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
	update = [SQRLTestUpdate modelWithDictionary:@{
		@"updateURL": zipUpdate(updateURL),
		@"final": @YES
	} error:NULL];

	writeUpdate(update);

	expect(app.terminated).will.beTruthy();
	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
});

it(@"should use the application's bundled version of Squirrel and update in-place after a significant delay", ^{
	NSURL *updateURL = [self createTestApplicationUpdate];
	SQRLTestUpdate *update = [SQRLTestUpdate modelWithDictionary:@{
		@"updateURL": zipUpdate(updateURL),
		@"final": @YES
	} error:NULL];

	writeUpdate(update);

	NSTimeInterval delay = 30;
	NSRunningApplication *app = launchWithEnvironment(@{ @"SQRLUpdateDelay": [NSString stringWithFormat:@"%f", delay] });

	Expecta.asynchronousTestTimeout = delay + 3;
	expect(app.terminated).will.beTruthy();

	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
});

describe(@"response handling", ^{
	__block NSURLRequest *localRequest = nil;
	__block SQRLUpdater *updater = nil;

	before(^{
		localRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:@"fake://host/path"]];
		updater = [[SQRLUpdater alloc] initWithUpdateRequest:localRequest];
	});

	it(@"should return an error for non 2xx code HTTP responses", ^{
		OHHTTPStubs *stubs = [OHHTTPStubs shouldStubRequestsPassingTest:^(NSURLRequest *request) {
			return [request.URL isEqual:localRequest.URL];
		} withStubResponse:^(NSURLRequest *request) {
			return [OHHTTPStubsResponse responseWithData:nil statusCode:/* Server Error */ 500 responseTime:0 headers:nil];
		}];
		[self addCleanupBlock:^{
			[OHHTTPStubs removeRequestHandler:stubs];
		}];

		NSError *error = nil;
		BOOL result = [updater.checkForUpdatesAction.deferred asynchronouslyWaitUntilCompleted:&error];
		expect(result).to.beFalsy();
		expect(error.domain).to.equal(SQRLUpdaterErrorDomain);
		expect(error.code).to.equal(SQRLUpdaterErrorInvalidServerResponse);
	});

	it(@"should return an error for non JSON data", ^{
		OHHTTPStubs *stubs = [OHHTTPStubs shouldStubRequestsPassingTest:^(NSURLRequest *request) {
			return [request.URL isEqual:localRequest.URL];
		} withStubResponse:^(NSURLRequest *request) {
			return [OHHTTPStubsResponse responseWithData:NSData.data statusCode:/* OK */ 200 responseTime:0 headers:nil];
		}];
		[self addCleanupBlock:^{
			[OHHTTPStubs removeRequestHandler:stubs];
		}];

		NSError *error = nil;
		BOOL result = [updater.checkForUpdatesAction.deferred asynchronouslyWaitUntilCompleted:&error];
		expect(result).to.beFalsy();
		expect(error.domain).to.equal(SQRLUpdaterErrorDomain);
		expect(error.code).to.equal(SQRLUpdaterErrorInvalidServerBody);
	});
});

it(@"should clean up resumable downloads after a successful download", ^{
	SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:@"com.github.Squirrel.TestApplication"];
	SQRLDownloadManager *downloadManager = [[SQRLDownloadManager alloc] initWithDirectoryManager:directoryManager];

	NSError *error = nil;
	BOOL remove = [[downloadManager removeAllResumableDownloads] waitUntilCompleted:&error];
	expect(remove).to.beTruthy();
	expect(error).to.beNil();

	NSURL *updateApplicationBundle = [self createTestApplicationUpdate];

	NSURL *firstDownload = zipUpdate(updateApplicationBundle);
	SQRLURLConnection *connection = [[SQRLURLConnection alloc] initWithRequest:[NSURLRequest requestWithURL:firstDownload]];
	BOOL download = [[connection download:downloadManager] waitUntilCompleted:&error];
	expect(download).to.beTruthy();
	expect(error).to.beNil();

	NSURL *downloadDirectory = [[directoryManager downloadDirectoryURL] firstOrDefault:nil success:NULL error:&error];
	expect(downloadDirectory).notTo.beNil();
	expect(error).to.beNil();

	NSArray *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:downloadDirectory includingPropertiesForKeys:@[] options:0 error:&error];
	expect(contents.count).to.equal(1);

	SQRLTestUpdate *update = [[SQRLTestUpdate alloc] initWithDictionary:@{
		@"updateURL": zipUpdate(updateApplicationBundle),
		@"final": @YES,
	} error:NULL];

	writeUpdate(update);

	NSRunningApplication *app = launchWithEnvironment(nil);
	expect(app.terminated).will.beTruthy();
	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);

	contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:downloadDirectory includingPropertiesForKeys:@[] options:0 error:&error];
	if (contents == nil) {
		expect(error.domain).to.equal(NSCocoaErrorDomain);
		expect(error.code).to.equal(NSFileReadNoSuchFileError);
	} else {
		expect(contents.count).to.equal(0);
	}
});

it(@"should unpack update archives into a .noindex directory", ^{
	NSURL *zippedUpdateLocation = zipUpdate([self createTestApplicationUpdate]);

	SQRLTestUpdate *update = [[SQRLTestUpdate alloc] initWithDictionary:@{
		@keypath(update.updateURL): zippedUpdateLocation,
	} error:NULL];

	writeUpdate(update);

	__block SQRLDownloadedUpdate *downloadedUpdate;

	[[[[[NSDistributedNotificationCenter.defaultCenter
		rac_addObserverForName:@"com.github.Squirrel.TestApplication.updateReceived" object:nil]
		map:^(NSNotification *notification) {
			return notification.userInfo[@"update"];
		}]
		tryMap:^(NSString *serialisedUpdate, NSError **errorRef) {
			NSData *JSONData = [serialisedUpdate dataUsingEncoding:NSUTF8StringEncoding];
			return [NSJSONSerialization JSONObjectWithData:JSONData options:0 error:errorRef];
		}]
		tryMap:^(NSDictionary *JSONDictionary, NSError **errorRef) {
			return [MTLJSONAdapter modelOfClass:SQRLDownloadedUpdate.class fromJSONDictionary:JSONDictionary error:errorRef];
		}]
		subscribeNext:^(SQRLDownloadedUpdate *update) {
			downloadedUpdate = update;
		}];

	launchWithEnvironment(nil);

	expect(downloadedUpdate).willNot.beNil();

	NSURL *bundleURL = downloadedUpdate.bundle.bundleURL;
	expect([bundleURL.path rangeOfString:@".noindex"].location).notTo.equal(NSNotFound);
});

SpecEnd
