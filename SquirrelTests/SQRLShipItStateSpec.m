//
//  SQRLShipItStateSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-09.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDirectoryManager.h"
#import "SQRLShipItState.h"

SpecBegin(SQRLShipItState)

__block SQRLDirectoryManager *directoryManager;
__block SQRLShipItState *state;

beforeEach(^{
	directoryManager = SQRLDirectoryManager.currentApplicationManager;

	NSURL *updateURL = [self createTestApplicationUpdate];
	state = [[SQRLShipItState alloc] initWithTargetBundleURL:self.testApplicationURL updateBundleURL:updateURL bundleIdentifier:nil];
	expect(state).notTo.beNil();

	expect(state.targetBundleURL).to.equal(self.testApplicationURL);
	expect(state.updateBundleURL).to.equal(updateURL);
	expect(state.bundleIdentifier).to.beNil();
});

afterEach(^{
	NSURL *stateURL = [[directoryManager shipItStateURL] firstOrDefault:nil success:NULL error:NULL];
	expect(stateURL).notTo.beNil();
	
	[NSFileManager.defaultManager removeItemAtURL:stateURL error:NULL];
});

it(@"should copy", ^{
	SQRLShipItState *stateCopy = [state copy];
	expect(stateCopy).to.equal(state);
	expect(stateCopy).notTo.beIdenticalTo(state);
});

it(@"should fail to read state when no file exists yet", ^{
	NSError *error = nil;
	BOOL success = [[SQRLShipItState readUsingURL:directoryManager.shipItStateURL] waitUntilCompleted:&error];
	expect(success).to.beFalsy();
	expect(error).notTo.beNil();
});

it(@"should write and read state to disk", ^{
	NSError *error = nil;
	BOOL success = [[state writeUsingURL:directoryManager.shipItStateURL] waitUntilCompleted:&error];
	expect(success).to.beTruthy();
	expect(error).to.beNil();

	SQRLShipItState *readState = [[SQRLShipItState readUsingURL:directoryManager.shipItStateURL] firstOrDefault:nil success:&success error:&error];
	expect(success).to.beTruthy();
	expect(error).to.beNil();

	expect(readState).to.equal(state);
});

it(@"should write and read state to defaults", ^{
	NSString *domain = @"com.github.Squirrel.Tests";
	NSString *defaultsKey = @"SQRLShipItStateSpecStateKey";

	NSError *error = nil;
	BOOL success = [[state writeToDefaultsDomain:domain key:defaultsKey] waitUntilCompleted:&error];
	expect(success).to.beTruthy();
	expect(error).to.beNil();

	SQRLShipItState *readState = [[SQRLShipItState readFromDefaultsDomain:domain key:defaultsKey] firstOrDefault:nil success:&success error:&error];
	expect(success).to.beTruthy();
	expect(error).to.beNil();

	expect(readState).to.equal(state);
});

SpecEnd
