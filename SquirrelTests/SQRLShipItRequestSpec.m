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

#import <sys/stat.h>
#import <unistd.h>

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
	[NSFileManager.defaultManager removeItemAtURL:[SQRLShipItRequest preparationStatusURLForStateURL:stateURL] error:NULL];
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
	it(@"should write preparation status to a separate file without modifying ShipItState.plist", ^{
		NSURL *stateURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"ShipItState.plist"];
		RACSignal *location = [RACSignal return:stateURL];

		NSMutableDictionary *newerValues = [request.dictionaryValue mutableCopy];
		newerValues[@"updateBundleURL"] = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"newer.app"];
		newerValues[@"launchAfterInstallation"] = @YES;
		SQRLShipItRequest *newerRequest = [[SQRLShipItRequest alloc] initWithDictionary:newerValues error:NULL];
		expect(@([[newerRequest writeUsingURL:location] waitUntilCompleted:NULL])).to(beTruthy());

		expect(@([[request writePreparationResult:nil usingURL:location] waitUntilCompleted:NULL])).to(beTruthy());

		SQRLShipItRequest *stateOnDisk = [[SQRLShipItRequest readUsingURL:location] first];
		expect(stateOnDisk).to(equal(newerRequest));
		expect(@(stateOnDisk.launchAfterInstallation)).to(beTruthy());
	});

	it(@"should allow only the relaunch flag and preparation fields to change", ^{
		NSMutableDictionary *values = [request.dictionaryValue mutableCopy];
		values[@"launchAfterInstallation"] = @YES;
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

	it(@"should wait for a matching acknowledgment in ShipItState.plist.prepared rather than a stale request", ^{
		NSURL *URL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"ShipItState.plist"];
		RACSignal *location = [RACSignal return:URL];
		NSMutableDictionary *values = [request.dictionaryValue mutableCopy];
		values[@"updateBundleURL"] = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"stale.app"];
		SQRLShipItRequest *stale = [[SQRLShipItRequest alloc] initWithDictionary:values error:NULL];
		expect(@([[stale writePreparationResult:nil usingURL:location] waitUntilCompleted:NULL])).to(beTruthy());
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
			[[request writePreparationResult:nil usingURL:location] subscribeError:^(NSError *error) {
				XCTFail(@"Could not acknowledge preparation: %@", error);
			}];
		});
		__block NSError *error = nil;
		expect(@([[request waitForPreparationUsingURL:location] asynchronouslyWaitUntilCompleted:&error])).to(beTruthy());
		expect(error).to(beNil());
	});

	it(@"should propagate preparation errors from ShipItState.plist.prepared", ^{
		RACSignal *location = [RACSignal return:[self.temporaryDirectoryURL URLByAppendingPathComponent:@"ShipItState.plist"]];
		expect(@([[request writeUsingURL:location] waitUntilCompleted:NULL])).to(beTruthy());
		NSError *failure = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOSPC userInfo:@{ NSLocalizedDescriptionKey: @"No space for preparation" }];
		expect(@([[request writePreparationResult:failure usingURL:location] waitUntilCompleted:NULL])).to(beTruthy());
		__block NSError *error = nil;
		expect(@([[request waitForPreparationUsingURL:location] asynchronouslyWaitUntilCompleted:&error])).to(beFalsy());
		expect(error.localizedDescription).to(equal(failure.localizedDescription));
	});

	it(@"should replace a symlink at ShipItState.plist.prepared without following it or changing target permissions", ^{
		NSURL *stateURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"ShipItState.plist"];
		NSURL *preparedURL = [SQRLShipItRequest preparationStatusURLForStateURL:stateURL];
		NSURL *victimURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"victim"];
		expect(@([@"secret" writeToURL:victimURL atomically:YES encoding:NSUTF8StringEncoding error:NULL])).to(beTruthy());
		expect(@(chmod(victimURL.path.fileSystemRepresentation, S_IRUSR | S_IWUSR))).to(equal(@0));
		expect(@(symlink(victimURL.path.fileSystemRepresentation, preparedURL.path.fileSystemRepresentation))).to(equal(@0));

		__block NSError *error = nil;
		expect(@([[request writePreparationResult:nil usingURL:[RACSignal return:stateURL]] waitUntilCompleted:&error])).to(beTruthy());
		expect(error).to(beNil());

		struct stat victimStat = {0};
		int victimStatResult = lstat(victimURL.path.fileSystemRepresentation, &victimStat);
		expect(@(victimStatResult)).to(equal(@0));
		expect(@(victimStat.st_mode & 0777)).to(equal(@0600));
		expect([NSString stringWithContentsOfURL:victimURL encoding:NSUTF8StringEncoding error:NULL]).to(equal(@"secret"));

		struct stat preparedStat = {0};
		int preparedStatResult = lstat(preparedURL.path.fileSystemRepresentation, &preparedStat);
		expect(@(preparedStatResult)).to(equal(@0));
		expect(@(S_ISREG(preparedStat.st_mode))).to(beTruthy());
		expect(@(preparedStat.st_mode & 0777)).to(equal(@0644));
	});

	it(@"should refuse to write preparation status through a symlinked parent directory", ^{
		NSURL *realDirURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"real-dir" isDirectory:YES];
		NSURL *symlinkDirURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"symlink-dir" isDirectory:YES];
		expect(@([NSFileManager.defaultManager createDirectoryAtURL:realDirURL withIntermediateDirectories:YES attributes:nil error:NULL])).to(beTruthy());
		expect(@(symlink(realDirURL.path.fileSystemRepresentation, symlinkDirURL.path.fileSystemRepresentation))).to(equal(@0));

		NSURL *stateURL = [symlinkDirURL URLByAppendingPathComponent:@"ShipItState.plist"];
		__block NSError *error = nil;
		expect(@([[request writePreparationResult:nil usingURL:[RACSignal return:stateURL]] waitUntilCompleted:&error])).to(beFalsy());
		expect(error).notTo(beNil());
		expect(@([NSFileManager.defaultManager fileExistsAtPath:[realDirURL URLByAppendingPathComponent:@"ShipItState.plist.prepared"].path])).to(beFalsy());
	});
});

QuickSpecEnd
