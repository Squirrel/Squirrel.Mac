//
//  SQRLDownloader.m
//  Squirrel
//
//  Copyright (c) 2026 GitHub. All rights reserved.
//

#import "SQRLDownloader.h"
#import <ReactiveObjC/ReactiveObjC.h>

// Keys of the property list written to `resumeDataURL`. The session's resume
// data is opaque, so the URL it belongs to is kept beside it.
static NSString * const SQRLDownloaderResumeURLKey = @"URL";
static NSString * const SQRLDownloaderResumeDataKey = @"resumeData";

@implementation SQRLDownloadProgress

- (instancetype)initWithBytesResumed:(int64_t)bytesResumed bytesReceived:(int64_t)bytesReceived bytesExpected:(int64_t)bytesExpected {
	self = [super init];
	if (self == nil) return nil;

	_bytesResumed = bytesResumed;
	_bytesReceived = bytesReceived;
	_bytesExpected = bytesExpected;
	return self;
}

- (id)copyWithZone:(NSZone *)zone {
	return self;
}

- (NSString *)description {
	return [NSString stringWithFormat:@"<%@: %p>{ resumed = %lld, received = %lld, expected = %lld }", self.class, self, self.bytesResumed, self.bytesReceived, self.bytesExpected];
}

@end

@interface SQRLDownloader () <NSURLSessionDownloadDelegate>

@property (nonatomic, copy, readonly) NSURLRequest *request;
@property (nonatomic, copy, readonly) NSURL *resumeDataURL;

// Serial queue every delegate callback arrives on; all mutable state below is
// touched only there once the task has started.
@property (nonatomic, strong, readonly) NSOperationQueue *delegateQueue;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDownloadTask *task;

@property (nonatomic, strong) id<RACSubscriber> subscriber;
@property (nonatomic, copy) NSURL *destinationURL;
@property (nonatomic, strong) NSError *moveError;
// The resume data this downloader took off disk, in case it must go back.
@property (nonatomic, copy) NSData *takenResumeData;

@property (nonatomic, assign) int64_t bytesResumed;
@property (nonatomic, assign) BOOL startedFromResumeData;
@property (nonatomic, assign) BOOL receivedBytes;
@property (nonatomic, assign) BOOL cancelled;

// Entered when a task starts, left when its completion (including any resume
// data write) has been handled. +cancelAllWritingResumeDataWithTimeout: waits
// on it.
@property (nonatomic, strong, readonly) dispatch_group_t completionGroup;

@end

@implementation SQRLDownloader {
	RACSubject *_progress;
}

#pragma mark Configuration

static NSURLSessionConfiguration *SQRLDownloaderSessionConfiguration = nil;

+ (NSURLSessionConfiguration *)sessionConfiguration {
	@synchronized (self) {
		return [SQRLDownloaderSessionConfiguration copy] ?: NSURLSessionConfiguration.defaultSessionConfiguration;
	}
}

+ (void)setSessionConfiguration:(NSURLSessionConfiguration *)sessionConfiguration {
	@synchronized (self) {
		SQRLDownloaderSessionConfiguration = [sessionConfiguration copy];
	}
}

#pragma mark Registry

+ (NSHashTable *)liveDownloaders {
	static NSHashTable *live;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		live = [NSHashTable weakObjectsHashTable];
	});
	return live;
}

+ (void)cancelAllWritingResumeDataWithTimeout:(NSTimeInterval)timeout {
	NSArray *downloaders;
	NSHashTable *live = self.liveDownloaders;
	@synchronized (live) {
		downloaders = live.allObjects;
	}

	dispatch_group_t all = dispatch_group_create();
	for (SQRLDownloader *downloader in downloaders) {
		dispatch_group_enter(all);
		dispatch_group_notify(downloader.completionGroup, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
			dispatch_group_leave(all);
		});
		[downloader cancel];
	}

	dispatch_group_wait(all, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
}

#pragma mark Lifecycle

- (instancetype)initWithRequest:(NSURLRequest *)request resumeDataURL:(NSURL *)resumeDataURL {
	NSParameterAssert(request != nil);
	NSParameterAssert(resumeDataURL == nil || resumeDataURL.isFileURL);

	self = [super init];
	if (self == nil) return nil;

	_request = [request copy];
	_resumeDataURL = [resumeDataURL copy];
	_progress = [[RACSubject subject] setNameWithFormat:@"%@ progress", self];
	_completionGroup = dispatch_group_create();

	_delegateQueue = [[NSOperationQueue alloc] init];
	_delegateQueue.maxConcurrentOperationCount = 1;
	_delegateQueue.name = @"com.github.Squirrel.SQRLDownloader";

	return self;
}

- (RACSignal *)progress {
	return _progress;
}

#pragma mark Resume Data

- (NSData *)takeStoredResumeData {
	if (self.resumeDataURL == nil) return nil;

	NSDictionary *stored = [NSDictionary dictionaryWithContentsOfURL:self.resumeDataURL];
	NSData *resumeData = stored[SQRLDownloaderResumeDataKey];

	// Taken, not read: while this attempt owns the partial file nothing on disk
	// may point another downloader (or a relaunch after a crash) at it. It is
	// written again if this attempt stops short.
	[self clearStoredResumeData];
	if (![stored[SQRLDownloaderResumeURLKey] isEqual:self.request.URL.absoluteString] || ![resumeData isKindOfClass:NSData.class]) return nil;

	return resumeData;
}

