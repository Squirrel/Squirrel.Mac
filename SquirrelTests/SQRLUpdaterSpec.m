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

#import "SQRLDirectoryManager.h"
#import "SQRLUpdater.h"
#import "SQRLZipArchiver.h"

#import "OHHTTPStubs/OHHTTPStubs.h"
#import "QuickSpec+SQRLFixtures.h"
#import "SQRLTestUpdate.h"
#import "TestAppConstants.h"
#import <objc/objc-class.h>

//! force Updater to believe we are not on readonly, to continue downloading the release
bool isRunningOnReadOnlyVolumeImp(id self, SEL _cmd)
{
	return false;
}

//! we don't want updateFromJSONData to be executed. It is enough to know if it was called
bool updateFromJSONDataIsCalled = false;
RACSignal * updateFromJSONDataImp(id self, SEL _cmd, NSData * data)
{
	NSString* str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

	NSLog(@"updateFromJSONDataImp called with %@", str);
	updateFromJSONDataIsCalled = true;
	return false;
}

QuickSpecBegin(SQRLUpdaterSpec)

__block NSURL *JSONURL;

void (^writeUpdate)(SQRLUpdate *) = ^(SQRLUpdate *update) {
	NSDictionary *updateInfo = [MTLJSONAdapter JSONDictionaryFromModel:update];
	expect(updateInfo).notTo(beNil());

	NSError *error = nil;
	NSData *JSON = [NSJSONSerialization dataWithJSONObject:updateInfo options:NSJSONWritingPrettyPrinted error:&error];
	expect(JSON).notTo(beNil());
	expect(error).to(beNil());

	BOOL success = [JSON writeToURL:JSONURL options:NSDataWritingAtomic error:&error];
	expect(@(success)).to(beTruthy());
	expect(error).to(beNil());
};

