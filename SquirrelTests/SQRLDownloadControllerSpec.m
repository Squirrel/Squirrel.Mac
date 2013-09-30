//
//  SQRLDownloadControllerSpec.m
//  Squirrel
//
//  Created by Keith Duncan on 27/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDownloadController.h"
#import "SQRLResumableDownload.h"
#import "NSError+SQRLVerbosityExtensions.h"

SpecBegin(SQRLDownloadController)

__block SQRLDownloadController *downloadController = nil;

beforeAll(^{
	downloadController = SQRLDownloadController.defaultDownloadController;

	NSError *removeError = nil;
	BOOL remove = [downloadController removeAllResumableDownloads:&removeError];
	if (!remove) NSLog(@"Couldn’t remove resumable downloads %@", removeError.sqrl_verboseDescription);
});

NSURL * (^newTestURL)() = ^ () {
	return [[NSURL alloc] initWithScheme:@"http" host:@"localhost" path:[@"/" stringByAppendingString:NSProcessInfo.processInfo.globallyUniqueString]];
};

NSURL * (^newDownloadURL)() = ^ () {
	SQRLResumableDownload *download = [downloadController downloadForRequest:[NSURLRequest requestWithURL:newTestURL()]];
	expect(download).notTo.beNil();

	NSURL *downloadURL = download.fileURL;
	expect(downloadURL).notTo.beNil();

	return downloadURL;
};

it(@"should return a file that doesn't exist yet for new URLs", ^{
	NSURL *downloadURL = newDownloadURL();

	BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:downloadURL.path];
	expect(exists).to.beFalsy();
});

it(@"should return a path in a writable directory for new URLs", ^{
	NSURL *downloadURL = newDownloadURL();

	BOOL writable = [NSFileManager.defaultManager isWritableFileAtPath:downloadURL.URLByDeletingLastPathComponent.path];
	expect(writable).to.beTruthy();
});

it(@"should return the same path for the same URL", ^{
	NSURL *testURL = newTestURL();

	SQRLResumableDownload *download1 = [downloadController downloadForRequest:[NSURLRequest requestWithURL:testURL]];
	SQRLResumableDownload *download2 = [downloadController downloadForRequest:[NSURLRequest requestWithURL:testURL]];
 
	expect(download1).to.equal(download2);
});

it(@"should remember a response", ^{
	NSURLRequest *request = [NSURLRequest requestWithURL:newTestURL()];
	NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200 HTTPVersion:(__bridge NSString *)kCFHTTPVersion1_1 headerFields:@{ @"ETag": NSProcessInfo.processInfo.globallyUniqueString }];

	SQRLResumableDownload *initialDownload = [downloadController downloadForRequest:request];

	SQRLResumableDownload *newDownload = [[SQRLResumableDownload alloc] initWithResponse:response fileURL:initialDownload.fileURL];
	[downloadController setDownload:newDownload forRequest:request];
	expect(initialDownload).notTo.equal(newDownload);

	SQRLResumableDownload *resumedDownload = [downloadController downloadForRequest:request];
	expect(resumedDownload).to.equal(newDownload);
});

SpecEnd
