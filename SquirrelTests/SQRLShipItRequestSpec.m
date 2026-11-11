//
//  SQRLShipItStateSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-09.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Nimble/Nimble.h>
#import <Quick/Quick.h>
#import <ReactiveObjC/ReactiveObjC.h>
#import <Squirrel/Squirrel.h>

#import "SQRLDirectoryManager.h"
#import "SQRLShipItRequest.h"

#import "QuickSpec+SQRLFixtures.h"

QuickSpecBegin(SQRLShipItRequestSpec)

__block SQRLDirectoryManager *directoryManager;
__block SQRLShipItRequest *request;

beforeEach(^{
	directoryManager = SQRLDirectoryManager.currentApplicationManager;

	NSURL *updateURL = [self createTestApplicationUpdate];
	request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:self.testApplicationURL bundleIdentifier:nil launchAfterInstallation:NO useUpdateBundleName:NO];
	expect(request).notTo(beNil());

	expect(request.targetBundleURL).to(equal(self.testApplicationURL));
	expect(request.updateBundleURL).to(equal(updateURL));
	expect(request.bundleIdentifier).to(beNil());
	expect(@(request.launchAfterInstallation)).to(beFalsy());
});

afterEach(^{
	NSURL *stateURL = [[directoryManager shipItStateURL] first];
	expect(stateURL).notTo(beNil());

	[NSFileManager.defaultManager removeItemAtURL:stateURL error:NULL];
});

it(@"should copy", ^{
	SQRLShipItRequest *requestCopy = [request copy];
	expect(requestCopy).to(equal(request));
	expect(requestCopy).notTo(beIdenticalTo(request));
});

it(@"should fail to read state when no file exists yet", ^{
	NSError *error;
	BOOL success = [[SQRLShipItRequest readUsingURL:directoryManager.shipItStateURL] waitUntilCompleted:&error];
	expect(@(success)).to(beFalsy());
	expect(error).notTo(beNil());
});

it(@"should write and read state to disk", ^{
	NSError *error;
	BOOL success = [[request writeUsingURL:directoryManager.shipItStateURL] waitUntilCompleted:&error];
	expect(@(success)).to(beTruthy());
	expect(error).to(beNil());

	SQRLShipItRequest *readRequest = [[SQRLShipItRequest readUsingURL:directoryManager.shipItStateURL] firstOrDefault:nil success:&success error:&error];
	expect(@(success)).to(beTruthy());
	expect(error).to(beNil());

	expect(readRequest).to(equal(request));
});

it(@"should fail gracefully with archives encoding a different class", ^{
	NSURL *archiveLocation = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"archive"];

	NSError *error;
	BOOL write = [[NSKeyedArchiver archivedDataWithRootObject:@"rogue object"] writeToURL:archiveLocation atomically:YES];
	expect(@(write)).to(beTruthy());
	expect(error).to(beNil());

	BOOL success = NO;
	SQRLShipItRequest *request = [[SQRLShipItRequest readUsingURL:[RACSignal return:archiveLocation]] firstOrDefault:nil success:&success error:&error];
	expect(request).to(beNil());
	expect(@(success)).to(beFalsy());
	expect(error.domain).to(equal(SQRLShipItRequestErrorDomain));
	expect(@(error.code)).to(equal(@(SQRLShipItRequestErrorUnarchiving)));
});

describe(@"preparation status", ^{
	it(@"should preserve preparation status through serialization", ^{
		NSMutableDictionary *values = [request.dictionaryValue mutableCopy];
		values[@"prepared"] = @YES;
		SQRLShipItRequest *preparedRequest = [[SQRLShipItRequest alloc] initWithDictionary:values error:NULL];
		expect(@([[preparedRequest writeUsingURL:directoryManager.shipItStateURL] waitUntilCompleted:NULL])).to(beTruthy());
		SQRLShipItRequest *restored = [[SQRLShipItRequest readUsingURL:directoryManager.shipItStateURL] first];
		expect(restored.prepared).to(equal(@YES));
	});

	it(@"should allow only the relaunch flag and preparation fields to change", ^{
		NSMutableDictionary *values = [request.dictionaryValue mutableCopy];
		values[@"launchAfterInstallation"] = @YES;
		values[@"prepared"] = @YES;
		SQRLShipItRequest *relaunch = [[SQRLShipItRequest alloc] initWithDictionary:values error:NULL];
		expect(@([request matchesPreparedRequest:relaunch])).to(beTruthy());

		for (NSString *key in @[ @"targetBundleURL", @"updateBundleURL", @"bundleIdentifier", @"useUpdateBundleName", @"earlyStaging" ]) {
			NSMutableDictionary *changed = [values mutableCopy];
			if ([key hasSuffix:@"URL"]) {
				changed[key] = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"different.app"];
			} else if ([key isEqual:@"useUpdateBundleName"] || [key isEqual:@"earlyStaging"]) {
				changed[key] = @YES;
			} else {
				changed[key] = @"different";
			}
			expect(@([request matchesPreparedRequest:[[SQRLShipItRequest alloc] initWithDictionary:changed error:NULL]])).to(beFalsy());
		}
	});

	it(@"should wait for a matching acknowledgment in ShipItState.plist rather than a stale request", ^{
		NSURL *URL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"ShipItState.plist"];
		RACSignal *location = [RACSignal return:URL];
		NSMutableDictionary *values = [request.dictionaryValue mutableCopy];
		values[@"updateBundleURL"] = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"stale.app"];
		values[@"prepared"] = @YES;
		SQRLShipItRequest *stale = [[SQRLShipItRequest alloc] initWithDictionary:values error:NULL];
		expect(@([[stale writeUsingURL:location] waitUntilCompleted:NULL])).to(beTruthy());
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
			[[[request writeUsingURL:location] then:^{
				return [request writePreparationResult:nil usingURL:location];
			}] subscribeError:^(NSError *error) {
				XCTFail(@"Could not acknowledge preparation: %@", error);
			}];
		});
		__block NSError *error = nil;
		expect(@([[request waitForPreparationUsingURL:location] asynchronouslyWaitUntilCompleted:&error])).to(beTruthy());
		expect(error).to(beNil());
	});

	it(@"should propagate preparation errors from ShipItState.plist", ^{
		RACSignal *location = [RACSignal return:[self.temporaryDirectoryURL URLByAppendingPathComponent:@"ShipItState.plist"]];
		expect(@([[request writeUsingURL:location] waitUntilCompleted:NULL])).to(beTruthy());
		NSError *failure = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOSPC userInfo:@{ NSLocalizedDescriptionKey: @"No space for preparation" }];
		expect(@([[request writePreparationResult:failure usingURL:location] waitUntilCompleted:NULL])).to(beTruthy());
		__block NSError *error = nil;
		expect(@([[request waitForPreparationUsingURL:location] asynchronouslyWaitUntilCompleted:&error])).to(beFalsy());
		expect(error.localizedDescription).to(equal(failure.localizedDescription));
	});
});

QuickSpecEnd
