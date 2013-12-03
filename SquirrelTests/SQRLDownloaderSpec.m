//
//  SQRLDownloadOperationSpec.m
//  Squirrel
//
//  Created by Keith Duncan on 27/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDownloader.h"
#import "SQRLDownloadManager.h"
#import "SQRLResumableDownload.h"
#import <ReactiveCocoa/EXTScope.h>
#import "NSError+SQRLVerbosityExtensions.h"
#import "SQRLHTTPServer.h"

SpecBegin(SQRLDownload);

__block SQRLDownloadManager *downloadManager;

beforeAll(^{
	downloadManager = SQRLDownloadManager.defaultDownloadManager;

	NSError *removeError = nil;
	BOOL remove = [[downloadManager
		removeAllResumableDownloads]
		waitUntilCompleted:&removeError];
	expect(remove).to.beTruthy();
	expect(removeError).to.beNil();
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

	SQRLDownloader *downloadOperation = [[SQRLDownloader alloc] initWithRequest:[NSURLRequest requestWithURL:fileLocation] downloadManager:downloadManager];
	RACTuple *result = [[downloadOperation download] firstOrDefault:nil success:NULL error:&error];
	expect(result).notTo.beNil();
	expect(error).to.beNil();

	RACTupleUnpack(__unused NSURLResponse *response, NSURL *location) = result;
	NSData *downloadContents = [NSData dataWithContentsOfURL:location options:0 error:&error];
	expect(downloadContents.length).to.equal(testContents.length);
	expect(downloadContents).to.equal(testContents);
	expect(error).to.beNil();

	expect(downloadContents).to.equal(testContents);
});

static NSData * (^stringTimes)(NSString *, NSUInteger) = ^ (NSString *string, NSUInteger times) {
	NSData *stringData = [string dataUsingEncoding:NSUTF8StringEncoding];
	NSMutableData *data = [NSMutableData dataWithCapacity:(stringData.length + 2) * times];
	for (NSUInteger idx = 0; idx < times; idx++) {
		[data appendData:stringData];
		[data appendData:[NSData dataWithBytes:"\r\n" length:2]];
	}
	return data;
};

static SQRLHTTPServer * (^newHttpServer)(SQRLTestCase *) = ^ (SQRLTestCase *self) {
	SQRLHTTPServer *server = [[SQRLHTTPServer alloc] init];

	[self addCleanupBlock:^{
		[server invalidate];
	}];

	return server;
};

it(@"should resume a download", ^{
	// Start server

	SQRLHTTPServer *server = newHttpServer(self);

	NSError *error = nil;
	NSURL *baseURL = [server start:&error];
	expect(baseURL).notTo.beNil();
	expect(error).to.beNil();

	error = nil;


	// Prepare half response

	NSData *firstHalf = stringTimes(@"the quick brown fox", 100);
	NSData *secondHalf = stringTimes(@"jumped over the lazy doge", 100);

	NSString *ETag = NSProcessInfo.processInfo.globallyUniqueString;

	CFHTTPMessageRef serverResponse = (__bridge CFHTTPMessageRef)CFBridgingRelease(CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1));
	NSDictionary *responseHeaders = @{
		@"Content-Length": [@(firstHalf.length + secondHalf.length) stringValue],
		@"ETag": ETag,
	};
	[responseHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
		CFHTTPMessageSetHeaderFieldValue(serverResponse, (__bridge CFStringRef)key, (__bridge CFStringRef)obj);
	}];
	CFHTTPMessageSetBody(serverResponse, (__bridge CFDataRef)firstHalf);

	server.responseBlock = ^ (CFHTTPMessageRef request) {
		NSString *ifRange = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(request, CFSTR("If-Range")));
		expect(ifRange).to.beNil();

		NSString *range = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(request, CFSTR("Range")));
		expect(range).to.beNil();

		return serverResponse;
	};


	// Issue first request

	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:baseURL];
	request.timeoutInterval = 1.;
	SQRLDownloader *downloadOperation = [[SQRLDownloader alloc] initWithRequest:request downloadManager:downloadManager];
	RACTuple *result = [[downloadOperation download] firstOrDefault:nil success:NULL error:&error];
	expect(result).to.beNil();
	expect(error).notTo.beNil();

	error = nil;

	SQRLResumableDownload *download = [[downloadManager downloadForRequest:request] firstOrDefault:nil success:NULL error:&error];
	expect(download).notTo.beNil();
	expect(error).to.beNil();

	NSData *downloadedData = [NSData dataWithContentsOfURL:download.fileURL options:0 error:&error];
	expect(downloadedData.length).to.equal(firstHalf.length);
	expect(downloadedData).to.equal(firstHalf);
	expect(error).to.beNil();


	// Prepare remainder response

	serverResponse = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 206, NULL, kCFHTTPVersion1_1);
	responseHeaders = @{
		@"Content-Length": [@(secondHalf.length) stringValue],
		@"Range": [NSString stringWithFormat:@"%lu-%lu", firstHalf.length, secondHalf.length - 1],
		@"ETag": ETag,
	};
	[responseHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
		CFHTTPMessageSetHeaderFieldValue(serverResponse, (__bridge CFStringRef)key, (__bridge CFStringRef)obj);
	}];
	CFHTTPMessageSetBody(serverResponse, (__bridge CFDataRef)secondHalf);

	server.responseBlock = ^ (CFHTTPMessageRef request) {
		NSString *ifRange = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(request, CFSTR("If-Range")));
		expect(ifRange).to.equal(ETag);

		NSString *range = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(request, CFSTR("Range")));
		expect(range).to.equal(([NSString stringWithFormat:@"%lu-", firstHalf.length]));

		return serverResponse;
	};


	// Issue second request

	downloadOperation = [[SQRLDownloader alloc] initWithRequest:request downloadManager:downloadManager];
	result = [[downloadOperation download] firstOrDefault:nil success:NULL error:&error];
	expect(result).notTo.beNil();
	expect(error).to.beNil();

	NSURL *location = result.second;

	NSMutableData *fullBody = [firstHalf mutableCopy];
	[fullBody appendData:secondHalf];

	downloadedData = [NSData dataWithContentsOfURL:location options:0 error:&error];
	expect(downloadedData.length).to.equal(fullBody.length);
	expect(downloadedData).to.equal(fullBody);
	expect(error).to.beNil();
});