NSURL * (^zipUpdate)(NSURL *) = ^(NSURL *updateURL) {
	NSURL *zipFolderURL = [NSFileManager.defaultManager URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:self.temporaryDirectoryURL create:YES error:NULL];
	expect(zipFolderURL).notTo(beNil());

	NSURL *zippedUpdateURL = [[zipFolderURL URLByAppendingPathComponent:updateURL.lastPathComponent] URLByAppendingPathExtension:@"zip"];
	BOOL success = [[SQRLZipArchiver createZipArchiveAtURL:zippedUpdateURL fromDirectoryAtURL:updateURL] asynchronouslyWaitUntilCompleted:NULL];
	expect(@(success)).to(beTruthy());

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


describe(@"checkForUpdatesCommand", ^{

	/** 
	 control test behavior via env variables:
	 
	 SQUIRREL_TEST_LOCAL_SERVER=True
	 SQUIRREL_LOCAL_SERVER_URL=http://localhost:8123/update/osx/1.0.1-stable/stable
	 SQUIRREL_TEST_LOCAL_CDN=True
	 SQUIRREL_CDN_URL=@"http://localhost/RELEASES.json"

	 */

	OHHTTPStubs *stubsJson = [OHHTTPStubs shouldStubRequestsPassingTest:^(NSURLRequest *request) {
		return [request.URL.absoluteString isEqualToString:@"http://localhost/RELEASES.json?method=Json"];
	} withStubResponse:^(NSURLRequest *request) {
		NSDictionary *newReleaseJSON = @{
										 @"version": @"0.0.145",
										 @"name": @"my-stub-release",
										 @"notes": @"mock release for automated tests, json",
										 @"pub_date": @"2017-03-09T15:24:55-05:00",
										 @"url": @"http://localhost/myapp-0.0.145.zip"
										 };

		NSError * err;
		NSData * jsonData = [NSJSONSerialization  dataWithJSONObject:newReleaseJSON options:0 error:&err];

		return [OHHTTPStubsResponse responseWithData:jsonData statusCode:200 responseTime:0 headers:nil];
	}];

	OHHTTPStubs *stubsReleaseServer = [OHHTTPStubs shouldStubRequestsPassingTest:^(NSURLRequest *request) {
		return [request.URL.absoluteString isEqualToString:@"http://localhost:8123/update/osx/1.0.1-stable/stable?method=ReleaseServer"];
	} withStubResponse:^(NSURLRequest *request) {
		NSDictionary *newReleaseJSON = @{
										 @"version": @"0.0.145",
										 @"name": @"my-stub-release",
										 @"notes": @"mock release for automated tests, release server",
										 @"pub_date": @"2017-03-09T15:24:55-05:00",
										 @"url": @"http://localmyappng-0.0.145.zip"
										 };

		NSError * err;
		NSData * jsonData = [NSJSONSerialization  dataWithJSONObject:newReleaseJSON options:0 error:&err];

		return [OHHTTPStubsResponse responseWithData:jsonData statusCode:200 responseTime:0 headers:nil];
	}];

	[self addCleanupBlock:^{
		[OHHTTPStubs removeRequestHandler:stubsJson];
		[OHHTTPStubs removeRequestHandler:stubsReleaseServer];
	}];

	BOOL testLocalServer = [[[[NSProcessInfo processInfo]environment]objectForKey:@"SQUIRREL_TEST_LOCAL_SERVER"] boolValue];
	NSString* localServerURL = [[[NSProcessInfo processInfo]environment]objectForKey:@"SQUIRREL_LOCAL_SERVER_URL"];
	if(!localServerURL) {
		localServerURL = @"http://localhost:8123/update/osx/1.0.1-stable/stable?method=ReleaseServer";
	}
	BOOL testLocalCdn = [[[[NSProcessInfo processInfo]environment]objectForKey:@"SQUIRREL_TEST_LOCAL_CDN"] boolValue];
	NSString* localCdnURL = [[[NSProcessInfo processInfo]environment]objectForKey:@"SQUIRREL_CDN_URL"];
	if(!localCdnURL) {
		localCdnURL = @"http://localhost/RELEASES.json?method=Json";
	}

	NSLog(@"testLocalServer %d %@", testLocalServer, localServerURL);
	NSLog(@"testLocalCdn %d %@", testLocalCdn, localCdnURL);

	__block SQRLUpdater *updater = nil;
	__block NSURLRequest *localRequest = nil;

	it(@"Squirrel should work with a release server", ^{
		
		if(testLocalServer) {

			updateFromJSONDataIsCalled = false;
			
			//! setup the updater
			localRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:localServerURL]];
			updater = [[SQRLUpdater alloc] initWithUpdateRequest:localRequest];
			
			//! replace updateFromJSONData() and isRunningOnReadOnlyVolume() methods
			method_setImplementation(class_getInstanceMethod([SQRLUpdater class]
															 , @selector(updateFromJSONData:))
									 , (IMP) updateFromJSONDataImp);
			
			method_setImplementation(class_getInstanceMethod([SQRLUpdater class]
															 , @selector(isRunningOnReadOnlyVolume))
									 , (IMP) isRunningOnReadOnlyVolumeImp);
			
			NSError *error = nil;
			BOOL result = [[updater.checkForUpdatesCommand execute:nil] asynchronouslyWaitUntilCompleted:&error];
			
			//! now check the results
			expect((int)updater.state).toEventually(equal((int)SQRLUpdaterStateIdle));
			expect( (BOOL) updateFromJSONDataIsCalled ).to(beTrue());
			expect( (BOOL) result ).to(beTrue());
		}
	});

	it(@"Squirrel should work with a CDN", ^{

		if(testLocalCdn) {
			updateFromJSONDataIsCalled = false;
			
			//! setup the updater
			localRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:localCdnURL]];
			updater = [[SQRLUpdater alloc] initWithUpdateRequest:localRequest];
			
			//! replace updateFromJSONData() and isRunningOnReadOnlyVolume() methods
			method_setImplementation(class_getInstanceMethod([SQRLUpdater class]
															 , @selector(updateFromJSONData:))
									 , (IMP) updateFromJSONDataImp);

			method_setImplementation(class_getInstanceMethod([SQRLUpdater class]
															 , @selector(isRunningOnReadOnlyVolume))
									 , (IMP) isRunningOnReadOnlyVolumeImp);
			
			NSError *error = nil;
			BOOL result = [[updater.checkForUpdatesCommand execute:nil] asynchronouslyWaitUntilCompleted:&error];
			
			//! now check the results
			expect((int)updater.state).toEventually(equal((int)SQRLUpdaterStateIdle));
			expect( (BOOL) updateFromJSONDataIsCalled ).to(beTrue());
			expect( (BOOL) result ).to(beTrue());
		}
	});

});

