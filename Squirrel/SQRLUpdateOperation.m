//
//  SQRLUpdateOperation.m
//  Squirrel
//
//  Created by Keith Duncan on 25/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLUpdateOperation.h"

#import "EXTKeyPathCoding.h"

#import "SQRLUpdate.h"
#import "SQRLUpdate+Private.h"
#import "SQRLURLConnectionOperation.h"
#import "SQRLDownloadOperation.h"
#import "SQRLZipOperation.h"
#import "SQRLDirectoryManager.h"
#import "SQRLCodeSignatureVerifier.h"

NSString * const SQRLUpdateOperationErrorDomain = @"SQRLUpdateOperationErrorDomain";

@interface SQRLUpdateOperation ()
@property (atomic, assign) BOOL isExecuting;
@property (atomic, assign) BOOL isFinished;

// Request the operation was initialised with
@property (nonatomic, copy, readonly) NSURLRequest *updateRequest;
// Verifier the operation was initialised with
@property (nonatomic, strong, readonly) SQRLCodeSignatureVerifier *verifier;

// Serial queue for managing operation state
@property (nonatomic, strong, readonly) NSOperationQueue *controlQueue;
// Concurrent queue for operation work, all operations are cancellable
@property (nonatomic, strong, readonly) NSOperationQueue *workQueue;

@property (readwrite, assign, atomic) SQRLUpdaterState state;

// Result
@property (readwrite, copy, atomic) SQRLUpdate * (^completionProvider)(NSError **errorRef);
@end

@implementation SQRLUpdateOperation

- (instancetype)initWithUpdateRequest:(NSURLRequest *)updateRequest verifier:(SQRLCodeSignatureVerifier *)verifier {
	NSParameterAssert(updateRequest != nil);
	NSParameterAssert(verifier != nil);

	self = [self init];
	if (self == nil) return nil;

	NSString *queuePrefix = @"com.github.Squirrel.SQRLUpdateOperation";

	_controlQueue = [[NSOperationQueue alloc] init];
	_controlQueue.maxConcurrentOperationCount = 1;
	_controlQueue.name = [NSString stringWithFormat:@"%@.controlQueue", queuePrefix];

	 _workQueue = [[NSOperationQueue alloc] init];
	 _workQueue.name = [NSString stringWithFormat:@"%@.workQueue", queuePrefix];

	_updateRequest = [updateRequest copy];
	_verifier = verifier;

	_state = SQRLUpdaterStateCheckingForUpdate;

	_completionProvider = [^ SQRLUpdate * (NSError **errorRef) {
		if (errorRef != NULL) *errorRef = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
		return nil;
	} copy];

	return self;
}

#pragma mark Operation Overrides

- (BOOL)isConcurrent {
	return YES;
}

- (void)start {
	[self.controlQueue addOperationWithBlock:^{
		if (self.isCancelled) {
			[self finish];
			return;
		}

		[self willChangeValueForKey:@keypath(self, isExecuting)];
		self.isExecuting = YES;
		[self didChangeValueForKey:@keypath(self, isExecuting)];

		[self requestUpdate];
	}];
}

- (void)cancel {
	[self.controlQueue addOperationWithBlock:^{
		[self.workQueue cancelAllOperations];

		[super cancel];
	}];

	[super cancel];
}

- (void)finish {
	[self willChangeValueForKey:@keypath(self, isExecuting)];
	self.isExecuting = NO;
	[self didChangeValueForKey:@keypath(self, isExecuting)];

	[self willChangeValueForKey:@keypath(self, isFinished)];
	self.isFinished = YES;
	[self didChangeValueForKey:@keypath(self, isFinished)];
}

- (void)completeWithError:(NSError *)error {
	self.completionProvider = ^ SQRLUpdate * (NSError **errorRef) {
		if (errorRef != NULL) *errorRef = error;
		return nil;
	};
	[self finish];
}

- (void)completeWithUpdate:(SQRLUpdate *)update {
	self.completionProvider = ^ (NSError **errorRef) {
		return update;
	};
	[self finish];
}

#pragma Update

- (void)requestUpdate {
	NSMutableURLRequest *request = [self.updateRequest mutableCopy];
	[request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

	SQRLURLConnectionOperation *connectionOperation = [[SQRLURLConnectionOperation alloc] initWithRequest:request];
	[self.workQueue addOperation:connectionOperation];

	NSOperation *finishOperation = [NSBlockOperation blockOperationWithBlock:^{
		if (self.isCancelled) {
			[self finish];
		}

		[self parseUpdateWithResponseProvider:connectionOperation.responseProvider];
	}];
	[finishOperation addDependency:connectionOperation];
	[self.controlQueue addOperation:finishOperation];
}

- (void)parseUpdateWithResponseProvider:(SQRLResponseProvider)responseProvider {
	NSData * (^provider)(NSError **) = ^ (NSError **errorRef) {
		return responseProvider(NULL, errorRef);
	};

	NSError *updateError = nil;
	SQRLUpdate *update = [SQRLUpdate updateWithResponseProvider:provider error:&updateError];
	if (update == nil) {
		[self completeWithError:updateError];
		return;
	}

	[self downloadUpdate:update];
}

- (void)downloadUpdate:(SQRLUpdate *)update {
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:update.updateURL];
	[request setValue:@"application/zip" forHTTPHeaderField:@"Accept"];

	SQRLDownloadOperation *downloadOperation = [[SQRLDownloadOperation alloc] initWithRequest:request];
	[self.workQueue addOperation:downloadOperation];
	self.state = SQRLUpdaterStateDownloadingUpdate;

	NSOperation *finishOperation = [NSBlockOperation blockOperationWithBlock:^{
		if (self.isCancelled) {
			[self finish];
		}

		NSError *downloadURLError = nil;
		NSURL *downloadURL = downloadOperation.completionProvider(NULL, &downloadURLError);
		if (downloadURL == nil) {
			[self completeWithError:downloadURLError];
			return;
		}

		[self unpackUpdate:update archiveURL:downloadURL];
	}];
	[finishOperation addDependency:downloadOperation];
	[self.controlQueue addOperation:finishOperation];
}

