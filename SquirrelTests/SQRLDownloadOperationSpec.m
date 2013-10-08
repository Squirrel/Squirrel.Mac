//
//  SQRLDownloadOperationSpec.m
//  Squirrel
//
//  Created by Keith Duncan on 27/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDownloadOperation.h"
#import "SQRLDownloadController.h"
#import "SQRLResumableDownload.h"
#import "OHHTTPStubs/OHHTTPStubs.h"

SpecBegin(SQRLDownloadOperation);

__block SQRLDownloadController *downloadController;

beforeAll(^{
	downloadController = SQRLDownloadController.defaultDownloadController;

	NSError *error = nil;
	BOOL remove = [downloadController removeAllResumableDownloads:&error];
	expect(remove).to.beTruthy();
	expect(error).to.beNil();
});

beforeEach(^{
	Expecta.asynchronousTestTimeout = 60.;
});

afterAll(^{
	Expecta.asynchronousTestTimeout = 1.;
});

it(@"should download file:// scheme URLs", ^{
	NSURL *fileLocation = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"test"];
	NSData *testContents = [@"test" dataUsingEncoding:NSUTF8StringEncoding];

	NSError *error = nil;
	BOOL write = [testContents writeToURL:fileLocation options:0 error:&error];
	expect(write).to.beTruthy();
	expect(error).to.beNil();

	SQRLDownloadOperation *downloadOperation = [[SQRLDownloadOperation alloc] initWithRequest:[NSURLRequest requestWithURL:fileLocation] downloadController:downloadController];
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

it(@"should resume a download", ^{
	NSData *halfBody = [@"the quick brown fox jumped over the lazy doge" dataUsingEncoding:NSUTF8StringEncoding];

	NSMutableData *body = [halfBody mutableCopy];
	[body appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
	[body appendData:halfBody];

	NSDictionary *responseHeaders = @{
		@"Content-Length": [@(body.length) stringValue],
		@"ETag": NSProcessInfo.processInfo.globallyUniqueString,
	};

	id stub = [OHHTTPStubs shouldStubRequestsPassingTest:^ BOOL (NSURLRequest *request) {
		return YES;
	}
	withStubResponse:^ id (NSURLRequest *request) {
		OHHTTPStubsResponse *response = [OHHTTPStubsResponse responseWithData:halfBody statusCode:200 responseTime:0 headers:responseHeaders];
		//response.error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil];
		return response;
	}];

	NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://localhost/foo"]];
	SQRLDownloadOperation *downloadOperation = [[SQRLDownloadOperation alloc] initWithRequest:request downloadController:downloadController];
	[downloadOperation start];
	expect(downloadOperation.isFinished).will.beTruthy();

	[OHHTTPStubs removeRequestHandler:stub];

	NSError *error = nil;
	NSURL *result = [downloadOperation completionProvider:NULL error:&error];
	expect(result).to.beNil();
	expect(error).notTo.beNil();

	error = nil;

	SQRLResumableDownload *download = [downloadController downloadForRequest:request error:&error];
	expect(download).notTo.beNil();
	expect(error).to.beNil();

	NSData *downloadedData = [NSData dataWithContentsOfURL:download.fileURL options:0 error:&error];
	expect(downloadedData).to.equal(halfBody);
	expect(error).to.beNil();

	stub = [OHHTTPStubs shouldStubRequestsPassingTest:^ BOOL (NSURLRequest *request) {
		return YES;
	}
	withStubResponse:^ id (NSURLRequest *request) {
		return [OHHTTPStubsResponse responseWithData:body statusCode:200 responseTime:0 headers:responseHeaders];
	}];

	downloadOperation = [[SQRLDownloadOperation alloc] initWithRequest:request downloadController:downloadController];
	[downloadOperation start];
	expect(downloadOperation.isFinished).will.beTruthy();

	[OHHTTPStubs removeRequestHandler:stub];

	result = [downloadOperation completionProvider:NULL error:&error];
	expect(result).notTo.beNil();
	expect(error).to.beNil();

	downloadedData = [NSData dataWithContentsOfURL:result options:0 error:&error];
	expect(downloadedData).to.equal(body);
	expect(error).to.beNil();
});

SpecEnd
