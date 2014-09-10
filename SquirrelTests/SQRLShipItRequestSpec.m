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

it(@"should fail to read when no file exists yet", ^{
	NSError *error;
	BOOL success = [[SQRLShipItRequest readFromURL:[directoryManager.shipItStateURL first]] waitUntilCompleted:&error];
	expect(success).to.beFalsy();
	expect(error).notTo.beNil();
});

it(@"should write and read to disk", ^{
	NSError *error;
	BOOL success = [[request writeToURL:[directoryManager.shipItStateURL first]] waitUntilCompleted:&error];
	expect(success).to.beTruthy();
	expect(error).to.beNil();

	SQRLShipItRequest *readRequest = [[SQRLShipItRequest readFromURL:[directoryManager.shipItStateURL first]] firstOrDefault:nil success:&success error:&error];
	expect(success).to.beTruthy();
	expect(error).to.beNil();

	expect(readRequest).to.equal(request);
});

it(@"should fail gracefully with archives encoding a different class", ^{
	NSURL *archiveLocation = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"archive"];

	NSError *error;
	BOOL write = [[NSKeyedArchiver archivedDataWithRootObject:@"rogue object"] writeToURL:archiveLocation atomically:YES];
	expect(write).to.beTruthy();
	expect(error).to.beNil();

	BOOL success = NO;
	SQRLShipItRequest *request = [[SQRLShipItRequest readFromURL:archiveLocation] firstOrDefault:nil success:&success error:&error];
	expect(request).to.beNil();
	expect(success).to.beFalsy();
	expect(error.domain).to.equal(SQRLShipItRequestErrorDomain);
	expect(error.code).to.equal(SQRLShipItRequestErrorUnarchiving);
});

SpecEnd
