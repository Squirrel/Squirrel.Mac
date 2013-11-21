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

// A signal which forwards any errors received from the
// `NSURLConnection`.
@property (readonly, nonatomic, strong) RACSignal *connectionErrors;

// A signal which sends the latest response received from the connection then
// completes.
@property (readonly, nonatomic, strong) RACSubject *latestResponse;

// A signal which sends the latest prepared download then completes.
@property (readonly, nonatomic, strong) RACSubject *preparedDownload;

// Aggregate subject for all errors, from the connection proper or dependent
// operations.
@property (readonly, nonatomic, strong) RACSubject *allErrors;

// A signal which completes when the `NSURLConnection` completes.
@property (readonly, nonatomic, strong) RACSignal *completionSignal;

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

	_allErrors = [RACSubject subject];

	_connectionErrors = [[[[self
		rac_signalForSelector:@selector(connection:didFailWithError:)]
		reduceEach:^(id _, NSError *error) {
			return [RACSignal error:error];
		}]
		flatten]
		setNameWithFormat:@"%@ connection errors", self];

	[_connectionErrors subscribe:_allErrors];

	_latestResponse = [[RACReplaySubject
		replaySubjectWithCapacity:1]
		setNameWithFormat:@"%@ latest response", self];

	_preparedDownload = [[RACReplaySubject
		replaySubjectWithCapacity:1]
		setNameWithFormat:@"%@ prepared download", self];

	@weakify(self);
	_completionSignal = [[[[self
		rac_signalForSelector:@selector(connectionDidFinishLoading:)]
		reduceEach:^(id _) {
			@strongify(self);

			RACSignal *locationSignal = [self.initialisedDownload
				map:^(SQRLResumableDownload *download) {
					return download.fileURL;
				}];

			return [RACSignal zip:@[ self.latestResponse, locationSignal ]];
		}]
		flatten]
		setNameWithFormat:@"%@ completion", self];

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

/*
	These methods fully evaluate their side effects before returning.
 
	This ensures strong ordering of response and data handling, and that no more
	than one `data` is held in memory at any one time.
 */

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
	[self.latestResponse sendNext:response];

	RACSignal *prepareDownload = [self
		prepareDownloadForResponse:response];
	SQRLResumableDownload *preparedDownload = [self waitForSignal:prepareDownload forwardErrors:self.allErrors];

	[self.preparedDownload sendNext:preparedDownload];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
	RACSignal *saveData = [[self.preparedDownload
		map:^(SQRLResumableDownload *download) {
			return download.fileURL;
		}]
		try:^(NSURL *fileURL, NSError **errorRef) {
			return [self appendData:data toURL:fileURL error:errorRef];
		}];
	[self waitForSignal:saveData forwardErrors:self.allErrors];
}

- (id)waitForSignal:(RACSignal *)signal forwardErrors:(RACSubject *)subject {
	NSError *error = nil;
	BOOL success = NO;
	id result = [signal firstOrDefault:nil success:&success error:&error];
	if (!success) {
		[subject sendError:error];
		return nil;
	}

	return result;
}

- (RACSignal *)connectionSignalWithRequest:(NSURLRequest *)request {
	return [[RACSignal
		createSignal:^(id<RACSubscriber> subscriber) {
			RACCompoundDisposable *disposable = [[RACCompoundDisposable alloc] init];

			RACDisposable *connectionDisposable = [RACDisposable disposableWithBlock:^{
				[self.connection cancel];
			}];
			[disposable addDisposable:connectionDisposable];

			// Sends errors
			RACDisposable *errorDisposable = [[self.allErrors
				doError:^(NSError *error) {
					[connectionDisposable dispose];
				}]
				subscribe:subscriber];
			[disposable addDisposable:errorDisposable];

			// Sends result and completion
			RACDisposable *completionDisposable = [self.completionSignal subscribe:subscriber];
			[disposable addDisposable:completionDisposable];

			[self startDownloadWithRequest:request];

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