- (void)unpackUpdate:(SQRLUpdate *)update archiveURL:(NSURL *)archiveURL {
	NSURL *unpackDirectory = SQRLDirectoryManager.directoryManagerForCurrentApplication.URLForUnpackDirectory;

	NSURL *currentUnpackDirectory = [unpackDirectory URLByAppendingPathComponent:NSProcessInfo.processInfo.globallyUniqueString];

	NSError *createDirectoryError = nil;
	BOOL createDirectory = [NSFileManager.defaultManager createDirectoryAtURL:currentUnpackDirectory withIntermediateDirectories:YES attributes:nil error:&createDirectoryError];
	if (!createDirectory) {
		[self completeWithError:createDirectoryError];
		return;
	}

	[self unpackUpdate:update archiveURL:archiveURL toDirectory:currentUnpackDirectory];
}

- (void)unpackUpdate:(SQRLUpdate *)update archiveURL:(NSURL *)archiveURL toDirectory:(NSURL *)directoryURL {
	SQRLZipOperation *zipOperation = [SQRLZipOperation unzipArchiveAtURL:archiveURL intoDirectoryAtURL:directoryURL];
	[self.workQueue addOperation:zipOperation];
	self.state = SQRLUpdaterStateUnzippingUpdate;

	NSOperation *finishOperation = [NSBlockOperation blockOperationWithBlock:^{
		if (self.isCancelled) {
			[self finish];
			return;
		}

		NSError *error = nil;

		BOOL unzip = zipOperation.completionProvider(&error);
		if (!unzip) {
			[self completeWithError:error];
			return;
		}

		NSRunningApplication *currentApplication = NSRunningApplication.currentApplication;
		NSURL *applicationBundleURL = [self verifiedApplicationBundleURLWithIdentifier:currentApplication.bundleIdentifier inDirectory:directoryURL error:&error];
		if (applicationBundleURL == nil) {
			[self completeWithError:error];
			return;
		}

		update.downloadedUpdateURL = applicationBundleURL;
		[self completeWithUpdate:update];
	}];
	[finishOperation addDependency:zipOperation];
	[self.controlQueue addOperation:finishOperation];
}

+ (NSURL *)applicationBundleURLWithIdentifier:(NSString *)bundleIdentifier inDirectory:(NSURL *)directory {
	NSParameterAssert(bundleIdentifier != nil);

	if (directory == nil) return nil;

	NSFileManager *manager = [[NSFileManager alloc] init];
	NSDirectoryEnumerator *enumerator = [manager enumeratorAtURL:directory includingPropertiesForKeys:@[ NSURLTypeIdentifierKey ] options:NSDirectoryEnumerationSkipsPackageDescendants | NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^(NSURL *URL, NSError *error) {
		NSLog(@"Error enumerating item %@ within directory %@: %@", URL, directory, error);
		return YES;
	}];

	for (NSURL *URL in enumerator) {
		NSString *type = nil;
		NSError *error = nil;
		if (![URL getResourceValue:&type forKey:NSURLTypeIdentifierKey error:&error]) {
			NSLog(@"Error retrieving UTI for item at %@: %@", URL, error);
			continue;
		}

		if (!UTTypeConformsTo((__bridge CFStringRef)type, kUTTypeApplicationBundle)) continue;

		NSDictionary *infoPlist = CFBridgingRelease(CFBundleCopyInfoDictionaryForURL((__bridge CFURLRef)URL));

		if ([infoPlist[(__bridge NSString *)kCFBundleIdentifierKey] isEqual:bundleIdentifier]) {
			return URL;
		}
	}

	return nil;
}

- (NSURL *)verifiedApplicationBundleURLWithIdentifier:(NSString *)bundleIdentifier inDirectory:(NSURL *)directory error:(NSError **)errorRef {
	NSURL *applicationBundleURL = [self.class applicationBundleURLWithIdentifier:bundleIdentifier inDirectory:directory];
	if (applicationBundleURL == nil) {
		if (errorRef != NULL) {
			NSDictionary *errorInfo = @{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Could not locate update bundle for %@ within %@", nil), bundleIdentifier, directory.path],
			};
			*errorRef = [NSError errorWithDomain:SQRLUpdateOperationErrorDomain code:SQRLUpdateOperationErrorMissingUpdateBundle userInfo:errorInfo];
		}
		return nil;
	}

	if (![self.verifier verifyCodeSignatureOfBundle:applicationBundleURL error:errorRef]) return nil;

	return applicationBundleURL;
}

@end
