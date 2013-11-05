//
//  SQRLDownloadOperation.m
//  Squirrel
//
//  Created by Keith Duncan on 25/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDownloadOperation.h"

#import "ReactiveCocoa/ReactiveCocoa.h"
#import "ReactiveCocoa/EXTScope.h"

#import "SQRLResumableDownloadManager.h"
#import "SQRLResumableDownload.h"

@interface SQRLDownloadOperation () <NSURLConnectionDataDelegate>
// Request the operation was initialised with.
@property (nonatomic, copy, readonly) NSURLRequest *request;
// Download manager for resumable state.
@property (nonatomic, strong, readonly) SQRLResumableDownloadManager *downloadManager;

// Connection to retreive the remote resource.
@property (nonatomic, strong) NSURLConnection *connection;

// Download that the body is being saved to.
@property (nonatomic, strong) SQRLResumableDownload *currentDownload;
// Latest response received from connection.
@property (nonatomic, strong) NSURLResponse *currentResponse;

// Events arising from the `NSURLConnection` are sent on this subject.
@property (nonatomic, strong) RACSubject *connectionSubject;
@end

@implementation SQRLDownloadOperation

- (instancetype)initWithRequest:(NSURLRequest *)request downloadManager:(SQRLResumableDownloadManager *)downloadManager {
	NSParameterAssert(request != nil);
	NSParameterAssert(downloadManager != nil);

	self = [self init];
	if (self == nil) return nil;

	_request = [request copy];

	_downloadManager = downloadManager;

	return self;
}

#pragma mark Download

// Returns a signal which sends the resumable download for `request` from
// `downloadManager` then completes, or errors.
- (RACSignal *)resumableDownload {
	return [[self.downloadManager
		downloadForRequest:self.request]
		setNameWithFormat:@"%@ %s", self, sel_getName(_cmd)];
}

// Returns a signal which sends a tuple of SQRLResumableDownload and the request
// that should be performed for that download. Either the original request or a
// new request with the state added to resume a prior download, then completes,
// or errors.
- (RACSignal *)resumeRequest {
	return [[[self
		resumableDownload]
		map:^(SQRLResumableDownload *resumableDownload) {
			NSURLRequest *originalRequest = self.request;
			RACTuple *originalTuple = RACTuplePack(resumableDownload, originalRequest);

			NSHTTPURLResponse *response = resumableDownload.response;
			NSString *ETag = [self.class ETagFromResponse:response];
			if (ETag == nil) return originalTuple;

			NSURL *downloadLocation = resumableDownload.fileURL;

			NSNumber *alreadyDownloadedSize = nil;
			NSError *alreadyDownloadedSizeError = nil;
			BOOL getAlreadyDownloadedSize = [downloadLocation getResourceValue:&alreadyDownloadedSize forKey:NSURLFileSizeKey error:&alreadyDownloadedSizeError];
			if (!getAlreadyDownloadedSize) return originalTuple;

			NSMutableURLRequest *newRequest = [originalRequest mutableCopy];
			[newRequest setValue:ETag forHTTPHeaderField:@"If-Range"];
			[newRequest setValue:[NSString stringWithFormat:@"%llu-", alreadyDownloadedSize.unsignedLongLongValue] forHTTPHeaderField:@"Range"];
			return RACTuplePack(resumableDownload, newRequest);
		}]
		setNameWithFormat:@"%@ %s", self, sel_getName(_cmd)];
}

+ (NSString *)ETagFromResponse:(NSHTTPURLResponse *)response {
	NSDictionary *headers = response.allHeaderFields;
	for (NSString *header in headers) {
		if ([header caseInsensitiveCompare:@"ETag"] != NSOrderedSame) continue;
		return headers[header];
	}
	return nil;
}

