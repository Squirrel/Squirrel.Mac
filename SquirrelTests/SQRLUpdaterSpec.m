//
//  SQRLUpdaterSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-07-21.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Nimble/Nimble.h>
#import <Quick/Quick.h>
#import <ReactiveCocoa/ReactiveCocoa.h>
#import <Squirrel/Squirrel.h>

#import "SQRLTestUpdate.h"
#import "OHHTTPStubs/OHHTTPStubs.h"
#import "TestAppConstants.h"

SpecBegin(SQRLUpdaterSpec)

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

describe(@"updating", ^{
	__block NSURL *updateURL;

	beforeEach(^{
		updateURL = [self createTestApplicationUpdate];
	});

	it(@"should use the application's bundled version of Squirrel and update in-place", ^{
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

		update = [SQRLTestUpdate modelWithDictionary:@{
			@"updateURL": zipUpdate(updateURL),
			@"final": @YES
		} error:NULL];

		writeUpdate(update);

		expect(app.terminated).will.beTruthy();
		expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
	});

	it(@"should use the application's bundled version of Squirrel and update in-place after a significant delay", ^{
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

	describe(@"cleaning up", ^{
		__block NSURL *appSupportURL;
		__block RACSignal *updateDirectoryURLs;

		beforeEach(^{
			SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:@"com.github.Squirrel.TestApplication.ShipIt"];

			appSupportURL = [[directoryManager applicationSupportURL] first];
			expect(appSupportURL).notTo.beNil();

			updateDirectoryURLs = [[RACSignal
				defer:^{
					NSArray *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:appSupportURL includingPropertiesForKeys:nil options:0 error:NULL];
					if (contents == nil) return [RACSignal empty];

					return contents.rac_sequence.signal;
				}]
				filter:^(NSURL *directoryURL) {
					return [directoryURL.lastPathComponent hasPrefix:@"update."];
				}];
		});

		it(@"should remove downloaded archives after updating", ^{
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

			expect([updateDirectoryURLs toArray]).will.equal(@[]);
		});
	});
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
		BOOL result = [[updater.checkForUpdatesCommand execute:nil] asynchronouslyWaitUntilCompleted:&error];
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
		BOOL result = [[updater.checkForUpdatesCommand execute:nil] asynchronouslyWaitUntilCompleted:&error];
		expect(result).to.beFalsy();
		expect(error.domain).to.equal(SQRLUpdaterErrorDomain);
		expect(error.code).to.equal(SQRLUpdaterErrorInvalidServerBody);
	});
});

static RACSignal * (^stateNotificationListener)(void) = ^ {
	return [[[NSDistributedNotificationCenter.defaultCenter
		rac_addObserverForName:SQRLTestAppUpdaterStateTransitionNotificationName object:nil]
		map:^(NSNotification *notification) {
			return notification.userInfo[SQRLTestAppUpdaterStateKey];
		}]
		setNameWithFormat:@"stateNotificationListener"];
};

describe(@"state", ^{
	it(@"should transition through idle, checking and idle, when there is no update", ^{
		NSMutableArray *states = [NSMutableArray array];
		[stateNotificationListener() subscribeNext:^(NSNumber *state) {
			[states addObject:state];
		}];

		NSRunningApplication *testApplication = launchWithEnvironment(nil);

		NSArray *expectedStates = @[
			@(SQRLUpdaterStateIdle),
			@(SQRLUpdaterStateCheckingForUpdate),
			@(SQRLUpdaterStateIdle),
		];
		expect(states).will.equal(expectedStates);

		expect(testApplication.terminated).will.beTruthy();
	});

	it(@"should transition through idle, checking, downloading and awaiting relaunch, when there is an update", ^{
		NSMutableArray *states = [NSMutableArray array];
		[stateNotificationListener() subscribeNext:^(NSNumber *state) {
			[states addObject:state];
		}];

		NSError *error;
		SQRLTestUpdate *update = [SQRLTestUpdate modelWithDictionary:@{
			@"updateURL": zipUpdate([self createTestApplicationUpdate]),
			@"final": @YES,
		} error:&error];
		expect(update).notTo.beNil();
		expect(error).to.beNil();

		writeUpdate(update);

		NSRunningApplication *testApplication = launchWithEnvironment(nil);

		NSArray *expectedStates = @[
			@(SQRLUpdaterStateIdle),
			@(SQRLUpdaterStateCheckingForUpdate),
			@(SQRLUpdaterStateDownloadingUpdate),
			@(SQRLUpdaterStateAwaitingRelaunch),
		];
		expect(states).will.equal(expectedStates);

		expect(testApplication.terminated).will.beTruthy();
	});
});

SpecEnd
