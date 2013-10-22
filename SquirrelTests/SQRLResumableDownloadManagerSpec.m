//
//  SQRLDownloadControllerSpec.m
//  Squirrel
//
//  Created by Keith Duncan on 27/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLResumableDownloadManager.h"
#import "SQRLResumableDownload.h"
#import "NSError+SQRLVerbosityExtensions.h"
#import "ReactiveCocoa/ReactiveCocoa.h"

SpecBegin(SQRLResumableDownloadManager)

__block SQRLResumableDownloadManager *downloadManager = nil;

beforeAll(^{
	downloadManager = SQRLResumableDownloadManager.defaultDownloadManager;

	NSError *removeError = nil;
	BOOL remove = [[downloadManager removeAllResumableDownloads] waitUntilCompleted:&removeError];
	if (!remove) {
		if ([removeError.domain isEqualToString:NSCocoaErrorDomain] && removeError.code == NSFileNoSuchFileError) return;
		
		NSLog(@"Couldn’t remove resumable downloads %@", removeError.sqrl_verboseDescription);
	}
});

NSURL * (^newTestURL)() = ^ () {
	return [[NSURL alloc] initWithScheme:@"http" host:@"localhost" path:[@"/" stringByAppendingString:NSProcessInfo.processInfo.globallyUniqueString]];
};

NSURL * (^newDownloadURL)() = ^ () {
	NSError *error = nil;
	SQRLResumableDownload *download = [downloadManager downloadForRequest:[NSURLRequest requestWithURL:newTestURL()] error:&error];
	expect(download).notTo.beNil();
	expect(error).to.beNil();

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

	SQRLResumableDownload *download1 = [downloadManager downloadForRequest:[NSURLRequest requestWithURL:testURL] error:NULL];
	SQRLResumableDownload *download2 = [downloadManager downloadForRequest:[NSURLRequest requestWithURL:testURL] error:NULL];
	expect(download1).notTo.beNil();
	expect(download1).to.equal(download2);
});

it(@"should remember a response", ^{
	NSURLRequest *request = [NSURLRequest requestWithURL:newTestURL()];
	NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200 HTTPVersion:(__bridge NSString *)kCFHTTPVersion1_1 headerFields:@{ @"ETag": NSProcessInfo.processInfo.globallyUniqueString }];

	SQRLResumableDownload *initialDownload = [downloadManager downloadForRequest:request error:NULL];

	SQRLResumableDownload *newDownload = [[SQRLResumableDownload alloc] initWithResponse:response fileURL:initialDownload.fileURL];
	[downloadManager setDownload:newDownload forRequest:request];
	expect(initialDownload).notTo.equal(newDownload);

	SQRLResumableDownload *resumedDownload = [downloadManager downloadForRequest:request error:NULL];
	expect(resumedDownload).to.equal(newDownload);
});

SpecEnd
