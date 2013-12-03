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
// The request the downloader was initialised with.
@property (nonatomic, copy, readonly) NSURLRequest *request;

// The download manager the downloader was initialised with.
@property (nonatomic, strong, readonly) SQRLDownloadManager *downloadManager;

// Connection to retreive the remote resource.
@property (nonatomic, strong) NSURLConnection *connection;

// Returns a signal which sends the download for `request` from
// `downloadManager` then completes, or errors.
@property (nonatomic, readonly, strong) RACSignal *initialisedDownload;

// Listens for invocations of `selector` on the receiver.
//
// The first argument of `selector` must be an `NSURLConnection` object.
//
// Returns a signal which sends the _second_ argument of `selector`, or
// RACUnit if there is only one argument, then completes when the receiver
// deallocates.
- (RACSignal *)signalForDelegateSelector:(SEL)selector;

@end

@implementation SQRLDownloader

- (instancetype)initWithRequest:(NSURLRequest *)request downloadManager:(SQRLDownloadManager *)downloadManager {
	NSParameterAssert(request != nil);
	NSParameterAssert(downloadManager != nil);

	self = [self init];
	if (self == nil) return nil;

	_request = [request copy];
	_downloadManager = downloadManager;

	_initialisedDownload = [[[downloadManager
		downloadForRequest:request]
		promiseOnScheduler:RACScheduler.immediateScheduler]
		deferred];

	return self;
}

#pragma mark Download

- (RACSignal *)signalForDelegateSelector:(SEL)selector {
	NSParameterAssert(selector != NULL);

	return [[self
		rac_signalForSelector:selector]
		map:^(RACTuple *args) {
			return args.second ?: RACUnit.defaultUnit;
		}];
}

- (RACSignal *)download {
	return [[[self
		requestForResumableDownload]
		flattenMap:^(NSURLRequest *request) {
			return [self connectionSignalWithRequest:request];
		}]
		setNameWithFormat:@"%@ %s", self, sel_getName(_cmd)];
}

- (RACSignal *)requestForResumableDownload {
	return [[[self
		initialisedDownload]
		flattenMap:^(SQRLDownload *download) {
			return [download resumableRequest];
		}]
		setNameWithFormat:@"%@ %s", self, sel_getName(_cmd)];
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
		then:^{
			return [RACSignal return:download];
		}]
		setNameWithFormat:@"%@ %s %@", self, sel_getName(_cmd), download];
}

- (RACSignal *)recordDownload:(SQRLResumableDownload *)download {
	return [[[self.downloadManager
		setDownload:download forRequest:self.request]
		then:^{
			return [RACSignal return:download];
		}]
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
				then:^{
					return [self recordDownload:newDownload];
				}];
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

- (RACSignal *)connectionSignalWithRequest:(NSURLRequest *)request {
	return [[RACSignal
		create:^(id<RACSubscriber> subscriber) {
			NSURLConnection *connection = nil;

			// A signal that will error if the connection fails for any reason.
			RACSignal *errors = [[self
				signalForDelegateSelector:@selector(connection:didFailWithError:)]
				flattenMap:^(NSError *error) {
					return [RACSignal error:error];
				}];

			// A signal of all `NSURLResponse`s received on the connection.
			RACSignal *responses = [self
				signalForDelegateSelector:@selector(connection:didReceiveResponse:)];

			// A signal of all `NSData` received on the connection.
			RACSignal *data = [self
				signalForDelegateSelector:@selector(connection:didReceiveData:)];

			// Sends (or replays) RACUnit when the connection has finished
			// loading successfully.
			RACSignal *finished = [[[[self
				signalForDelegateSelector:@selector(connectionDidFinishLoading:)]
				take:1]
				promiseOnScheduler:RACScheduler.immediateScheduler]
				start];

			RACDisposable *responsesDisposable = [[[[[RACSignal
				merge:@[ responses, errors ]]
				takeUntil:finished]
				map:^(NSURLResponse *response) {
					RACSignal *downloadURL = [[[[self
						prepareDownloadForResponse:response]
						map:^(SQRLDownload *download) {
							return download.fileURL;
						}]
						promiseOnScheduler:RACScheduler.immediateScheduler]
						deferred];

					return [[[[data
						takeUntil:finished]
						map:^(NSData *bodyData) {
							return [[downloadURL
								try:^(NSURL *fileURL, NSError **errorRef) {
									return [self appendData:bodyData toURL:fileURL error:errorRef];
								}]
								ignoreValues];
						}]
						concat]
						then:^{
							return [RACSignal zip:@[
								[RACSignal return:response],
								downloadURL
							]];
						}];
				}]
				switchToLatest]
				subscribe:subscriber];

			NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
			delegateQueue.maxConcurrentOperationCount = 1;

			connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
			connection.delegateQueue = delegateQueue;

			[connection start];

			[subscriber.disposable addDisposable:[RACDisposable disposableWithBlock:^{
				[connection cancel];

				[responsesDisposable dispose];
			}]];
		}]
		setNameWithFormat:@"%@ %s %@", self, sel_getName(_cmd), request];
}

@end
