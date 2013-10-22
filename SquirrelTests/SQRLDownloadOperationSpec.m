//
//  SQRLDownloadOperationSpec.m
//  Squirrel
//
//  Created by Keith Duncan on 27/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDownloadOperation.h"
#import "SQRLResumableDownloadManager.h"
#import "SQRLResumableDownload.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import "ReactiveCocoa/EXTScope.h"
#import "NSError+SQRLVerbosityExtensions.h"

SpecBegin(SQRLDownloadOperation);

__block SQRLResumableDownloadManager *downloadManager;

beforeAll(^{
	downloadManager = SQRLResumableDownloadManager.defaultDownloadManager;

	NSError *removeError = nil;
	BOOL remove = [[downloadManager removeAllResumableDownloads] waitUntilCompleted:&removeError];
	if (!remove) {
		if ([removeError.domain isEqualToString:NSCocoaErrorDomain] && removeError.code == NSFileNoSuchFileError) return;

		NSLog(@"Couldn’t remove resumable downloads %@", removeError.sqrl_verboseDescription);
	}
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

	SQRLDownloadOperation *downloadOperation = [[SQRLDownloadOperation alloc] initWithRequest:[NSURLRequest requestWithURL:fileLocation] downloadManager:downloadManager];
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

__block CFHTTPMessageRef (^responseBlock)(CFHTTPMessageRef) = nil;

// Returns a retained dispatch object, releasing it closes the server
dispatch_source_t (^startTcpServer)(SQRLTestCase *, in_port_t *) = ^ dispatch_source_t (SQRLTestCase *self, in_port_t *portRef) {
	int listenSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);

	struct sockaddr_in listenAddress = {
		.sin_len = sizeof(listenAddress),
		.sin_family = AF_INET,
		.sin_port = 0,
		.sin_addr = {
			.s_addr = htonl(INADDR_LOOPBACK),
		},
	};
	int bindError = bind(listenSocket, (struct sockaddr const *)&listenAddress, listenAddress.sin_len);
	if (bindError != 0) {
		close(listenSocket);
		return NULL;
	}

	listen(listenSocket, 128);

	dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, listenSocket, 0, NULL);
	dispatch_source_set_event_handler(source, ^{
		int connectionSocket = accept(listenSocket, NULL, NULL);
		// Wait to close the connection until after the test case is complete.
		// We need NSURLConnection to timeout, closing the connection causes it
		// to error immediately.
		[self addCleanupBlock:^{
			close(connectionSocket);
		}];

		CFHTTPMessageRef request = (__bridge CFHTTPMessageRef)CFBridgingRelease(CFHTTPMessageCreateEmpty(kCFAllocatorDefault, true));

		while (1) {
			uint8_t buffer;
			ssize_t readLength = read(connectionSocket, &buffer, 1);
			if (readLength < 0) {
				return;
			}

			CFHTTPMessageAppendBytes(request, (UInt8 const *)&buffer, readLength);
			if (!CFHTTPMessageIsHeaderComplete(request)) {
				continue;
			}

			// Doesn't support reading requests with a body for simplicity
			NSString *contentLength = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(request, CFSTR("Content-Length")));
			if (contentLength != nil) {
				return;
			}

			break;
		}

		NSLog(@"Received Request:");
		NSLog(@"%@", [[NSString alloc] initWithData:CFBridgingRelease(CFHTTPMessageCopySerializedMessage(request)) encoding:NSASCIIStringEncoding]);

		CFHTTPMessageRef response = responseBlock(request);
		NSData *responseData = CFBridgingRelease(CFHTTPMessageCopySerializedMessage(response));

		NSLog(@"Sending Response:");
		NSLog(@"%@", [[NSString alloc] initWithData:responseData encoding:NSASCIIStringEncoding]);

		size_t bufferLength = responseData.length;
		uint8_t const *buffer = responseData.bytes;

		while (1) {
			ssize_t writeLength = write(connectionSocket, buffer, bufferLength);
			if (writeLength < 0) {
				return;
			}

			buffer += writeLength;
			bufferLength -= writeLength;

			if (bufferLength == 0) {
				break;
			}
		}
	});
	dispatch_source_set_cancel_handler(source, ^{
		close(listenSocket);
	});
	dispatch_resume(source);

	struct sockaddr_storage localAddress = {};
	socklen_t localAddressLength = sizeof(localAddress);
	int localAddressError = getsockname(listenSocket, (struct sockaddr *)&localAddress, &localAddressLength);
	expect(localAddressError).to.equal(0);

	// IPv4 and IPv6 address transport layer port fields are at the same offset
	// and are the same size
	in_port_t port = ntohs(((struct sockaddr_in *)&localAddress)->sin_port);
	expect(port).to.beGreaterThan(0);
	*portRef = port;

	return source;
};

