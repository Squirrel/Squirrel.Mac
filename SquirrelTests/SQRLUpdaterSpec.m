//
//  SQRLUpdaterSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-07-21.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Nimble/Nimble.h>
#import <Quick/Quick.h>
#import <ReactiveObjC/ReactiveObjC.h>
#import <Squirrel/Squirrel.h>

#import "SQRLDirectoryManager.h"
#import "SQRLShipItLauncher.h"
#import "SQRLUpdater.h"
#import "SQRLZipArchiver.h"

#import "OHHTTPStubs/OHHTTPStubs.h"
#import "QuickSpec+SQRLFixtures.h"
#import "SQRLTestUpdate.h"
#import "TestAppConstants.h"
#import <objc/objc-class.h>

@interface SQRLUpdater (SQRLTestingHooks)
- (RACSignal *)removeUpdateDirectoriesInStorageURL:(NSURL *)storageURL excludingURL:(NSURL *)excludedURL;
@property (nonatomic, strong, readonly) RACSignal *shipItLauncher;
@end

extern BOOL isVersionStandard(NSString* version);

//! controllable stub for +[SQRLShipItLauncher launchPrivileged:]
static int launchPrivilegedCallCount = 0;
static RACSignal *(^launchPrivilegedStub)(BOOL) = nil;
RACSignal * launchPrivilegedImp(id self, SEL _cmd, BOOL privileged)
{
	launchPrivilegedCallCount++;
	return launchPrivilegedStub != nil ? launchPrivilegedStub(privileged) : [RACSignal empty];
}

//! force Updater to believe we are not on readonly, to continue downloading the release
bool isRunningOnReadOnlyVolumeImp(id self, SEL _cmd)
{
	return false;
}

//! we don't want updateFromJSONData to be executed. It is enough to know if it was called
bool updateFromJSONDataIsCalled = false;
NSDictionary *updateFromJSONDataLastBody = nil;
RACSignal * updateFromJSONDataImp(id self, SEL _cmd, NSData * data)
{
	NSString* str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

	NSLog(@"updateFromJSONDataImp called with %@", str);
	updateFromJSONDataIsCalled = true;
	updateFromJSONDataLastBody = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
	return [RACSignal empty];
}

QuickSpecBegin(SQRLUpdaterSpec)

__block NSURL *JSONURL;

void (^writeUpdate)(SQRLUpdate *) = ^(SQRLUpdate *update) {
	NSError *error = nil;
	NSDictionary *updateInfo = [MTLJSONAdapter JSONDictionaryFromModel:update error:&error];
	expect(updateInfo).notTo(beNil());
	expect(error).to(beNil());

	NSData *JSON = [NSJSONSerialization dataWithJSONObject:updateInfo options:NSJSONWritingPrettyPrinted error:&error];
	expect(JSON).notTo(beNil());
	expect(error).to(beNil());

	BOOL success = [JSON writeToURL:JSONURL options:NSDataWritingAtomic error:&error];
	expect(@(success)).to(beTruthy());
	expect(error).to(beNil());
};

