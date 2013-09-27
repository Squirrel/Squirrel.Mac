//
//  SQRLURLConnectionOperationSpec.m
//  Squirrel
//
//  Created by Keith Duncan on 27/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLURLConnectionOperation.h"

SpecBegin(SQRLURLConnectionOperation)

it(@"should load file:// scheme URLs", ^{
	NSURL *fileLocation = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"test"];
	NSData *testContents = [@"test" dataUsingEncoding:NSUTF8StringEncoding];

	NSError *error = nil;
	BOOL write = [testContents writeToURL:fileLocation options:0 error:&error];
	expect(write).to.beTruthy();
	expect(error).to.beNil();

	SQRLURLConnectionOperation *operation = [[SQRLURLConnectionOperation alloc] initWithRequest:[NSURLRequest requestWithURL:fileLocation]];
	[operation start];
	expect(operation.isFinished).will.beTruthy();

	NSData *bodyData = operation.responseProvider(NULL, &error);
	expect(bodyData).to.equal(testContents);
	expect(error).to.beNil();
});

SpecEnd
