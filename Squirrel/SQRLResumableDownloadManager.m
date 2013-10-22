//
//  SQRLDownloadController.m
//  Squirrel
//
//  Created by Keith Duncan on 26/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLResumableDownloadManager.h"

#import "ReactiveCocoa/ReactiveCocoa.h"
#import <CommonCrypto/CommonCrypto.h>

#import "SQRLDirectoryManager.h"
#import "SQRLResumableDownload.h"

@interface SQRLResumableDownloadManager ()
@property (nonatomic, strong, readonly) SQRLDirectoryManager *directoryManager;
@property (nonatomic, strong, readonly) RACScheduler *serialScheduler;
@end

@implementation SQRLResumableDownloadManager

+ (instancetype)defaultDownloadManager {
	static SQRLResumableDownloadManager *defaultDownloadManager = nil;
	static dispatch_once_t defaultDownloadManagerPredicate = 0;

	dispatch_once(&defaultDownloadManagerPredicate, ^{
		defaultDownloadManager = [[self alloc] init];
	});

	return defaultDownloadManager;
}

- (id)init {
	self = [super init];
	if (self == nil) return nil;

	_directoryManager = [SQRLDirectoryManager currentApplicationManager];

	_serialScheduler = [[RACTargetQueueScheduler alloc] initWithName:@"com.github.Squirrel.SQRLDownloadController.serialScheduler" targetQueue:DISPATCH_TARGET_QUEUE_DEFAULT];

	return self;
}

- (RACSignal *)removeAllResumableDownloads {
	NSArray *locationSignals = @[ [self downloadStoreIndexFileLocation], [self.directoryManager downloadDirectoryURL] ];
	return [[[[locationSignals
		rac_sequence]
		signalWithScheduler:RACScheduler.immediateScheduler]
		map:^ RACSignal * (RACSignal *locationSignal) {
			return [locationSignal map:^ RACSignal * (NSURL *location) {
				NSError *error = nil;
				BOOL remove = [NSFileManager.defaultManager removeItemAtURL:location error:&error];
				if (!remove) return [RACSignal error:error];

				return [RACSignal empty];
			}];
		}]
		flatten];
}

- (RACSignal *)downloadStoreIndexFileLocation {
	return [[[self.directoryManager
		applicationSupportURL]
		flattenMap:^ RACSignal * (NSURL *directory) {
			return [RACSignal return:[directory URLByAppendingPathComponent:@"DownloadIndex.plist"]];
		}]
		setNameWithFormat:@"%@ -downloadStoreIndexFileLocation", self];
}

- (RACSignal *)readDownloadIndexWithBlock:(RACSignal * (^)(NSDictionary *))block {
	NSParameterAssert(block != nil);

	return [[self.downloadStoreIndexFileLocation
		deliverOn:self.serialScheduler]
		flattenMap:^ RACSignal * (NSURL *location) {
			NSError *error = nil;
			NSData *propertyListData = [NSData dataWithContentsOfURL:location options:0 error:&error];
			if (propertyListData == nil) return [RACSignal error:error];

			NSDictionary *propertyList = [NSKeyedUnarchiver unarchiveObjectWithData:propertyListData];
			if (propertyList == nil) {
				return [RACSignal error:[NSError errorWithDomain:NSCocoaErrorDomain code:NSPropertyListReadCorruptError userInfo:nil]];
			}

			return block(propertyList);
		}];
}

- (RACSignal *)writeDownloadIndexWithBlock:(NSDictionary * (^)(NSDictionary *))block {
	NSParameterAssert(block != nil);

	return [[self.downloadStoreIndexFileLocation
		deliverOn:self.serialScheduler]
		flattenMap:^ RACSignal * (NSURL *location) {
			NSDictionary *propertyList = nil;

			NSData *propertyListData = [NSData dataWithContentsOfURL:location options:0 error:NULL];
			if (propertyListData == nil) {
				propertyList = @{};
			} else {
				propertyList = [NSKeyedUnarchiver unarchiveObjectWithData:propertyListData];
				if (propertyList == nil) return [RACSignal error:[NSError errorWithDomain:NSCocoaErrorDomain code:NSPropertyListReadCorruptError userInfo:nil]];
			}

			NSDictionary *newPropertyList = block(propertyList);
			if ([newPropertyList isEqual:propertyList]) return [RACSignal empty];

			NSData *newData = [NSKeyedArchiver archivedDataWithRootObject:newPropertyList];
			if (newData == nil) return [RACSignal error:[NSError errorWithDomain:NSCocoaErrorDomain code:NSPropertyListWriteStreamError userInfo:nil]];

			NSError *error = nil;
			BOOL write = [newData writeToURL:location options:NSDataWritingAtomic error:&error];
			if (!write) return [RACSignal error:error];

			return [RACSignal empty];
		}];
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
	char const *alphabet = "0123456789ABCDEF"; // <http://tools.ietf.org/html/rfc4648#section-8>
	NSMutableString *base16 = [NSMutableString stringWithCapacity:data.length * 2];
	for (NSUInteger idx = 0; idx < data.length; idx++) {
		uint8_t byte = *((uint8_t *)data.bytes + idx);
		[base16 appendFormat:@"%c%c", alphabet[(byte & /* 0b11110000 */ 240) >> 4], alphabet[(byte & /* 0b00001111 */ 15)]];
	}
	return base16;
}

- (RACSignal *)downloadForRequest:(NSURLRequest *)request {
	NSParameterAssert(request != nil);

	return [self readDownloadIndexWithBlock:^ RACSignal * (NSDictionary *index) {
		NSString *key = [self.class keyForURL:request.URL];
		SQRLResumableDownload *download = index[key];
		if (download != nil) return [RACSignal return:download];

		return [[[self.directoryManager
			downloadDirectoryURL]
			map:^ NSURL * (NSURL *downloadDirectory) {
				return [downloadDirectory URLByAppendingPathComponent:[self.class fileNameForURL:request.URL]];
			}]
			map:^ SQRLResumableDownload * (NSURL *location) {
				return [[SQRLResumableDownload alloc] initWithResponse:nil fileURL:location];
			}];
	}];
}

- (RACSignal *)setDownload:(SQRLResumableDownload *)download forRequest:(NSURLRequest *)request {
	NSParameterAssert(download.response != nil);
	NSParameterAssert(request != nil);

	return [self writeDownloadIndexWithBlock:^ NSDictionary * (NSDictionary *index) {
		NSString *key = [self.class keyForURL:request.URL];

		NSMutableDictionary *newIndex = [index mutableCopy];

		if (download != nil) {
			newIndex[key] = download;
		} else {
			[newIndex removeObjectForKey:key];
		}

		return newIndex;
	}];
}

@end
