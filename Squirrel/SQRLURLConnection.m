//
//  SQRLURLConnection.m
//  Squirrel
//
//  Created by Keith Duncan on 25/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLURLConnection.h"

#import <ReactiveCocoa/ReactiveCocoa.h>
#import <ReactiveCocoa/EXTScope.h>

#import "SQRLDownloadManager.h"
#import "SQRLResumableDownload.h"

@interface SQRLURLConnection ()
// The request the downloader was initialised with.
@property (nonatomic, copy, readonly) NSURLRequest *request;

// Listens for invocations of `selector` on the receiver.
//
// The first argument of `selector` must be an `NSURLConnection` object.
//
// Returns a signal which sends the _second_ argument of `selector`, or
// RACUnit if there is only one argument, then completes when the receiver
// deallocates.
- (RACSignal *)signalForDelegateSelector:(SEL)selector;

// Subscribes to the connection delegate selectors and starts a connection for
// `request`.
//
// request - The request to perform, must not be nil.
// mapData - For each response, map the data received for that response to a
//           result.
//
// Returns a signal which sends a tuple of the last response, and the first
// value from the last `mapData`, then completes, or errors.
- (RACSignal *)connectionSignalWithRequest:(NSURLRequest *)request mapData:(RACSignal * (^)(NSURLResponse *, RACSignal *))mapData;

@end

@implementation SQRLURLConnection

- (instancetype)initWithRequest:(NSURLRequest *)request {
	NSParameterAssert(request != nil);

	self = [self init];
	if (self == nil) return nil;

	_request = [request copy];

	return self;
}

- (RACSignal *)signalForDelegateSelector:(SEL)selector {
	NSParameterAssert(selector != NULL);

	return [[self
		rac_signalForSelector:selector]
		map:^(RACTuple *args) {
			return args[1] ?: RACUnit.defaultUnit;
		}];
}

- (RACSignal *)connectionSignalWithRequest:(NSURLRequest *)request mapData:(RACSignal * (^)(NSURLResponse *, RACSignal *))mapData {
	return [[RACSignal
		create:^(id<RACSubscriber> subscriber) {
			// A signal that will error if the connection fails for any reason.
			RACSignal *errors = [[self
				signalForDelegateSelector:@selector(connection:didFailWithError:)]
				flattenMap:^(NSError *error) {
					return [RACSignal error:error];
				}];

			// Sends (or replays) RACUnit when the connection has finished
			// loading successfully.
			RACSignal *finished = [[[[self
				signalForDelegateSelector:@selector(connectionDidFinishLoading:)]
				take:1]
				promiseOnScheduler:RACScheduler.immediateScheduler]
				start];

			// A signal of all `NSURLResponse`s received on the connection.
			RACSignal *responses = [[self
				signalForDelegateSelector:@selector(connection:didReceiveResponse:)]
				takeUntil:finished];

			// A signal of all `NSData` received on the connection.
			RACSignal *data = [[self
				signalForDelegateSelector:@selector(connection:didReceiveData:)]
				takeUntil:finished];

			[[[[[RACSignal
				merge:@[ responses, errors ]]
				takeUntil:finished]
				map:^(NSURLResponse *response) {
					return [RACSignal
						zip:@[
							[RACSignal return:response],
							mapData(response, data),
						]];
				}]
				switchToLatest]
				subscribe:subscriber];

			NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
			delegateQueue.maxConcurrentOperationCount = 1;

			NSURLConnection *connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
			connection.delegateQueue = delegateQueue;

			[connection start];

			[subscriber.disposable addDisposable:[RACDisposable disposableWithBlock:^{
				[connection cancel];
			}]];
		}]
		setNameWithFormat:@"%@ %s %@", self, sel_getName(_cmd), request];
}

#pragma mark Download

- (RACSignal *)truncateDownload:(SQRLDownload *)download {
	NSParameterAssert(download != nil);

	return [[[[RACSignal
		defer:^{
			NSError *error = nil;
			BOOL remove = [NSFileManager.defaultManager removeItemAtURL:download.fileURL error:&error];
			return (remove ? [RACSignal empty] : [RACSignal error:error]);
		}]
		catch:^(NSError *error) {
			if ([error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileNoSuchFileError) return [RACSignal empty];
			return [RACSignal error:error];
		}]
		concat:[RACSignal return:download]]
		setNameWithFormat:@"%@ %s %@", self, sel_getName(_cmd), download];
}

- (RACSignal *)recordDownload:(SQRLResumableDownload *)download downloadManager:(SQRLDownloadManager *)downloadManager {
	NSParameterAssert(download != nil);
	NSParameterAssert(downloadManager != nil);

	return [[[downloadManager
		setDownload:download forRequest:self.request]
		concat:[RACSignal return:download]]
		setNameWithFormat:@"%@ %s %@", self, sel_getName(_cmd), download];
}

- (RACSignal *)prepareDownload:(SQRLDownload *)download downloadManager:(SQRLDownloadManager *)downloadManager forResponse:(NSURLResponse *)response {
	return [[RACSignal
		defer:^{
			if (![response isKindOfClass:NSHTTPURLResponse.class]) {
				return [self truncateDownload:download];
			}

			NSHTTPURLResponse *httpResponse = (id)response;

			RACSignal *downloadSignal;
			if (httpResponse.statusCode != 206 /* Partial Data */) {
				downloadSignal = [self truncateDownload:download];
			} else {
				downloadSignal = [RACSignal empty];
			}

			SQRLResumableDownload *newDownload = [[SQRLResumableDownload alloc] initWithRequest:self.request response:httpResponse fileURL:download.fileURL];

			return [[downloadSignal
				ignoreValues]
				concat:[self recordDownload:newDownload downloadManager:downloadManager]];
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

#pragma mark Start

- (RACSignal *)retrieve {
	return [[self
		connectionSignalWithRequest:self.request mapData:^(id _, RACSignal *data) {
			return [data
				aggregateWithStart:[NSMutableData data] reduce:^(NSMutableData *running, NSData *data) {
					[running appendData:data];
					return running;
				}];
		}]
		setNameWithFormat:@"%@ %s", self, sel_getName(_cmd)];
}

- (RACSignal *)download:(SQRLDownloadManager *)downloadManager {
	NSParameterAssert(downloadManager != nil);

	RACSignal *download = [[[downloadManager
		downloadForRequest:self.request]
		promiseOnScheduler:RACScheduler.immediateScheduler]
		deferred];

	RACSignal *request = [download
		flattenMap:^(SQRLDownload *download) {
			return [download resumableRequest];
		}];

	return [[request
		flattenMap:^(NSURLRequest *request) {
			return [self connectionSignalWithRequest:request mapData:^(NSURLResponse *response, RACSignal *data) {
				RACSignal *downloadURL = [[[[download
					flattenMap:^(SQRLDownload *download) {
						return [self prepareDownload:download downloadManager:downloadManager forResponse:response];
					}]
					map:^(SQRLDownload *download) {
						return download.fileURL;
					}]
					promiseOnScheduler:RACScheduler.immediateScheduler]
					deferred];

				return [[[[data
					map:^(NSData *bodyData) {
						return [[downloadURL
							try:^(NSURL *fileURL, NSError **errorRef) {
								return [self appendData:bodyData toURL:fileURL error:errorRef];
							}]
							ignoreValues];
					}]
					concat]
					ignoreValues]
					concat:downloadURL];
			}];
		}]
		setNameWithFormat:@"%@ download: %@", self, downloadManager];
}

@end