NSURL * (^zipUpdate)(NSURL *) = ^(NSURL *updateURL) {
	// The launched TestApplication cannot read from this process's
	// NSItemReplacementDirectory on modern macOS, so put the zip in our
	// per-example temporary directory instead.
	NSURL *zipFolderURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:NSProcessInfo.processInfo.globallyUniqueString isDirectory:YES];
	expect(@([NSFileManager.defaultManager createDirectoryAtURL:zipFolderURL withIntermediateDirectories:YES attributes:nil error:NULL])).to(beTruthy());

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

	beforeEach(^{
		updateFromJSONDataIsCalled = false;
		updateFromJSONDataLastBody = nil;

		// Short-circuit updateFromJSONData: so the test only verifies the
		// HTTP fetch path, and force isRunningOnReadOnlyVolume to NO since
		// the xctest CLI host has no bundleURL. Both implementations are
		// restored after each example so later in-process specs are
		// unaffected.
		Method updateFromJSON = class_getInstanceMethod(SQRLUpdater.class, @selector(updateFromJSONData:));
		IMP originalUpdateFromJSON = method_setImplementation(updateFromJSON, (IMP)updateFromJSONDataImp);

		Method readOnly = class_getInstanceMethod(SQRLUpdater.class, @selector(isRunningOnReadOnlyVolume));
		IMP originalReadOnly = method_setImplementation(readOnly, (IMP)isRunningOnReadOnlyVolumeImp);

		[self addCleanupBlock:^{
			method_setImplementation(updateFromJSON, originalUpdateFromJSON);
			method_setImplementation(readOnly, originalReadOnly);
		}];

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
	});

	it(@"Squirrel should work with a release server", ^{
		if(!testLocalServer) return;

		NSURLRequest *localRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:localServerURL]];
		SQRLUpdater *updater = [[SQRLUpdater alloc] initWithUpdateRequest:localRequest];

		NSError *error = nil;
		BOOL result = [[updater.checkForUpdatesCommand execute:nil] asynchronouslyWaitUntilCompleted:&error];

		expect((int)updater.state).toEventually(equal((int)SQRLUpdaterStateIdle));
		expect( (BOOL) updateFromJSONDataIsCalled ).to(beTrue());
		expect( (BOOL) result ).to(beTrue());
	});

	it(@"Squirrel should work with a CDN", ^{
		if(!testLocalCdn) return;

		NSURLRequest *localRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:localCdnURL]];
		SQRLUpdater *updater = [[SQRLUpdater alloc] initWithUpdateRequest:localRequest];

		NSError *error = nil;
		BOOL result = [[updater.checkForUpdatesCommand execute:nil] asynchronouslyWaitUntilCompleted:&error];

		expect((int)updater.state).toEventually(equal((int)SQRLUpdaterStateIdle));
		expect( (BOOL) updateFromJSONDataIsCalled ).to(beTrue());
		expect( (BOOL) result ).to(beTrue());
	});

	it(@"should treat a 204 No Content response as no update available", ^{
		OHHTTPStubs *stubs = [OHHTTPStubs shouldStubRequestsPassingTest:^(NSURLRequest *request) {
			return [request.URL.absoluteString isEqualToString:@"http://fake/no-update"];
		} withStubResponse:^(NSURLRequest *request) {
			return [OHHTTPStubsResponse responseWithData:NSData.data statusCode:204 responseTime:0 headers:nil];
		}];
		[self addCleanupBlock:^{ [OHHTTPStubs removeRequestHandler:stubs]; }];

		NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://fake/no-update"]];
		SQRLUpdater *updater = [[SQRLUpdater alloc] initWithUpdateRequest:request];

		NSError *error = nil;
		BOOL result = [[updater.checkForUpdatesCommand execute:nil] asynchronouslyWaitUntilCompleted:&error];

		expect(@(result)).to(beTruthy());
		expect(error).to(beNil());
		expect((BOOL)updateFromJSONDataIsCalled).to(beFalse());
		expect((int)updater.state).toEventually(equal((int)SQRLUpdaterStateIdle));
	});

	it(@"should pass through custom headers from the update request", ^{
		__block NSString *seenHeader = nil;
		OHHTTPStubs *stubs = [OHHTTPStubs shouldStubRequestsPassingTest:^(NSURLRequest *request) {
			return [request.URL.absoluteString isEqualToString:@"http://fake/with-headers"];
		} withStubResponse:^(NSURLRequest *request) {
			seenHeader = request.allHTTPHeaderFields[@"X-Test"];
			return [OHHTTPStubsResponse responseWithData:NSData.data statusCode:204 responseTime:0 headers:nil];
		}];
		[self addCleanupBlock:^{ [OHHTTPStubs removeRequestHandler:stubs]; }];

		NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://fake/with-headers"]];
		[request setValue:@"this-is-a-test" forHTTPHeaderField:@"X-Test"];
		SQRLUpdater *updater = [[SQRLUpdater alloc] initWithUpdateRequest:request];

		NSError *error = nil;
		BOOL result = [[updater.checkForUpdatesCommand execute:nil] asynchronouslyWaitUntilCompleted:&error];

		expect(@(result)).to(beTruthy());
		expect(seenHeader).to(equal(@"this-is-a-test"));
	});

	describe(@"JSONFILE mode", ^{
		OHHTTPStubsResponse * (^jsonResponse)(NSDictionary *) = ^(NSDictionary *body) {
			NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
			return [OHHTTPStubsResponse responseWithData:data statusCode:200 responseTime:0 headers:nil];
		};

		SQRLUpdater * (^makeUpdater)(NSString *) = ^(NSString *currentVersion) {
			NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://fake/releases.json"]];
			return [[SQRLUpdater alloc] initWithUpdateRequest:request forVersion:currentVersion];
		};

		it(@"should pick the matching release's updateTo when currentRelease is newer than the running version", ^{
			NSDictionary *updateTo = @{
				@"version": @"2.0.0",
				@"url": @"http://fake/app-2.0.0.zip",
				@"name": @"v2",
			};
			OHHTTPStubs *stubs = [OHHTTPStubs shouldStubRequestsPassingTest:^(NSURLRequest *request) {
				return [request.URL.absoluteString isEqualToString:@"http://fake/releases.json"];
			} withStubResponse:^(NSURLRequest *request) {
				return jsonResponse(@{
					@"currentRelease": @"2.0.0",
					@"releases": @[
						@{ @"version": @"1.5.0", @"updateTo": @{ @"url": @"http://fake/wrong" } },
						@{ @"version": @"2.0.0", @"updateTo": updateTo },
					],
				});
			}];
			[self addCleanupBlock:^{ [OHHTTPStubs removeRequestHandler:stubs]; }];

			SQRLUpdater *updater = makeUpdater(@"1.0.0");
			NSError *error = nil;
			BOOL result = [[updater.checkForUpdatesCommand execute:nil] asynchronouslyWaitUntilCompleted:&error];

			expect(@(result)).to(beTruthy());
			expect((BOOL)updateFromJSONDataIsCalled).to(beTrue());
			expect(updateFromJSONDataLastBody).to(equal(updateTo));
		});

		it(@"should not download when currentRelease equals the running version", ^{
			OHHTTPStubs *stubs = [OHHTTPStubs shouldStubRequestsPassingTest:^(NSURLRequest *request) {
				return [request.URL.absoluteString isEqualToString:@"http://fake/releases.json"];
			} withStubResponse:^(NSURLRequest *request) {
				return jsonResponse(@{
					@"currentRelease": @"1.0.0",
					@"releases": @[
						@{ @"version": @"1.0.0", @"updateTo": @{ @"url": @"http://fake/wrong" } },
					],
				});
			}];
			[self addCleanupBlock:^{ [OHHTTPStubs removeRequestHandler:stubs]; }];

			SQRLUpdater *updater = makeUpdater(@"1.0.0");
			NSError *error = nil;
			BOOL result = [[updater.checkForUpdatesCommand execute:nil] asynchronouslyWaitUntilCompleted:&error];

			expect(@(result)).to(beTruthy());
			expect(error).to(beNil());
			expect((BOOL)updateFromJSONDataIsCalled).to(beFalse());
		});

		it(@"should not download when currentRelease is older than the running version", ^{
			OHHTTPStubs *stubs = [OHHTTPStubs shouldStubRequestsPassingTest:^(NSURLRequest *request) {
				return [request.URL.absoluteString isEqualToString:@"http://fake/releases.json"];
			} withStubResponse:^(NSURLRequest *request) {
				return jsonResponse(@{
					@"currentRelease": @"0.1.0",
					@"releases": @[
						@{ @"version": @"0.1.0", @"updateTo": @{ @"url": @"http://fake/wrong" } },
					],
				});
			}];
			[self addCleanupBlock:^{ [OHHTTPStubs removeRequestHandler:stubs]; }];

			SQRLUpdater *updater = makeUpdater(@"1.0.0");
			NSError *error = nil;
			BOOL result = [[updater.checkForUpdatesCommand execute:nil] asynchronouslyWaitUntilCompleted:&error];

			expect(@(result)).to(beTruthy());
			expect(error).to(beNil());
			expect((BOOL)updateFromJSONDataIsCalled).to(beFalse());
		});

		it(@"should error when the JSON file is invalid", ^{
			OHHTTPStubs *stubs = [OHHTTPStubs shouldStubRequestsPassingTest:^(NSURLRequest *request) {
				return [request.URL.absoluteString isEqualToString:@"http://fake/releases.json"];
			} withStubResponse:^(NSURLRequest *request) {
				return [OHHTTPStubsResponse responseWithData:[@"not json" dataUsingEncoding:NSUTF8StringEncoding] statusCode:200 responseTime:0 headers:nil];
			}];
			[self addCleanupBlock:^{ [OHHTTPStubs removeRequestHandler:stubs]; }];

			SQRLUpdater *updater = makeUpdater(@"1.0.0");
			NSError *error = nil;
			BOOL result = [[updater.checkForUpdatesCommand execute:nil] asynchronouslyWaitUntilCompleted:&error];

			expect(@(result)).to(beFalsy());
			expect(error.domain).to(equal(SQRLUpdaterErrorDomain));
			expect(@(error.code)).to(equal(@(SQRLUpdaterErrorInvalidServerBody)));
			expect((BOOL)updateFromJSONDataIsCalled).to(beFalse());
		});
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
		[self waitForShipItJobToExitWithLabel:@"com.github.Squirrel.TestApplication.ShipIt"];
		expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationUpdatedShortVersionString));
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
		[self waitForShipItJobToExitWithLabel:@"com.github.Squirrel.TestApplication.ShipIt"];
		expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationUpdatedShortVersionString));
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
		[self waitForShipItJobToExitWithLabel:@"com.github.Squirrel.TestApplication.ShipIt"];
		expect(self.testApplicationBundleVersion).to(equal(SQRLTestApplicationUpdatedShortVersionString));
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

		it(@"should keep the update directory count bounded across repeated checks", ^{
			SKIP_IF_RUNNING_ON_TRAVIS

			NSError *error = nil;
			SQRLTestUpdate *update = [SQRLTestUpdate modelWithDictionary:@{
				@"updateURL": zipUpdate(updateURL),
			} error:&error];

			expect(update).notTo(beNil());
			expect(error).to(beNil());

			writeUpdate(update);

			NSRunningApplication *app = launchWithEnvironment(@{ @"SQRLUpdateRequestCount": @"3" });
			expect([updateDirectoryURLs toArray]).toEventuallyNot(equal(@[]));
			expect(@(app.terminated)).withTimeout(SQRLLongTimeout).toEventually(beTruthy());

			// pruneOrphanedUpdateDirectories runs before each download and
			// preserves only the directory referenced by the current
			// ShipItState, so after N checks at most 2 directories remain
			// (the most recently staged + the one created during the final
			// check).
			expect(@([[updateDirectoryURLs toArray] count])).to(beLessThanOrEqualTo(@2));
		});

		it(@"should remove orphaned update directories while preserving the excluded one", ^{
			NSURL *storageURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"prune-storage"];
			expect(@([NSFileManager.defaultManager createDirectoryAtURL:storageURL withIntermediateDirectories:YES attributes:nil error:NULL])).to(beTruthy());

			NSURL *staged = nil;
			for (int i = 0; i < 4; i++) {
				NSURL *dir = [storageURL URLByAppendingPathComponent:[NSString stringWithFormat:@"update.ORPHAN%d", i]];
				expect(@([NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:NULL])).to(beTruthy());
				if (i == 2) staged = dir;
			}
			// Non-prefixed directory must be left alone.
			NSURL *unrelated = [storageURL URLByAppendingPathComponent:@"ShipItState.plist"];
			[NSData.data writeToURL:unrelated atomically:YES];

			SQRLUpdater *updater = [SQRLUpdater alloc];
			BOOL ok = [[updater removeUpdateDirectoriesInStorageURL:storageURL excludingURL:staged] asynchronouslyWaitUntilCompleted:NULL];
			expect(@(ok)).to(beTruthy());

			NSArray *remaining = [NSFileManager.defaultManager contentsOfDirectoryAtURL:storageURL includingPropertiesForKeys:nil options:0 error:NULL];
			NSPredicate *isUpdateDir = [NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) {
				return [url.lastPathComponent hasPrefix:@"update."];
			}];
			NSArray *remainingUpdateDirs = [remaining filteredArrayUsingPredicate:isUpdateDir];

			expect(@(remainingUpdateDirs.count)).to(equal(@1));
			expect([remainingUpdateDirs.firstObject lastPathComponent]).to(equal(staged.lastPathComponent));
			expect(@([NSFileManager.defaultManager fileExistsAtPath:unrelated.path])).to(beTruthy());
		});
	});
});

