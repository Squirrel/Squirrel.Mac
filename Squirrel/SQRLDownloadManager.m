//
//  SQRLDownloadController.m
//  Squirrel
//
//  Created by Keith Duncan on 26/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDownloadManager.h"

#import <ReactiveCocoa/ReactiveCocoa.h>

#import "SQRLDirectoryManager.h"
#import "SQRLDownload.h"
#import "SQRLDownload+Private.h"
#import "SQRLResumableDownload.h"

#import "NSData+SQRLExtensions.h"

@interface SQRLDownloadManager ()
@property (nonatomic, strong, readonly) SQRLDirectoryManager *directoryManager;
@property (nonatomic, assign, readonly) dispatch_queue_t queue;

// Reads the download index.
//
// Returns a signal which sends the download index at time of read then
// completes, or errors.
- (RACSignal *)readDownloadIndex;

// Write a new download index.
//
// block - Map from the old download index to the new download index. Writing
//         is serialised, subsequent writers will receive the output of the
//         previous map block. If the output of the map is equal to the input
//         no write is attempted and the returned signal completes.
//
// Returns a signal which completes or errors.
- (RACSignal *)writeDownloadIndexWithBlock:(NSDictionary * (^)(NSMutableDictionary *))block;
@end

@implementation SQRLDownloadManager

+ (instancetype)defaultDownloadManager {
	static SQRLDownloadManager *defaultDownloadManager;
	static dispatch_once_t defaultDownloadManagerPredicate;

	dispatch_once(&defaultDownloadManagerPredicate, ^{
		defaultDownloadManager = [[self alloc] initWithDirectoryManager:SQRLDirectoryManager.currentApplicationManager];
	});

	return defaultDownloadManager;
}

- (id)initWithDirectoryManager:(SQRLDirectoryManager *)directoryManager {
	NSParameterAssert(directoryManager != nil);

	self = [super init];
	if (self == nil) return nil;

	_directoryManager = directoryManager;

	_queue = dispatch_queue_create("com.github.Squirrel.SQRLDownloadManager.queue", DISPATCH_QUEUE_CONCURRENT);
	dispatch_set_target_queue(_queue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));

	return self;
}

- (void)dealloc {
	if (_queue != NULL) dispatch_release(_queue);
}

- (RACSignal *)removeAllResumableDownloads {
	return [[[RACSignal
		merge:@[
			[self downloadStoreIndexFileLocation],
			[self.directoryManager downloadDirectoryURL]
		]]
		flattenMap:^ (NSURL *location) {
			return [[RACSignal
				defer:^{
					NSError *error;
					BOOL remove = [NSFileManager.defaultManager removeItemAtURL:location error:&error];
					return (remove ? [RACSignal empty] : [RACSignal error:error]);
				}]
				catch:^(NSError *error) {
					if ([error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileNoSuchFileError) return [RACSignal empty];
					return [RACSignal error:error];
				}];
		}]
		setNameWithFormat:@"%@ %s", self, sel_getName(_cmd)];
}

- (RACSignal *)downloadStoreIndexFileLocation {
	return [[[self.directoryManager
		applicationSupportURL]
		map:^(NSURL *directory) {
			return [directory URLByAppendingPathComponent:@"DownloadIndex.plist"];
		}]
		setNameWithFormat:@"%@ %s", self, sel_getName(_cmd)];
}

- (RACSignal *)readDownloadIndex {
	return [[[self
		downloadStoreIndexFileLocation]
		flattenMap:^(NSURL *location) {
			return [RACSignal
				create:^(id<RACSubscriber> subscriber) {
					dispatch_async(self.queue, ^{
						if (subscriber.disposable.disposed) return;

						NSError *error;
						NSDictionary *propertyList = [self readPropertyListWithContentsOfURL:location error:&error];
						if (propertyList == nil) {
							[subscriber sendError:error];
							return;
						}

						[subscriber sendNext:propertyList];
						[subscriber sendCompleted];
					});
				}];
		}]
		setNameWithFormat:@"%@ %s", self, sel_getName(_cmd)];
}

- (RACSignal *)writeDownloadIndexWithBlock:(NSDictionary * (^)(NSMutableDictionary *))block {
	NSParameterAssert(block != nil);

	return [[[self
		downloadStoreIndexFileLocation]
		flattenMap:^(NSURL *location) {
			return [RACSignal create:^(id<RACSubscriber> subscriber) {
				dispatch_barrier_async(self.queue, ^{
					if (subscriber.disposable.disposed) return;

					NSError *error;
					NSDictionary *propertyList = [self readPropertyListWithContentsOfURL:location error:&error];
					if (propertyList == nil) {
						[subscriber sendError:error];
						return;
					}

					NSDictionary *newPropertyList = block([propertyList mutableCopy]);
					if ([newPropertyList isEqual:propertyList]) {
						[subscriber sendCompleted];
						return;
					}

					NSData *newData = [NSKeyedArchiver archivedDataWithRootObject:newPropertyList];
					if (newData == nil) {
						NSDictionary *errorInfo = @{ NSURLErrorKey: location };
						[subscriber sendError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSPropertyListWriteStreamError userInfo:errorInfo]];
						return;
					}

					BOOL write = [newData writeToURL:location options:NSDataWritingAtomic error:&error];
					if (!write) {
						[subscriber sendError:error];
						return;
					}

					[subscriber sendCompleted];
				});
			}];
		}]
		setNameWithFormat:@"%@ %s", self, sel_getName(_cmd)];
}

