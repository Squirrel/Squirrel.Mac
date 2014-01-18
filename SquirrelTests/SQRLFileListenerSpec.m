//
//  SQRLFileListenerSpec.m
//  Squirrel
//
//  Created by Keith Duncan on 17/01/2014.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import "SQRLFileListener.h"

SpecBegin(SQRLFileListener)

it(@"should send a value for a file that already exists", ^{
	NSURL *fileToWatch = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"test-file"];

	NSError *error;
	BOOL write = [[NSData data] writeToURL:fileToWatch options:0 error:&error];
	expect(write).to.beTruthy();
	expect(error).to.beNil();

	SQRLFileListener *listener = [[SQRLFileListener alloc] initWithFileURL:fileToWatch];

	BOOL complete = [listener.waitUntilPresent asynchronouslyWaitUntilCompleted:&error];
	expect(complete).to.beTruthy();
	expect(error).to.beNil();
});

it(@"should send a value for a file that appears", ^{
	NSURL *fileToWatch = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"test-file"];

	SQRLFileListener *listener = [[SQRLFileListener alloc] initWithFileURL:fileToWatch];

	__block BOOL complete = NO;
	[listener.waitUntilPresent
		subscribeCompleted:^{
			complete = YES;
		}];

	expect(complete).to.beFalsy();

	NSError *error;
	BOOL write = [[NSData data] writeToURL:fileToWatch options:0 error:&error];
	expect(write).to.beTruthy();
	expect(error).to.beNil();

	expect(complete).will.beTruthy();
});

SpecEnd