static NSData * (^stringTimes)(NSString *, NSUInteger) = ^ (NSString *string, NSUInteger times) {
	NSData *stringData = [string dataUsingEncoding:NSUTF8StringEncoding];
	NSMutableData *data = [NSMutableData dataWithCapacity:(stringData.length + 2) * times];
	for (NSUInteger idx = 0; idx < times; idx++) {
		[data appendData:stringData];
		[data appendData:[NSData dataWithBytes:"\r\n" length:2]];
	}
	return data;
};

it(@"should resume a download", ^{
	// Start server

	in_port_t port = 0;
	dispatch_source_t server = startTcpServer(self, &port);
	expect(server).notTo.beNil();
	@onExit {
		dispatch_release(server);
	};


	// Prepare half response

	NSData *firstHalf = stringTimes(@"the quick brown fox", 100);
	NSData *secondHalf = stringTimes(@"jumped over the lazy doge", 100);

	NSString *ETag = NSProcessInfo.processInfo.globallyUniqueString;

	CFHTTPMessageRef response = (__bridge CFHTTPMessageRef)CFBridgingRelease(CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1));
	NSDictionary *responseHeaders = @{
		@"Content-Length": [@(firstHalf.length + secondHalf.length) stringValue],
		@"ETag": ETag,
	};
	[responseHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
		CFHTTPMessageSetHeaderFieldValue(response, (__bridge CFStringRef)key, (__bridge CFStringRef)obj);
	}];
	CFHTTPMessageSetBody(response, (__bridge CFDataRef)firstHalf);

	responseBlock = ^ (CFHTTPMessageRef request) {
		NSString *ifRange = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(request, CFSTR("If-Range")));
		expect(ifRange).to.beNil();

		NSString *range = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(request, CFSTR("Range")));
		expect(range).to.beNil();

		return response;
	};


	// Issue first request

	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://localhost:%u/foo", port]]];
	request.timeoutInterval = 1.;
	SQRLDownloadOperation *downloadOperation = [[SQRLDownloadOperation alloc] initWithRequest:request downloadManager:downloadManager];
	[downloadOperation start];
	expect(downloadOperation.isFinished).will.beTruthy();

	NSError *error = nil;
	NSURL *result = [downloadOperation completionProvider:NULL error:&error];
	expect(result).to.beNil();
	expect(error).notTo.beNil();

	error = nil;

	SQRLResumableDownload *download = [[downloadManager downloadForRequest:request] firstOrDefault:nil success:NULL error:&error];
	expect(download).notTo.beNil();
	expect(error).to.beNil();

	NSData *downloadedData = [NSData dataWithContentsOfURL:download.fileURL options:0 error:&error];
	expect(downloadedData).to.equal(firstHalf);
	expect(error).to.beNil();


	// Prepare remainder response

	response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 206, NULL, kCFHTTPVersion1_1);
	responseHeaders = @{
		@"Content-Length": [@(secondHalf.length) stringValue],
		@"Range": [NSString stringWithFormat:@"%lu-%lu", firstHalf.length, secondHalf.length - 1],
		@"ETag": ETag,
	};
	[responseHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
		CFHTTPMessageSetHeaderFieldValue(response, (__bridge CFStringRef)key, (__bridge CFStringRef)obj);
	}];
	CFHTTPMessageSetBody(response, (__bridge CFDataRef)secondHalf);

	responseBlock = ^ (CFHTTPMessageRef request) {
		NSString *ifRange = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(request, CFSTR("If-Range")));
		expect(ifRange).to.equal(ETag);

		NSString *range = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(request, CFSTR("Range")));
		expect(range).to.equal(([NSString stringWithFormat:@"%lu-", firstHalf.length]));

		return response;
	};


	// Issue second request

	downloadOperation = [[SQRLDownloadOperation alloc] initWithRequest:request downloadManager:downloadManager];
	[downloadOperation start];
	expect(downloadOperation.isFinished).will.beTruthy();

	result = [downloadOperation completionProvider:NULL error:&error];
	expect(result).notTo.beNil();
	expect(error).to.beNil();

	NSMutableData *fullBody = [firstHalf mutableCopy];
	[fullBody appendData:secondHalf];

	downloadedData = [NSData dataWithContentsOfURL:result options:0 error:&error];
	expect(downloadedData).to.equal(fullBody);
	expect(error).to.beNil();
});

