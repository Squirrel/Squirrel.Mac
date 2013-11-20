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

#import "SQRLResumableDownloadManager.h"
#import "SQRLResumableDownload.h"

@interface SQRLDownloader ()
// Request the operation was initialised with.
@property (nonatomic, copy, readonly) NSURLRequest *request;

// Download manager for resumable state.
@property (nonatomic, strong, readonly) SQRLResumableDownloadManager *downloadManager;

// Connection to retreive the remote resource.
@property (nonatomic, strong) NSURLConnection *connection;

// Returns a signal which sends the resumable download for `request` from
// `downloadManager` then completes, or errors.
@property (nonatomic, readonly, strong) RACSignal *resumableDownload;

// Returns a signal which sends the request that should be performed for the
// `resumableDownload` - either the original request or a new request with the
// state added to resume a prior download - then completes, or errors.
- (RACSignal *)requestForResumableDownload;

// Listens for invocations of `selector` on the receiver that are triggered by
// the given connection.
//
// The first argument of `selector` must be an `NSURLConnection` object.
//
// Returns a signal which sends the _second_ argument of `selector`, or
// RACUnit if there is only one argument, then completes when the receiver
// deallocates.
- (RACSignal *)signalForDelegateSelector:(SEL)selector ofConnection:(NSURLConnection *)connection;

@end

@implementation SQRLDownloader

- (instancetype)initWithRequest:(NSURLRequest *)request downloadManager:(SQRLResumableDownloadManager *)downloadManager {
	NSParameterAssert(request != nil);
	NSParameterAssert(downloadManager != nil);

	self = [self init];
	if (self == nil) return nil;

	_request = [request copy];
	_downloadManager = downloadManager;
	_resumableDownload = [downloadManager downloadForRequest:request];

	return self;
}

#pragma mark Download

- (RACSignal *)signalForDelegateSelector:(SEL)selector ofConnection:(NSURLConnection *)connection {
	NSParameterAssert(selector != NULL);
	NSParameterAssert(connection != nil);

	return [[[self
		rac_signalForSelector:selector]
		filter:^ BOOL (RACTuple *args) {
			return args.first == connection;
		}]
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
		resumableDownload]
		map:^ NSURLRequest * (SQRLResumableDownload *resumableDownload) {
			NSURLRequest *originalRequest = self.request;

			NSHTTPURLResponse *response = resumableDownload.response;
			NSString *ETag = [self.class ETagFromResponse:response];
			if (ETag == nil) return originalRequest;

			NSURL *downloadLocation = resumableDownload.fileURL;

			NSNumber *alreadyDownloadedSize = nil;
			NSError *alreadyDownloadedSizeError = nil;
			BOOL getAlreadyDownloadedSize = [downloadLocation getResourceValue:&alreadyDownloadedSize forKey:NSURLFileSizeKey error:&alreadyDownloadedSizeError];
			if (!getAlreadyDownloadedSize) return originalRequest;

			NSMutableURLRequest *newRequest = [originalRequest mutableCopy];
			[newRequest setValue:ETag forHTTPHeaderField:@"If-Range"];
			[newRequest setValue:[NSString stringWithFormat:@"%llu-", alreadyDownloadedSize.unsignedLongLongValue] forHTTPHeaderField:@"Range"];
			return newRequest;
		}]
		setNameWithFormat:@"%@ %s", self, sel_getName(_cmd)];
}

+ (NSString *)ETagFromResponse:(NSHTTPURLResponse *)response {
	return [[[response.allHeaderFields.rac_sequence
		filter:^ BOOL (RACTuple *keyValuePair) {
			return [keyValuePair.first caseInsensitiveCompare:@"ETag"] == NSOrderedSame;
		}]
		reduceEach:^(NSString *key, NSString *value) {
			return value;
		}]
		head];
}

- (RACSignal *)truncateDownload:(SQRLResumableDownload *)download {
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

- (RACSignal *)prepareResumableDownloadForResponse:(NSURLResponse *)response {
	return [[[self
		resumableDownload]
		flattenMap:^(SQRLResumableDownload *download) {
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

			SQRLResumableDownload *newDownload = [[SQRLResumableDownload alloc] initWithResponse:httpResponse fileURL:download.fileURL];

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

- (RACSignal *)connectionSignalWithRequest:(NSURLRequest *)request {
	return [[RACSignal
		createSignal:^(id<RACSubscriber> subscriber) {
			NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
			delegateQueue.maxConcurrentOperationCount = 1;

			NSURLConnection *connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
			connection.delegateQueue = delegateQueue;

			// Because signal subscription is asynchronous when not performed on
			// a known RACScheduler (because lulz RAC implementation details),
			// this scheduler is used to order some of the subscription logic
			// below.
			//
			// As an aside, it lowers the priority of our download operation, to
			// avoid competing with work explicitly initiated by the user.
			RACScheduler *callbackScheduler = [RACScheduler schedulerWithPriority:RACSchedulerPriorityBackground];

			// A signal that will error if the connection fails for any reason.
			//
			// This does not use `callbackScheduler` because errors should
			// propagate as quickly as possible, and do not result in other
			// signal subscriptions (at least in this code).
			RACSignal *errors = [[self
				signalForDelegateSelector:@selector(connection:didFailWithError:) ofConnection:connection]
				flattenMap:^(NSError *error) {
					return [RACSignal error:error];
				}];

			// A signal of all `NSURLResponse`s received on the connection.
			//
			// This signal's events are delivered to `callbackScheduler` so that
			// any bound signals are subscribed to synchronously.
			RACSignal *responses = [[self
				signalForDelegateSelector:@selector(connection:didReceiveResponse:) ofConnection:connection]
				deliverOn:callbackScheduler];

			// A signal of all `NSData` received on the connection.
			//
			// This signal's events are delivered to `callbackScheduler` so that
			// ordering is preserved relative to `responses`.
			//
			// The signal is multicasted so that any subscription created _as
			// a result of_ an event on `responses` won't miss the first
			// `NSData` to follow.
			RACMulticastConnection *data = [[[self
				signalForDelegateSelector:@selector(connection:didReceiveData:) ofConnection:connection]
				deliverOn:callbackScheduler]
				publish];

			RACDisposable *dataDisposable = [data connect];

			// Sends (or replays) RACUnit when the connection has finished
			// loading successfully.
			RACSignal *finished = [[[self
				signalForDelegateSelector:@selector(connectionDidFinishLoading:) ofConnection:connection]
				take:1]
				replay];

			RACDisposable *responsesDisposable = [[[[[RACSignal
				merge:@[ responses, errors ]]
				takeUntil:finished]
				map:^(NSURLResponse *response) {
					RACSignal *downloadURL = [[[self
						prepareResumableDownloadForResponse:response]
						map:^(SQRLResumableDownload *download) {
							return download.fileURL;
						}]
						replayLazily];

					return [[[[data.signal
						takeUntil:finished]
						map:^(NSData *bodyData) {
							return [downloadURL try:^(NSURL *fileURL, NSError **errorRef) {
								return [self appendData:bodyData toURL:fileURL error:errorRef];
							}];
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

			[connection start];
			return [RACDisposable disposableWithBlock:^{
				[connection cancel];

				[dataDisposable dispose];
				[responsesDisposable dispose];
			}];
		}]
		setNameWithFormat:@"%@ %s %@", self, sel_getName(_cmd), request];
}

#pragma mark NSURLConnectionDelegate

// Stub delegate methods, to ensure that we don't ever invoke an unimplemented
// selector.
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
}

@end