- (RACSignal *)download {
	return [[[self
		resumeRequest]
		flattenMap:^(RACTuple *downloadRequestTuple) {
			return [RACSignal createSignal:^ RACDisposable * (id<RACSubscriber> subscriber) {
				RACTupleUnpack(SQRLResumableDownload *download, NSURLRequest *request) = downloadRequestTuple;
				[self startDownload:download withRequest:request];

				NSURLConnection *connection = self.connection;
				RACSubject *connectionSubject = self.connectionSubject;

				RACDisposable *subscriptionDisposable = [connectionSubject subscribe:subscriber];

				RACDisposable *connectionDisposable = [RACDisposable disposableWithBlock:^{
					[connection cancel];
				}];

				return [RACCompoundDisposable compoundDisposableWithDisposables:@[ subscriptionDisposable, connectionDisposable ]];
			}];
		}]
		setNameWithFormat:@"%@ %s", self, sel_getName(_cmd)];
}

- (void)startDownload:(SQRLResumableDownload *)download withRequest:(NSURLRequest *)request {
	self.currentDownload = download;

	self.connectionSubject = [RACSubject subject];

	self.connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
	self.connection.delegateQueue = [[NSOperationQueue alloc] init];
	[self.connection start];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
	[self.connectionSubject sendError:error];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
	self.currentResponse = response;

	// Can only resume HTTP responses which indicate whether we can resume
	if (![response isKindOfClass:NSHTTPURLResponse.class]) {
		[self removeDownloadFile];
		return;
	}

	NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;

	/*
		First truncate the file if necessary, then record the new ETag.

		This ensures old data doesn't get associated with a new ETag if we were
		to crash between setting the ETag and clearing the file.
	 */

	if (httpResponse.statusCode == /* OK */ 200) {
		[self removeDownloadFile];
	} else if (httpResponse.statusCode == /* Partial Content */ 206) {
		// This is the response we need to know we can append to our already
		// downloaded bytes, great success!
	}

	[self recordDownloadWithResponse:httpResponse];
}

- (void)removeDownloadFile {
	NSError *error = nil;
	BOOL remove = [NSFileManager.defaultManager removeItemAtURL:self.currentDownload.fileURL error:&error];
	if (!remove) {
		if (![error.domain isEqualToString:NSCocoaErrorDomain] || error.code != NSFileNoSuchFileError) {
			[self completeWithError:error];
		}

		return;
	}
}

- (void)recordDownloadWithResponse:(NSHTTPURLResponse *)response {
	SQRLResumableDownload *newDownload = [[SQRLResumableDownload alloc] initWithResponse:response fileURL:self.currentDownload.fileURL];
	self.currentDownload = newDownload;

	// Need to write the response we're saving data for to disk before writing
	// any data, ensures that bytes don't get associated with a rogue ETag.
	NSError *error = nil;
	BOOL result = [[self.downloadManager setDownload:newDownload forRequest:self.request] waitUntilCompleted:&error];
	if (!result) [self completeWithError:error];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
	NSOutputStream *outputStream = [NSOutputStream outputStreamWithURL:self.currentDownload.fileURL append:YES];

	[outputStream open];
	@onExit {
		[outputStream close];
	};

	uint8_t const *bytes = data.bytes;
	size_t length = data.length;
	while (1) {
		NSInteger written = [outputStream write:bytes maxLength:length];
		if (written == -1) {
			NSError *streamError = outputStream.streamError;
			if ([streamError.domain isEqualToString:NSPOSIXErrorDomain] && streamError.code == EINTR) continue;

			[self completeWithError:streamError];
			return;
		}

		if ((NSUInteger)written == length) {
			return;
		}

		bytes += written;
		length -= written;
	}
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
	NSURL *localURL = self.currentDownload.fileURL;
	NSURLResponse *response = self.currentResponse;

	[self.connectionSubject sendNext:RACTuplePack(response, localURL)];
	[self.connectionSubject sendCompleted];
}

- (void)completeWithError:(NSError *)error {
	[self.connection cancel];

	[self.connectionSubject sendError:error];
}

@end
