//
//  SQRLFileListenerSpec.m
//  Squirrel
//
//  Created by Keith Duncan on 17/01/2014.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import "SQRLFileListener.h"

SpecBegin(SQRLFileListener)

__block NSURL *fileToWatch = nil;

beforeEach(^{
	fileToWatch = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"test-file"];
});

it(@"should complete when the file already exists", ^{
	NSError *error;
	BOOL write = [[NSData data] writeToURL:fileToWatch options:0 error:&error];
	expect(write).to.beTruthy();
	expect(error).to.beNil();

	RACSignal *listener = [SQRLFileListener waitUntilItemExistsAtFileURL:fileToWatch];

	BOOL complete = [listener asynchronouslyWaitUntilCompleted:&error];
	expect(complete).to.beTruthy();
	expect(error).to.beNil();
});

it(@"should complete when the file appears", ^{
	RACSignal *listener = [SQRLFileListener waitUntilItemExistsAtFileURL:fileToWatch];

	__block BOOL complete = NO;
	[listener subscribeCompleted:^{
		complete = YES;
	}];

	expect(complete).to.beFalsy();

	NSError *error;
	BOOL write = [[NSData data] writeToURL:fileToWatch options:0 error:&error];
	expect(write).to.beTruthy();
	expect(error).to.beNil();

	expect(complete).will.beTruthy();
});

it(@"should error when given a parent directory that doesn't exist", ^{
	RACSignal *listener = [SQRLFileListener waitUntilItemExistsAtFileURL:[fileToWatch URLByAppendingPathComponent:@"sub-path"]];

	NSError *error;
	BOOL complete = [listener waitUntilCompleted:&error];
	expect(complete).to.beFalsy();
	expect(error.domain).to.equal(NSPOSIXErrorDomain);
	expect(error.code).to.equal(ENOENT);
});

SpecEnd