- (NSDictionary *)readPropertyListWithContentsOfURL:(NSURL *)location error:(NSError **)errorRef {
	NSData *propertyListData = [NSData dataWithContentsOfURL:location options:NSDataReadingUncached error:NULL];
	if (propertyListData == nil) {
		return @{};
	}

	NSDictionary *propertyList = [NSKeyedUnarchiver unarchiveObjectWithData:propertyListData];
	if (propertyList == nil) {
		if (errorRef != NULL) {
			NSDictionary *errorInfo = @{ NSURLErrorKey: location };
			*errorRef = [NSError errorWithDomain:NSCocoaErrorDomain code:NSPropertyListReadCorruptError userInfo:errorInfo];
		}
		return nil;
	}

	return propertyList;
}

+ (NSString *)keyForURL:(NSURL *)URL {
	return URL.absoluteString;
}

+ (NSString *)fileNameForURL:(NSURL *)URL {
	NSString *key = [self keyForURL:URL];
	return [[[key dataUsingEncoding:NSUTF8StringEncoding] sqrl_SHA1Hash] sqrl_base16String];
}

- (RACSignal *)downloadForRequest:(NSURLRequest *)request {
	NSParameterAssert(request != nil);

	return [[[[self
		readDownloadIndex]
		map:^(NSDictionary *index) {
			NSString *key = [self.class keyForURL:request.URL];
			return index[key];
		}]
		flattenMap:^(SQRLResumableDownload *download) {
			if (download != nil) return [RACSignal return:download];

			return [[[self.directoryManager
				downloadDirectoryURL]
				map:^(NSURL *downloadDirectory) {
					return [downloadDirectory URLByAppendingPathComponent:[self.class fileNameForURL:request.URL]];
				}]
				map:^(NSURL *location) {
					return [[SQRLDownload alloc] initWithRequest:request fileURL:location];
				}];
		}]
		setNameWithFormat:@"%@ %s", self, sel_getName(_cmd)];
}

- (RACSignal *)setDownload:(SQRLResumableDownload *)download forRequest:(NSURLRequest *)request {
	NSParameterAssert(download.response != nil);
	NSParameterAssert(request != nil);

	return [[self
		writeDownloadIndexWithBlock:^(NSMutableDictionary *index) {
			NSString *key = [self.class keyForURL:request.URL];

			if (download != nil) {
				index[key] = download;
			} else {
				[index removeObjectForKey:key];
			}

			return index;
		}]
		setNameWithFormat:@"%@ %s", self, sel_getName(_cmd)];
}

@end