describe(@"updating", ^{
	__block NSURL *updateURL;

	beforeEach(^{
		updateURL = [self createTestApplicationUpdate];
	});

	it(@"should use the application's bundled version of Squirrel and update in-place", ^{
		SKIP_IF_RUNNING_ON_TRAVIS

		NSError *error = nil;
		SQRLTestUpdate *update = [SQRLTestUpdate modelWithDictionary:@{
			@"updateURL": zipUpdate(updateURL),
			@"final": @YES
		} error:&error];
		expect(update).notTo(beNil());
		expect(error).to(beNil());

		writeUpdate(update);

		NSRunningApplication *app = launchWithEnvironment(nil);
		expect(@(app.terminated)).withTimeout(SQRLLongTimeout).toEventually(beTruthy());
		expect(self.testApplicationBundleVersion).toEventually(equal(SQRLTestApplicationUpdatedShortVersionString));
	});

	it(@"should not install a corrupt update", ^{
		SKIP_IF_RUNNING_ON_TRAVIS

		NSURL *codeSignatureURL = [updateURL URLByAppendingPathComponent:@"Contents/_CodeSignature"];
		expect(@([NSFileManager.defaultManager removeItemAtURL:codeSignatureURL error:NULL])).to(beTruthy());

		SQRLTestUpdate *update = [SQRLTestUpdate modelWithDictionary:@{
			@"updateURL": zipUpdate(updateURL),
			@"final": @YES
		} error:NULL];

		writeUpdate(update);

		NSRunningApplication *app = launchWithEnvironment(nil);
		expect(@(app.terminated)).withTimeout(SQRLLongTimeout).toEventually(beTruthy());

		// Give the update some time to finish installing.
		[NSThread sleepForTimeInterval:0.2];
		expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationOriginalShortVersionString));
	});

	it(@"should update to the most recently enqueued job", ^{
		SKIP_IF_RUNNING_ON_TRAVIS

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

		expect(@(app.terminated)).withTimeout(SQRLLongTimeout).toEventually(beTruthy());
		expect(self.testApplicationBundleVersion).toEventually(equal(SQRLTestApplicationUpdatedShortVersionString));
	});

	it(@"should use the application's bundled version of Squirrel and update in-place after a significant delay", ^{
		SKIP_IF_RUNNING_ON_TRAVIS
		
		SQRLTestUpdate *update = [SQRLTestUpdate modelWithDictionary:@{
			@"updateURL": zipUpdate(updateURL),
			@"final": @YES
		} error:NULL];

		writeUpdate(update);

		NSTimeInterval delay = 15;
		NSRunningApplication *app = launchWithEnvironment(@{ @"SQRLUpdateDelay": [NSString stringWithFormat:@"%f", delay] });

		expect(@(app.terminated)).withTimeout(delay + SQRLLongTimeout).toEventually(beTruthy());
		expect(self.testApplicationBundleVersion).toEventually(equal(SQRLTestApplicationUpdatedShortVersionString));
	});

	describe(@"cleaning up", ^{
		__block NSURL *appSupportURL;
		__block RACSignal *updateDirectoryURLs;

		beforeEach(^{
			SQRLDirectoryManager *directoryManager = [[SQRLDirectoryManager alloc] initWithApplicationIdentifier:@"com.github.Squirrel.TestApplication.ShipIt"];

			appSupportURL = [[directoryManager storageURL] first];
			expect(appSupportURL).notTo(beNil());

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
			SKIP_IF_RUNNING_ON_TRAVIS

			NSError *error = nil;
			SQRLTestUpdate *update = [SQRLTestUpdate modelWithDictionary:@{
				@"updateURL": zipUpdate(updateURL),
				@"final": @YES
			} error:&error];

			expect(update).notTo(beNil());
			expect(error).to(beNil());

			writeUpdate(update);

			NSRunningApplication *app = launchWithEnvironment(@{ @"SQRLUpdateRequestCount": @2 });
			expect([updateDirectoryURLs toArray]).toEventuallyNot(equal(@[]));
			expect(@(app.terminated)).withTimeout(SQRLLongTimeout).toEventually(beTruthy());
			expect(self.testApplicationBundleVersion).toEventually(equal(SQRLTestApplicationUpdatedShortVersionString));

			expect([updateDirectoryURLs toArray]).toEventually(equal(@[]));
		});
	});
});

describe(@"response handling", ^{
	__block NSURLRequest *localRequest = nil;
	__block SQRLUpdater *updater = nil;

	beforeEach(^{
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
		expect(@(result)).to(beFalsy());
		expect(error.domain).to(equal(SQRLUpdaterErrorDomain));
		expect(@(error.code)).to(equal(@(SQRLUpdaterErrorInvalidServerResponse)));
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
		expect(@(result)).to(beFalsy());
		expect(error.domain).to(equal(SQRLUpdaterErrorDomain));
		expect(@(error.code)).to(equal(@(SQRLUpdaterErrorInvalidServerBody)));
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
		SKIP_IF_RUNNING_ON_TRAVIS

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
		expect(states).toEventually(equal(expectedStates));

		expect(@(testApplication.terminated)).withTimeout(SQRLLongTimeout).toEventually(beTruthy());
	});

	it(@"should transition through idle, checking, downloading and awaiting relaunch, when there is an update", ^{
		SKIP_IF_RUNNING_ON_TRAVIS

		NSMutableArray *states = [NSMutableArray array];
		[stateNotificationListener() subscribeNext:^(NSNumber *state) {
			[states addObject:state];
		}];

		NSError *error;
		SQRLTestUpdate *update = [SQRLTestUpdate modelWithDictionary:@{
			@"updateURL": zipUpdate([self createTestApplicationUpdate]),
			@"final": @YES,
		} error:&error];
		expect(update).notTo(beNil());
		expect(error).to(beNil());

		writeUpdate(update);

		NSRunningApplication *testApplication = launchWithEnvironment(nil);

		NSArray *expectedStates = @[
			@(SQRLUpdaterStateIdle),
			@(SQRLUpdaterStateCheckingForUpdate),
			@(SQRLUpdaterStateDownloadingUpdate),
			@(SQRLUpdaterStateAwaitingRelaunch),
		];
		expect(states).withTimeout(SQRLLongTimeout).toEventually(equal(expectedStates));

		expect(@(testApplication.terminated)).withTimeout(SQRLLongTimeout).toEventually(beTruthy());
	});
});

QuickSpecEnd
