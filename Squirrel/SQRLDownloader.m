//
//  SQRLDownloadOperation.m
//  Squirrel
//
//  Created by Keith Duncan on 25/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDownloader.h"

#import <ReactiveCocoa/ReactiveCocoa.h>
#import <ReactiveCocoa/EXTScope.h>

#import "SQRLDownloadManager.h"
#import "SQRLResumableDownload.h"

@interface SQRLDownloader ()
// Request the operation was initialised with.
@property (nonatomic, copy, readonly) NSURLRequest *request;
// Download manager for resumable state.
@property (nonatomic, strong, readonly) SQRLDownloadManager *downloadManager;

// Connection to retreive the remote resource.
@property (nonatomic, strong) NSURLConnection *connection;

// Returns a signal which sends the download for `request` from
// `downloadManager` then completes, or errors.
@property (nonatomic, readonly, strong) RACSignal *initialisedDownload;

// Returns a signal which will complete when the `NSURLConnection` completes.
@property (readonly, nonatomic, strong) RACSignal *connectionFinished;
@end

@implementation SQRLDownloader

- (instancetype)initWithRequest:(NSURLRequest *)request downloadManager:(SQRLDownloadManager *)downloadManager {
	NSParameterAssert(request != nil);
	NSParameterAssert(downloadManager != nil);

	self = [self init];
	if (self == nil) return nil;

	_request = [request copy];

	_downloadManager = downloadManager;

	_initialisedDownload = [[downloadManager
		downloadForRequest:request]
		replayLast];

	_connectionFinished = [[[self
		rac_signalForSelector:@selector(connectionDidFinishLoading:)]
		flattenMap:^(id _) {
			return RACSignal.empty;
		}]
		replay];

	return self;
}

#pragma mark Download

- (void)startDownloadWithRequest:(NSURLRequest *)request {
	NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
	delegateQueue.maxConcurrentOperationCount = 1;

	self.connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
	self.connection.delegateQueue = delegateQueue;
	[self.connection start];
}

- (RACSignal *)truncateDownload:(SQRLDownload *)download {
	return [[[[RACSignal
		defer:^{
			NSError *error = nil;
			BOOL remove = [NSFileManager.defaultManager removeItemAtURL:download.fileURL error:&error];
			return (remove ? RACSignal.empty : [RACSignal error:error]);
		}]
		catch:^(NSError *error) {
			if ([error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileNoSuchFileError) return RACSignal.empty;
			return [RACSignal error:error];
		}]
		concat:[RACSignal return:download]]
		setNameWithFormat:@"%@ %s %@", self, sel_getName(_cmd), download];
}

- (RACSignal *)recordDownload:(SQRLResumableDownload *)download {
	return [[[self.downloadManager
		setDownload:download forRequest:self.request]
		concat:[RACSignal return:download]]
		setNameWithFormat:@"%@ %s %@", self, sel_getName(_cmd), download];
}

- (RACSignal *)prepareDownloadForResponse:(NSURLResponse *)response {
	return [[[self
		initialisedDownload]
		flattenMap:^(SQRLDownload *download) {
			if (![response isKindOfClass:NSHTTPURLResponse.class]) {
				return [self truncateDownload:download];
			}

			NSHTTPURLResponse *httpResponse = (id)response;

			RACSignal *downloadSignal;
			if (httpResponse.statusCode != 206 /* Partial Data */) {
				downloadSignal = [self truncateDownload:download];
			} else {
				downloadSignal = RACSignal.empty;
			}

			SQRLResumableDownload *newDownload = [[SQRLResumableDownload alloc] initWithRequest:self.request response:httpResponse fileURL:download.fileURL];

			return [downloadSignal
				concat:[self recordDownload:newDownload]];
		}]
		setNameWithFormat:@"%@ %s %@", self, sel_getName(_cmd), response];
}

- (BOOL)appendData:(NSData *)data toURL:(NSURL *)fileURL error:(NSError **)errorRef {
	NSOutputStream *outputStream = [NSOutputStream outputStreamWithURL:fileURL append:YES];

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

			if (errorRef != NULL) *errorRef = streamError;
			return NO;
		}

		if ((NSUInteger)written == length) break;
		
		bytes += written;
		length -= written;
	}

	return YES;
}

- (RACSignal *)errorsSignal {
	return [[[[self
		rac_signalForSelector:@selector(connection:didFailWithError:)]
		reduceEach:^(id _, NSError *error) {
			return [RACSignal error:error];
		}]
		flatten]
		setNameWithFormat:@"%@ %s", self, sel_getName(_cmd)];
}

- (RACSignal *)dataSignalWithResponse:(NSURLResponse *)response {
	RACSignal *downloadForResponse = [RACSignal
		defer:^{
			return [[self
				prepareDownloadForResponse:response]
				replayLast];
		}];

	return [[[[[self
		rac_signalForSelector:@selector(connection:didReceiveData:)]
		takeUntil:self.connectionFinished]
		reduceEach:^(id _, NSData *bodyData) {
			return [[downloadForResponse
				map:^(SQRLDownload *download) {
					return download.fileURL;
				}]
				try:^(NSURL *fileURL, NSError **errorRef) {
					return [self appendData:bodyData toURL:fileURL error:errorRef];
				}];
			}]
		concat]
		setNameWithFormat:@"%@ %s %@", self, sel_getName(_cmd), response];
}

- (RACSignal *)responseSignal {
	return [[[[[self
		rac_signalForSelector:@selector(connection:didReceiveResponse:)]
		takeUntil:self.connectionFinished]
		reduceEach:^(id _, NSURLResponse *response) {
			return [self dataSignalWithResponse:response];
		}]
		switchToLatest]
		setNameWithFormat:@"%@ %s", self, sel_getName(_cmd)];
}

- (RACSignal *)connectionSignalWithRequest:(NSURLRequest *)request {
	return [[RACSignal
		createSignal:^(id<RACSubscriber> subscriber) {
			RACCompoundDisposable *disposable = [[RACCompoundDisposable alloc] init];

			[disposable addDisposable:[[self responseSignal] subscribe:subscriber]];
			[disposable addDisposable:[[self errorsSignal] subscribe:subscriber]];

			[self startDownloadWithRequest:request];

			[disposable addDisposable:[RACDisposable disposableWithBlock:^{
				[self.connection cancel];
			}]];

			return disposable;
		}]
		setNameWithFormat:@"%@ %s %@", self, sel_getName(_cmd), request];
}

- (RACSignal *)download {
	return [[[[self
		initialisedDownload]
		flattenMap:^(SQRLDownload *download) {
			return [download resumableRequest];
		}]
		flattenMap:^(NSURLRequest *request) {
			return [self connectionSignalWithRequest:request];
		}]
		setNameWithFormat:@"%@ %s", self, sel_getName(_cmd)];
}

@end