it(@"should not resume downloads for a response with a different ETag", ^{
	// Start server

	in_port_t port = 0;
	dispatch_source_t server = startTcpServer(self, &port);
	expect(server).notTo.beNil();
	@onExit {
		dispatch_release(server);
	};


	// Prepare first response

	NSData *firstBody = stringTimes(@"the quick brown fox", 100);
	NSString *firstETag = NSProcessInfo.processInfo.globallyUniqueString;

	CFHTTPMessageRef response = (__bridge CFHTTPMessageRef)CFBridgingRelease(CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1));
	NSDictionary *responseHeaders = @{
		// Claim the response to be longer so that the connection will timeout
		// waiting for the extra bytes
		@"Content-Length": [@(firstBody.length + 100) stringValue],
		@"ETag": firstETag,
	};
	[responseHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
		CFHTTPMessageSetHeaderFieldValue(response, (__bridge CFStringRef)key, (__bridge CFStringRef)obj);
	}];
	CFHTTPMessageSetBody(response, (__bridge CFDataRef)firstBody);

	responseBlock = ^ (CFHTTPMessageRef request) {
		NSString *ifRange = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(request, CFSTR("If-Range")));
		expect(ifRange).to.beNil();

		NSString *range = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(request, CFSTR("Range")));
		expect(range).to.beNil();

		return response;
	};


	// Issue first request

	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://localhost:%u/bar", port]]];
	request.timeoutInterval = 1.;
	SQRLDownloadOperation *downloadOperation = [[SQRLDownloadOperation alloc] initWithRequest:request downloadManager:downloadManager];
	[downloadOperation start];
	expect(downloadOperation.isFinished).will.beTruthy();

	NSError *error = nil;
	NSURL *result = [downloadOperation completionProvider:NULL error:&error];
	expect(result).to.beNil();
	expect(error).notTo.beNil();

	error = nil;

	SQRLResumableDownload *download = [[downloadManager downloadForRequest:request] firstOrDefault:nil success:NULL error:&error];
	expect(download).notTo.beNil();
	expect(error).to.beNil();

	NSData *downloadedData = [NSData dataWithContentsOfURL:download.fileURL options:0 error:&error];
	expect(downloadedData).to.equal(firstBody);
	expect(error).to.beNil();


	// Prepare second response

	NSData *secondBody = stringTimes(@"jumps over the lazy doge", 100);
	NSString *secondETag = NSProcessInfo.processInfo.globallyUniqueString;

	response = (__bridge CFHTTPMessageRef)CFBridgingRelease(CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1));
	responseHeaders = @{
		@"Content-Length": [@(secondBody.length) stringValue],
		@"ETag": secondETag,
	};
	[responseHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
		CFHTTPMessageSetHeaderFieldValue(response, (__bridge CFStringRef)key, (__bridge CFStringRef)obj);
	}];
	CFHTTPMessageSetBody(response, (__bridge CFDataRef)secondBody);

	responseBlock = ^ (CFHTTPMessageRef request) {
		NSString *ifRange = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(request, CFSTR("If-Range")));
		expect(ifRange).to.equal(firstETag);

		NSString *range = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(request, CFSTR("Range")));
		expect(range).to.equal(([NSString stringWithFormat:@"%lu-", firstBody.length]));

		return response;
	};


	// Issue second request

	downloadOperation = [[SQRLDownloadOperation alloc] initWithRequest:request downloadManager:downloadManager];
	[downloadOperation start];
	expect(downloadOperation.isFinished).will.beTruthy();

	result = [downloadOperation completionProvider:NULL error:&error];
	expect(result).notTo.beNil();
	expect(error).to.beNil();

	downloadedData = [NSData dataWithContentsOfURL:result options:0 error:&error];
	expect(downloadedData).to.equal(secondBody);
	expect(error).to.beNil();
});

SpecEnd