describe(@"response handling", ^{
	__block NSURLRequest *localRequest = nil;
	__block SQRLUpdater *updater = nil;

	beforeEach(^{
		// Under XCTest the host process has no bundleURL, so the read-only
		// volume check would otherwise short-circuit before the response is
		// inspected.
		Method readOnly = class_getInstanceMethod(SQRLUpdater.class, @selector(isRunningOnReadOnlyVolume));
		IMP originalReadOnly = method_setImplementation(readOnly, (IMP)isRunningOnReadOnlyVolumeImp);
		[self addCleanupBlock:^{
			method_setImplementation(readOnly, originalReadOnly);
		}];

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

	it(@"should return an error when the download endpoint responds with non-2xx", ^{
		__block BOOL downloadHit = NO;
		OHHTTPStubs *stubsCheck = [OHHTTPStubs shouldStubRequestsPassingTest:^(NSURLRequest *request) {
			return [request.URL isEqual:localRequest.URL];
		} withStubResponse:^(NSURLRequest *request) {
			NSDictionary *body = @{ @"url": @"http://fake/download.zip" };
			NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
			return [OHHTTPStubsResponse responseWithData:json statusCode:200 responseTime:0 headers:nil];
		}];
		OHHTTPStubs *stubsDownload = [OHHTTPStubs shouldStubRequestsPassingTest:^(NSURLRequest *request) {
			return [request.URL.absoluteString isEqualToString:@"http://fake/download.zip"];
		} withStubResponse:^(NSURLRequest *request) {
			downloadHit = YES;
			return [OHHTTPStubsResponse responseWithData:[@"nope" dataUsingEncoding:NSUTF8StringEncoding] statusCode:/* Server Error */ 500 responseTime:0 headers:nil];
		}];
		[self addCleanupBlock:^{
			[OHHTTPStubs removeRequestHandler:stubsCheck];
			[OHHTTPStubs removeRequestHandler:stubsDownload];
		}];

		NSError *error = nil;
		BOOL result = [[updater.checkForUpdatesCommand execute:nil] asynchronouslyWaitUntilCompleted:&error];
		expect(@(result)).to(beFalsy());
		expect(@(downloadHit)).to(beTruthy());
		expect(error.domain).to(equal(SQRLUpdaterErrorDomain));
		expect(@(error.code)).to(equal(@(SQRLUpdaterErrorInvalidServerResponse)));
		expect(error.localizedDescription).to(contain(@"Update download failed"));
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

describe(@"shipItLauncher", ^{
	__block IMP originalLaunchPrivileged;
	__block Method launchPrivilegedMethod;
	__block SQRLUpdater *updater;

	beforeEach(^{
		launchPrivilegedCallCount = 0;
		launchPrivilegedStub = nil;

		launchPrivilegedMethod = class_getClassMethod(SQRLShipItLauncher.class, @selector(launchPrivileged:));
		originalLaunchPrivileged = method_setImplementation(launchPrivilegedMethod, (IMP)launchPrivilegedImp);

		NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://fake/"]];
		updater = [[SQRLUpdater alloc] initWithUpdateRequest:request];
	});

	afterEach(^{
		method_setImplementation(launchPrivilegedMethod, originalLaunchPrivileged);
		launchPrivilegedStub = nil;
	});

	it(@"should not re-submit the launchd job after a successful launch", ^{
		launchPrivilegedStub = ^(BOOL privileged) { return [RACSignal empty]; };

		NSError *error = nil;
		BOOL success = [updater.shipItLauncher waitUntilCompleted:&error];
		expect(@(success)).to(beTruthy());
		expect(error).to(beNil());
		expect(@(launchPrivilegedCallCount)).to(equal(@1));

		success = [updater.shipItLauncher waitUntilCompleted:&error];
		expect(@(success)).to(beTruthy());
		expect(@(launchPrivilegedCallCount)).to(equal(@1));
	});

	it(@"should retry the launch on the next subscription after an error", ^{
		NSError *cancelled = [NSError errorWithDomain:NSOSStatusErrorDomain code:-60006 userInfo:nil];
		launchPrivilegedStub = ^(BOOL privileged) { return [RACSignal error:cancelled]; };

		NSError *error = nil;
		BOOL success = [updater.shipItLauncher waitUntilCompleted:&error];
		expect(@(success)).to(beFalsy());
		expect(error).to(equal(cancelled));
		expect(@(launchPrivilegedCallCount)).to(equal(@1));

		// User re-authorizes / transient SMJobSubmit failure clears.
		launchPrivilegedStub = ^(BOOL privileged) { return [RACSignal empty]; };

		error = nil;
		success = [updater.shipItLauncher waitUntilCompleted:&error];
		expect(@(success)).to(beTruthy());
		expect(error).to(beNil());
		expect(@(launchPrivilegedCallCount)).to(equal(@2));
	});
});

describe(@"isVersionStandard", ^{
	it(@"should accept simple Major.Minor.Patch version strings", ^{
		expect(@(isVersionStandard(@"1.2.3"))).to(beTruthy());
		expect(@(isVersionStandard(@"0.0.0"))).to(beTruthy());
		expect(@(isVersionStandard(@"10.20.30"))).to(beTruthy());
		expect(@(isVersionStandard(@"100.0.1"))).to(beTruthy());
	});

	it(@"should reject version strings without exactly three parts", ^{
		expect(@(isVersionStandard(@"1.2"))).to(beFalsy());
		expect(@(isVersionStandard(@"1.2.3.4"))).to(beFalsy());
		expect(@(isVersionStandard(@"1"))).to(beFalsy());
		expect(@(isVersionStandard(@""))).to(beFalsy());
	});

	it(@"should reject version strings with non-numeric parts", ^{
		expect(@(isVersionStandard(@"1.2.3-beta"))).to(beFalsy());
		expect(@(isVersionStandard(@"a.b.c"))).to(beFalsy());
		expect(@(isVersionStandard(@"1.2.x"))).to(beFalsy());
		expect(@(isVersionStandard(@"v1.2.3"))).to(beFalsy());
	});

	it(@"should reject version strings with empty parts", ^{
		expect(@(isVersionStandard(@"1..3"))).to(beFalsy());
		expect(@(isVersionStandard(@".."))).to(beFalsy());
		expect(@(isVersionStandard(@".2.3"))).to(beFalsy());
	});
});

describe(@"+isVersionAllowedForUpdate:from:", ^{
	it(@"should compare version numbers correctly", ^{
		expect(@([SQRLUpdater isVersionAllowedForUpdate:@"2.0.0" from:@"1.0.0"])).to(beTruthy());
		expect(@([SQRLUpdater isVersionAllowedForUpdate:@"1.0.10" from:@"1.0.1"])).to(beTruthy());
		expect(@([SQRLUpdater isVersionAllowedForUpdate:@"1.0.1" from:@"1.0.10"])).to(beFalsy());
		expect(@([SQRLUpdater isVersionAllowedForUpdate:@"1.32.0" from:@"1.31.1"])).to(beTruthy());
		expect(@([SQRLUpdater isVersionAllowedForUpdate:@"0.32.0" from:@"1.31.1"])).to(beFalsy());
	});

	it(@"should allow updating to the same version", ^{
		expect(@([SQRLUpdater isVersionAllowedForUpdate:@"1.2.3" from:@"1.2.3"])).to(beTruthy());
	});
});

QuickSpecEnd
