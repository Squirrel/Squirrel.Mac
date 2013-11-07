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
- (RACSignal *)resumableDownload;

// Returns a signal which sends the request that should be performed for the
// `resumableDownload` - either the original request or a new request with the
// state added to resume a prior download - then completes, or errors.
- (RACSignal *)requestForResumableDownload;
@end

@implementation SQRLDownloader

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

- (RACSignal *)resumableDownload {
	return [[self.downloadManager
		downloadForRequest:self.request]
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

- (void)startDownloadWithRequest:(NSURLRequest *)request {
	NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
	delegateQueue.maxConcurrentOperationCount = 1;

	self.connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
	self.connection.delegateQueue = delegateQueue;
	[self.connection start];
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

- (RACSignal *)download {
	RACSignal *errors = [[[self
		rac_signalForSelector:@selector(connection:didFailWithError:) fromProtocol:@protocol(NSURLConnectionDataDelegate)]
		reduceEach:^(id _, NSError *error) {
			return [RACSignal error:error];
		}]
		flatten];

	RACSignal *finished = [self rac_signalForSelector:@selector(connectionDidFinishLoading:) fromProtocol:@protocol(NSURLConnectionDataDelegate)];

	RACSignal *data = [[[[[RACSignal
		merge:@[
			[self rac_signalForSelector:@selector(connection:didReceiveResponse:) fromProtocol:@protocol(NSURLConnectionDataDelegate)],
			[self rac_signalForSelector:@selector(connection:didReceiveData:) fromProtocol:@protocol(NSURLConnectionDataDelegate)],
		]]
	 	reduceEach:^(id _, id value) {
			return value;
		}]
		takeUntil:finished]
		flattenMap:^(id value) {
			return [[self
				resumableDownload]
				flattenMap:^(SQRLResumableDownload *download) {
					if ([value isKindOfClass:NSURLResponse.class]) {
						NSURLResponse *response = value;

						// Can only resume HTTP responses which indicate whether we can resume
						if (![response isKindOfClass:NSHTTPURLResponse.class]) {
							return [self truncateDownload:download];
						}

						NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;

						/*
						 First truncate the file if necessary, then record the new ETag.

						 This ensures old data doesn't get associated with a new ETag if
						 we were to crash between setting the ETag and clearing the file.
						 */

						SQRLResumableDownload *newDownload = [[SQRLResumableDownload alloc] initWithResponse:httpResponse fileURL:download.fileURL];

						if (httpResponse.statusCode == /* OK */ 200) {
							return [[[[self
								truncateDownload:download]
								concat:[self recordDownload:newDownload]]
								ignoreValues]
								concat:[RACSignal return:response]];
						} else if (httpResponse.statusCode == /* Partial Content */ 206) {
							// This is the response we need to know we can append to our already
							// downloaded bytes, great success!
						}

						return [[[self
							recordDownload:newDownload]
							ignoreValues]
							concat:[RACSignal return:response]];
					} else if ([value isKindOfClass:NSData.class]) {
						NSData *bodyData = value;

						NSError *error = nil;
						BOOL append = [self appendData:bodyData toURL:download.fileURL error:&error];
						id response = nil;
						return (append ? [RACSignal return:response] : [RACSignal error:error]);
					}

					@throw [NSException exceptionWithName:NSInvalidArgumentException reason:[NSString stringWithFormat:@"%@ cannot be mapped", value] userInfo:nil];
				}];
		}]
		replayLast];

	return [[[self
		requestForResumableDownload]
		flattenMap:^(NSURLRequest *request) {
			return [[RACSignal
				createSignal:^(id<RACSubscriber> subscriber) {
					RACCompoundDisposable *disposable = [[RACCompoundDisposable alloc] init];

					[self startDownloadWithRequest:request];

					RACDisposable *connectionDisposable = [RACDisposable disposableWithBlock:^{
						[self.connection cancel];
					}];
					[disposable addDisposable:connectionDisposable];

					RACDisposable *errorDisposable = [[RACSignal
						merge:@[ errors, data ]]
						subscribeError:^(NSError *error) {
							[connectionDisposable dispose];
							[subscriber sendError:error];
						}];
					[disposable addDisposable:errorDisposable];

					RACDisposable *completedDisposable = [data
						subscribeCompleted:^{
							RACSignal *downloadLocation = [[self
								resumableDownload]
								map:^(SQRLResumableDownload *download) {
									return download.fileURL;
								}];

							RACSignal *result = [data
								zipWith:downloadLocation];

							[subscriber sendNext:result];
							[subscriber sendCompleted];
						}];
					[disposable addDisposable:completedDisposable];

					return disposable;
				}]
				flatten];
		}]
		setNameWithFormat:@"%@ %s", self, sel_getName(_cmd)];
}

@end
