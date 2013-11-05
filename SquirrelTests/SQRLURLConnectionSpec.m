//
//  SQRLURLConnectionOperationSpec.m
//  Squirrel
//
//  Created by Keith Duncan on 27/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLURLConnection.h"

SpecBegin(SQRLURLConnection)

it(@"should load file:// scheme URLs", ^{
	NSURL *fileLocation = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"test"];
	NSData *testContents = [@"test" dataUsingEncoding:NSUTF8StringEncoding];

	NSError *error = nil;
	BOOL write = [testContents writeToURL:fileLocation options:0 error:&error];
	expect(write).to.beTruthy();
	expect(error).to.beNil();

	RACSignal *connection = [SQRLURLConnection sqrl_sendAsynchronousRequest:[NSURLRequest requestWithURL:fileLocation]];
	RACTuple *response = [connection firstOrDefault:nil success:NULL error:&error];
	expect(response).notTo.beNil();
	expect(error).to.beNil();

	expect(response[1]).to.equal(testContents);
});

SpecEnd
