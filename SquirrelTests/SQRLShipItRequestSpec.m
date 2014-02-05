//
//  SQRLShipItStateSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-09.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDirectoryManager.h"
#import "SQRLShipItRequest.h"

SpecBegin(SQRLShipItRequest)

__block SQRLDirectoryManager *directoryManager;
__block SQRLShipItRequest *request;

beforeEach(^{
	directoryManager = SQRLDirectoryManager.currentApplicationManager;

	NSURL *updateURL = [self createTestApplicationUpdate];
	request = [[SQRLShipItRequest alloc] initWithUpdateBundleURL:updateURL targetBundleURL:self.testApplicationURL bundleIdentifier:nil launchAfterInstallation:NO];
	expect(request).notTo.beNil();

	expect(request.targetBundleURL).to.equal(self.testApplicationURL);
	expect(request.updateBundleURL).to.equal(updateURL);
	expect(request.bundleIdentifier).to.beNil();
	expect(request.launchAfterInstallation).to.beFalsy();
});

afterEach(^{
	NSURL *stateURL = [[directoryManager shipItStateURL] first];
	expect(stateURL).notTo.beNil();
	
	[NSFileManager.defaultManager removeItemAtURL:stateURL error:NULL];
});

it(@"should copy", ^{
	SQRLShipItRequest *requestCopy = [request copy];
	expect(requestCopy).to.equal(request);
	expect(requestCopy).notTo.beIdenticalTo(request);
});

it(@"should fail to read state when no file exists yet", ^{
	NSError *error;
	BOOL success = [[SQRLShipItRequest readUsingURL:directoryManager.shipItStateURL] waitUntilCompleted:&error];
	expect(success).to.beFalsy();
	expect(error).notTo.beNil();
});

it(@"should write and read state to disk", ^{
	NSError *error;
	BOOL success = [[request writeUsingURL:directoryManager.shipItStateURL] waitUntilCompleted:&error];
	expect(success).to.beTruthy();
	expect(error).to.beNil();

	SQRLShipItRequest *readRequest = [[SQRLShipItRequest readUsingURL:directoryManager.shipItStateURL] firstOrDefault:nil success:&success error:&error];
	expect(success).to.beTruthy();
	expect(error).to.beNil();

	expect(readRequest).to.equal(request);
});

SpecEnd
