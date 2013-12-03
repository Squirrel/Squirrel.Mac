//
//  SQRLDownloadController.m
//  Squirrel
//
//  Created by Keith Duncan on 26/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDownloadManager.h"

#import <ReactiveCocoa/ReactiveCocoa.h>
#import <CommonCrypto/CommonCrypto.h>

#import "SQRLDirectoryManager.h"
#import "SQRLResumableDownload.h"

@interface SQRLDownloadManager ()
@property (nonatomic, strong, readonly) SQRLDirectoryManager *directoryManager;
@property (nonatomic, assign, readonly) dispatch_queue_t queue;
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
	dispatch_set_target_queue(_queue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));

	return self;
}

- (void)dealloc {
	dispatch_release(_queue);
}

- (RACSignal *)removeAllResumableDownloads {
	return [[[RACSignal
		merge:@[
			[self downloadStoreIndexFileLocation],
			[self.directoryManager downloadDirectoryURL]
		]]
		flattenMap:^ (NSURL *location) {
			return [[[[RACSignal
				return:location]
				try:^(NSURL *location, NSError **errorRef) {
					return [NSFileManager.defaultManager removeItemAtURL:location error:errorRef];
				}]
				catch:^(NSError *error) {
					if ([error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileNoSuchFileError) return RACSignal.empty;
					return [RACSignal error:error];
				}]
				ignoreValues];
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

// Reads the download index.
//
// Returns a signal which sends the download index at time of read then
// completes, or errors.
- (RACSignal *)readDownloadIndex {
	return [[[self
		downloadStoreIndexFileLocation]
		flattenMap:^(NSURL *location) {
			return [[RACSignal
				create:^(id<RACSubscriber> subscriber) {
					dispatch_sync(self.queue, ^{
						if (subscriber.disposable.disposed) return;

						NSError *error = nil;
						NSData *propertyListData = [NSData dataWithContentsOfURL:location options:0 error:&error];
						if (propertyListData == nil) {
							[subscriber sendError:error];
							return;
						}

						[subscriber sendNext:propertyListData];
						[subscriber sendCompleted];
					});
				}]
				tryMap:^ NSDictionary * (NSData *propertyListData, NSError **errorRef) {
					NSDictionary *propertyList = [NSKeyedUnarchiver unarchiveObjectWithData:propertyListData];
					if (propertyList == nil) {
						if (errorRef != NULL) {
							NSDictionary *errorInfo = @{ NSURLErrorKey: location };
							*errorRef = [NSError errorWithDomain:NSCocoaErrorDomain code:NSPropertyListReadCorruptError userInfo:errorInfo];
						}
						return nil;
					}

					return propertyList;
				}];
		}]
		setNameWithFormat:@"%@ %s", self, sel_getName(_cmd)];
}

// Write a new download index.
//
// block - Map from the old download index to the new download index. Writing
//         is serialised, subsequent writers will receive the output of the
//         previous map block. If the output of the map is equal to the input
//         no write is attempted and the returned signal completes.
//
// Returns a signal which completes or errors.
- (RACSignal *)writeDownloadIndexWithBlock:(NSDictionary * (^)(NSDictionary *))block {
	NSParameterAssert(block != nil);

	return [[[self
		downloadStoreIndexFileLocation]
		flattenMap:^(NSURL *location) {
			return [RACSignal create:^(id<RACSubscriber> subscriber) {
				dispatch_barrier_sync(self.queue, ^{
					if (subscriber.disposable.disposed) return;

					NSDictionary *propertyList = nil;

					NSData *propertyListData = [NSData dataWithContentsOfURL:location options:NSDataReadingUncached error:NULL];
					if (propertyListData == nil) {
						propertyList = @{};
					} else {
						propertyList = [NSKeyedUnarchiver unarchiveObjectWithData:propertyListData];
						if (propertyList == nil) {
							NSDictionary *errorInfo = @{ NSURLErrorKey: location };
							[subscriber sendError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSPropertyListReadCorruptError userInfo:errorInfo]];
							return;
						}
					}

					NSDictionary *newPropertyList = block(propertyList);
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

					NSError *error = nil;
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

+ (NSString *)keyForURL:(NSURL *)URL {
	return URL.absoluteString;
}

+ (NSString *)fileNameForURL:(NSURL *)URL {
	NSString *key = [self keyForURL:URL];
	return [self base16:[self SHA1:[key dataUsingEncoding:NSUTF8StringEncoding]]];
}

+ (NSData *)SHA1:(NSData *)data {
	unsigned char hash[CC_SHA1_DIGEST_LENGTH];
	CC_SHA1(data.bytes, (CC_LONG)data.length, hash);
	return [NSData dataWithBytes:hash length:sizeof(hash) / sizeof(*hash)];
}

+ (NSString *)base16:(NSData *)data {
	NSMutableString *base16 = [NSMutableString stringWithCapacity:data.length * 2];
	for (NSUInteger idx = 0; idx < data.length; idx++) {
		uint8_t byte = *((uint8_t *)data.bytes + idx);
		[base16 appendFormat:@"%02hhx", byte];
	}
	return base16;
}

- (RACSignal *)downloadForRequest:(NSURLRequest *)request {
	NSParameterAssert(request != nil);

	return [[[[[self
		readDownloadIndex]
		catch:^(NSError *error) {
			if ([error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileReadNoSuchFileError) return [RACSignal return:@{}];
			return [RACSignal error:error];
		}]
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
		writeDownloadIndexWithBlock:^(NSDictionary *index) {
			NSString *key = [self.class keyForURL:request.URL];

			NSMutableDictionary *newIndex = [index mutableCopy];

			if (download != nil) {
				newIndex[key] = download;
			} else {
				[newIndex removeObjectForKey:key];
			}

			return newIndex;
		}]
		setNameWithFormat:@"%@ %s", self, sel_getName(_cmd)];
}

@end
