//
//  SQRLDownloadOperationSpec.m
//  Squirrel
//
//  Created by Keith Duncan on 27/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDownloadOperation.h"

SpecBegin(SQRLDownloadOperation);

it(@"should download file:// scheme URLs", ^{
	NSURL *fileLocation = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"test"];
	NSData *testContents = [@"test" dataUsingEncoding:NSUTF8StringEncoding];

	NSError *error = nil;
	BOOL write = [testContents writeToURL:fileLocation options:0 error:&error];
	expect(write).to.beTruthy();
	expect(error).to.beNil();

	SQRLDownloadOperation *downloadOperation = [[SQRLDownloadOperation alloc] initWithRequest:[NSURLRequest requestWithURL:fileLocation]];
	[downloadOperation start];
	expect(downloadOperation.isFinished).will.beTruthy();

	NSURL *downloadURL = [downloadOperation completionProvider:NULL error:&error];
	expect(downloadURL).notTo.beNil();
	expect(error).to.beNil();

	NSData *downloadContents = [NSData dataWithContentsOfURL:downloadURL options:0 error:&error];
	expect(downloadContents).notTo.beNil();
	expect(error).to.beNil();

	expect(downloadContents).to.equal(testContents);
});

SpecEnd
