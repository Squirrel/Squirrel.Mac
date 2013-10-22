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
@property (nonatomic, assign, readonly) dispatch_queue_t indexQueue;
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

	_indexQueue = dispatch_queue_create("com.github.Squirrel.SQRLDownloadController.index", DISPATCH_QUEUE_CONCURRENT);

	return self;
}

- (void)dealloc {
	dispatch_release(_indexQueue);
}

- (RACSignal *)removeAllResumableDownloads {
	NSArray *locationSignals = @[ [self downloadStoreIndexFileLocation], [self.directoryManager downloadDirectoryURL] ];
	return [[[[locationSignals
		rac_sequence]
		signalWithScheduler:RACScheduler.immediateScheduler]
		map:^ RACSignal * (NSURL *location) {
			NSError *error = nil;
			BOOL remove = [NSFileManager.defaultManager removeItemAtURL:location error:&error];
			if (!remove) return [RACSignal error:error];
			
			return [RACSignal return:RACUnit.defaultUnit];
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

- (BOOL)coordinateReadingIndex:(NSError **)errorRef byAccessor:(void (^)(NSDictionary *))block {
	NSParameterAssert(block != nil);

	__block BOOL result = NO;

	dispatch_sync(self.indexQueue, ^{
		NSData *propertyListData = [NSData dataWithContentsOfURL:self.downloadStoreIndexFileLocation.first options:0 error:errorRef];
		if (propertyListData == nil) return;

		NSDictionary *propertyList = [NSKeyedUnarchiver unarchiveObjectWithData:propertyListData];
		if (propertyList == nil) {
			if (errorRef != NULL) *errorRef = [NSError errorWithDomain:NSCocoaErrorDomain code:NSPropertyListReadCorruptError userInfo:nil];
			return;
		}

		block(propertyList);

		result = YES;
	});

	return result;
}

- (BOOL)coordinateWritingIndex:(NSError **)errorRef byAccessor:(NSDictionary * (^)(NSDictionary *))block {
	NSParameterAssert(block != nil);

	__block BOOL result = NO;

	dispatch_barrier_sync(self.indexQueue, ^{
		NSURL *fileLocation = self.downloadStoreIndexFileLocation.first;

		NSDictionary *propertyList = nil;

		NSData *propertyListData = [NSData dataWithContentsOfURL:fileLocation options:0 error:NULL];
		if (propertyListData == nil) {
			propertyList = @{};
		} else {
			propertyList = [NSKeyedUnarchiver unarchiveObjectWithData:propertyListData];
			if (propertyList == nil) {
				if (errorRef != NULL) *errorRef = [NSError errorWithDomain:NSCocoaErrorDomain code:NSPropertyListReadCorruptError userInfo:nil];
				return;
			}
		}

		NSDictionary *newPropertyList = block(propertyList);
		if ([newPropertyList isEqual:propertyList]) {
			result = YES;
			return;
		}

		NSData *newData = [NSKeyedArchiver archivedDataWithRootObject:newPropertyList];
		if (newData == nil) {
			if (errorRef != NULL) *errorRef = [NSError errorWithDomain:NSCocoaErrorDomain code:NSPropertyListWriteStreamError userInfo:nil];
			return;
		}

		if (![newData writeToURL:fileLocation options:NSDataWritingAtomic error:errorRef]) return;

		result = YES;
	});

	return result;
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

- (SQRLResumableDownload *)downloadForRequest:(NSURLRequest *)request error:(NSError **)errorRef {
	NSParameterAssert(request != nil);

	NSError *downloadError = nil;
	__block SQRLResumableDownload *download = nil;

	NSString *key = [self.class keyForURL:request.URL];

	[self coordinateReadingIndex:&downloadError byAccessor:^(NSDictionary *index) {
		download = index[key];
	}];

	if (download == nil) {
		NSURL *downloadDirectory = self.directoryManager.downloadDirectoryURL.first;
		if (![NSFileManager.defaultManager createDirectoryAtURL:downloadDirectory withIntermediateDirectories:YES attributes:nil error:errorRef]) return nil;

		NSURL *localURL = [downloadDirectory URLByAppendingPathComponent:[self.class fileNameForURL:request.URL]];
		return [[SQRLResumableDownload alloc] initWithResponse:nil fileURL:localURL];
	}

	return download;
}

- (void)setDownload:(SQRLResumableDownload *)download forRequest:(NSURLRequest *)request {
	NSParameterAssert(download.response != nil);
	NSParameterAssert(request != nil);

	NSString *key = [self.class keyForURL:request.URL];

	NSError *writeError = nil;
	[self coordinateWritingIndex:&writeError byAccessor:^(NSDictionary *index) {
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