it(@"should not resume downloads for a response with a different ETag", ^{
	// Start server

	SQRLHTTPServer *server = newHttpServer(self);

	NSError *error = nil;
	NSURL *baseURL = [server start:&error];
	expect(baseURL).notTo.beNil();
	expect(error).to.beNil();

	error = nil;


	// Prepare first response

	NSData *firstBody = stringTimes(@"the quick brown fox", 100);
	NSString *firstETag = NSProcessInfo.processInfo.globallyUniqueString;

	CFHTTPMessageRef serverResponse = (__bridge CFHTTPMessageRef)CFBridgingRelease(CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1));
	NSDictionary *responseHeaders = @{
		// Claim the response to be longer so that the connection will timeout
		// waiting for the extra bytes
		@"Content-Length": [@(firstBody.length + 100) stringValue],
		@"ETag": firstETag,
	};
	[responseHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
		CFHTTPMessageSetHeaderFieldValue(serverResponse, (__bridge CFStringRef)key, (__bridge CFStringRef)obj);
	}];
	CFHTTPMessageSetBody(serverResponse, (__bridge CFDataRef)firstBody);

	server.responseBlock = ^ (CFHTTPMessageRef request) {
		NSString *ifRange = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(request, CFSTR("If-Range")));
		expect(ifRange).to.beNil();

		NSString *range = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(request, CFSTR("Range")));
		expect(range).to.beNil();

		return serverResponse;
	};


	// Issue first request

	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:baseURL];
	request.timeoutInterval = 1.;
	SQRLDownloader *downloadOperation = [[SQRLDownloader alloc] initWithRequest:request downloadManager:downloadManager];
	RACTuple *result = [[downloadOperation download] firstOrDefault:nil success:NULL error:&error];
	expect(result).to.beNil();
	expect(error).notTo.beNil();

	error = nil;

	SQRLResumableDownload *download = [[downloadManager downloadForRequest:request] firstOrDefault:nil success:NULL error:&error];
	expect(download).notTo.beNil();
	expect(error).to.beNil();

	NSData *downloadedData = [NSData dataWithContentsOfURL:download.fileURL options:0 error:&error];
	expect(downloadedData.length).to.equal(firstBody.length);
	expect(downloadedData).to.equal(firstBody);
	expect(error).to.beNil();


	// Prepare second response

	NSData *secondBody = stringTimes(@"jumps over the lazy doge", 100);
	NSString *secondETag = NSProcessInfo.processInfo.globallyUniqueString;

	serverResponse = (__bridge CFHTTPMessageRef)CFBridgingRelease(CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1));
	responseHeaders = @{
		@"Content-Length": [@(secondBody.length) stringValue],
		@"ETag": secondETag,
	};
	[responseHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
		CFHTTPMessageSetHeaderFieldValue(serverResponse, (__bridge CFStringRef)key, (__bridge CFStringRef)obj);
	}];
	CFHTTPMessageSetBody(serverResponse, (__bridge CFDataRef)secondBody);

	server.responseBlock = ^ (CFHTTPMessageRef request) {
		NSString *ifRange = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(request, CFSTR("If-Range")));
		expect(ifRange).to.equal(firstETag);

		NSString *range = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(request, CFSTR("Range")));
		expect(range).to.equal(([NSString stringWithFormat:@"%lu-", firstBody.length]));

		return serverResponse;
	};


	// Issue second request

	downloadOperation = [[SQRLDownloader alloc] initWithRequest:request downloadManager:downloadManager];
	result = [[downloadOperation download] firstOrDefault:nil success:NULL error:&error];
	expect(result).notTo.beNil();
	expect(error).to.beNil();

	NSURL *location = result.second;

	downloadedData = [NSData dataWithContentsOfURL:location options:0 error:&error];
	expect(downloadedData.length).to.equal(secondBody.length);
	expect(downloadedData).to.equal(secondBody);
	expect(error).to.beNil();
});

SpecEnd