- (void)storeResumeData:(NSData *)resumeData {
	if (self.resumeDataURL == nil) return;
	if (resumeData == nil) {
		[self clearStoredResumeData];
		return;
	}

	NSDictionary *stored = @{
		SQRLDownloaderResumeURLKey: self.request.URL.absoluteString,
		SQRLDownloaderResumeDataKey: resumeData,
	};

	NSError *error;
	NSData *plist = [NSPropertyListSerialization dataWithPropertyList:stored format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
	if (plist == nil || ![plist writeToURL:self.resumeDataURL options:NSDataWritingAtomic error:&error]) {
		NSLog(@"Could not keep resume data for %@ at %@: %@", self.request.URL, self.resumeDataURL, error);
	}
}

- (void)clearStoredResumeData {
	if (self.resumeDataURL == nil) return;
	[NSFileManager.defaultManager removeItemAtURL:self.resumeDataURL error:NULL];
}

#pragma mark Downloading

- (RACSignal *)downloadToURL:(NSURL *)destinationURL {
	NSParameterAssert(destinationURL != nil);

	return [[RACSignal
		createSignal:^(id<RACSubscriber> subscriber) {
			NSAssert(self.session == nil, @"%@ is one-shot; -downloadToURL: was subscribed to twice", self);

			self.subscriber = subscriber;
			self.destinationURL = destinationURL;
			self.session = [NSURLSession sessionWithConfiguration:self.class.sessionConfiguration delegate:self delegateQueue:self.delegateQueue];

			NSHashTable *live = self.class.liveDownloaders;
			@synchronized (live) {
				[live addObject:self];
			}

			[self.delegateQueue addOperationWithBlock:^{
				[self startTaskWithResumeData:[self takeStoredResumeData]];
			}];

			return [RACDisposable disposableWithBlock:^{
				[self cancel];
			}];
		}]
		setNameWithFormat:@"%@ -downloadToURL: %@", self, destinationURL];
}

- (void)startTaskWithResumeData:(NSData *)resumeData {
	dispatch_group_enter(self.completionGroup);

	NSURLSessionDownloadTask *resumed = resumeData != nil ? [self.session downloadTaskWithResumeData:resumeData] : nil;
	if (resumed != nil) self.takenResumeData = resumeData;
	self.startedFromResumeData = (resumed != nil);
	self.receivedBytes = NO;
	self.bytesResumed = 0;
	self.moveError = nil;
	self.task = resumed ?: [self.session downloadTaskWithRequest:self.request];
	[self.task resume];
}

- (void)cancel {
	[self.delegateQueue addOperationWithBlock:^{
		if (self.task == nil || self.cancelled) return;

		self.cancelled = YES;
		// The resume data also arrives in -URLSession:task:didCompleteWithError:,
		// which is where it is written.
		[self.task cancelByProducingResumeData:^(NSData *resumeData) {}];
	}];
}

- (void)sendProgressWithBytesReceived:(int64_t)bytesReceived bytesExpected:(int64_t)bytesExpected {
	[_progress sendNext:[[SQRLDownloadProgress alloc] initWithBytesResumed:self.bytesResumed bytesReceived:bytesReceived bytesExpected:bytesExpected]];
}

#pragma mark NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didResumeAtOffset:(int64_t)fileOffset expectedTotalBytes:(int64_t)expectedTotalBytes {
	self.bytesResumed = fileOffset;
	[self sendProgressWithBytesReceived:fileOffset bytesExpected:expectedTotalBytes];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
	self.receivedBytes = YES;
	[self sendProgressWithBytesReceived:totalBytesWritten bytesExpected:totalBytesExpectedToWrite];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
	NSFileManager *fileManager = [[NSFileManager alloc] init];
	[fileManager removeItemAtURL:self.destinationURL error:NULL];

	NSError *error;
	if (![fileManager moveItemAtURL:location toURL:self.destinationURL error:&error]) {
		self.moveError = error;
	}
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
	if (task != self.task) return;

	// A resumed attempt that got no further than where it started says nothing
	// about the payload: the session refused the data, the ranged request was
	// reset or could not be decoded, or it was answered rather than served
	// (403/416 from an expired signed URL, 304). Forget the resume data and
	// ask from the start, once; never hand such an answer up as the download.
	NSInteger statusCode = [task.response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)task.response statusCode] : 200;
	BOOL resumeWentNowhere = self.startedFromResumeData && !self.cancelled && (error != nil ? !self.receivedBytes : statusCode < 200 || statusCode > 299);
	if (resumeWentNowhere) {
		dispatch_group_leave(self.completionGroup);
		[self startTaskWithResumeData:nil];
		return;
	}

	if (error != nil) {
		// A fresh attempt that received nothing either means the network is
		// the problem, not the ranged request: put back what was taken so
		// the partial file outlives the outage.
		NSData *resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData];
		[self storeResumeData:(!self.receivedBytes && self.takenResumeData != nil) ? self.takenResumeData : resumeData];
		[self finishWithError:error];
		return;
	}

	if (self.moveError != nil) {
		[self clearStoredResumeData];
		[self finishWithError:self.moveError];
		return;
	}

	[self clearStoredResumeData];
	[self.subscriber sendNext:RACTuplePack(task.response, self.destinationURL)];
	[self finishWithError:nil];
}

- (void)finishWithError:(NSError *)error {
	id<RACSubscriber> subscriber = self.subscriber;
	self.subscriber = nil;

	[self.session finishTasksAndInvalidate];
	NSHashTable *live = self.class.liveDownloaders;
	@synchronized (live) {
		[live removeObject:self];
	}

	[_progress sendCompleted];
	if (error != nil) {
		[subscriber sendError:error];
	} else {
		[subscriber sendCompleted];
	}

	dispatch_group_leave(self.completionGroup);
}

@end
