//
//  SQRLDownloadController.m
//  Squirrel
//
//  Created by Keith Duncan on 26/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDownloadController.h"

#import <CommonCrypto/CommonDigest.h>

#import "SQRLFileManager.h"

NSString * const SQRLDownloadETagKey = @"SQRLDownloadETagKey";
NSString * const SQRLDownloadLocalFileKey = @"SQRLDownloadLocalFileKey";

@implementation SQRLDownloadController

+ (instancetype)defaultDownloadController {
	return [[self alloc] init];
}

- (NSURL *)downloadStoreDirectory {
	return SQRLFileManager.fileManagerForCurrentApplication.URLForDownloadDirectory;
}

- (void)removeAllResumableDownloads {
	[NSFileManager.defaultManager removeItemAtURL:self.downloadStoreDirectory error:NULL];
}

- (NSURL *)downloadStoreIndexFileLocation {
	return [self.downloadStoreDirectory URLByAppendingPathComponent:@"Index.plist"];
}

- (BOOL)coordinateReadingIndex:(NSError **)errorRef byAccessor:(void (^)(NSDictionary *))block {
	NSParameterAssert(block != nil);

	__block BOOL result = NO;

	NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
	[coordinator coordinateReadingItemAtURL:self.downloadStoreIndexFileLocation options:0 error:errorRef byAccessor:^(NSURL *newURL) {
		NSData *propertyListData = [NSData dataWithContentsOfURL:newURL options:0 error:errorRef];
		if (propertyListData == nil) return;

		NSDictionary *propertyList = [NSKeyedUnarchiver unarchiveObjectWithData:propertyListData];
		if (propertyList == nil) return;

		block(propertyList);
	}];

	return result;
}

- (BOOL)coordinateWritingIndex:(NSError **)errorRef byAccessor:(NSDictionary * (^)(NSDictionary *))block {
	NSParameterAssert(block != nil);

	__block BOOL result = NO;

	NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
	[coordinator coordinateWritingItemAtURL:self.downloadStoreIndexFileLocation options:0 error:errorRef byAccessor:^(NSURL *newURL) {
		NSDictionary *propertyList = nil;

		NSData *propertyListData = [NSData dataWithContentsOfURL:newURL options:0 error:NULL];
		if (propertyListData == nil) {
			propertyList = @{};
		} else {
			propertyList = [NSKeyedUnarchiver unarchiveObjectWithData:propertyListData];
			if (propertyList == nil) return;
		}

		NSDictionary *newPropertyList = block(propertyList);
		if ([newPropertyList isEqual:propertyList]) return;

		NSData *newData = [NSKeyedArchiver archivedDataWithRootObject:newPropertyList];
		if (newData == nil) return;

		BOOL write = [newData writeToURL:newURL options:NSDataWritingAtomic error:errorRef];
		if (!write) return;

		result = YES;
	}];

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
	NSMutableString *base16 = [NSMutableString stringWithCapacity:data.length * 2];
	for (NSUInteger idx = 0; idx < data.length; idx++) {
		[base16 appendFormat:@"%X", (unsigned int)*((uint8_t *)data.bytes + idx)];
	}
	return base16;
}

- (NSDictionary *)downloadForURL:(NSURL *)URL {
	__block NSError *downloadError = nil;
	__block NSDictionary *download = nil;

	NSString *key = [self.class keyForURL:URL];

	[self coordinateReadingIndex:&downloadError byAccessor:^(NSDictionary *index) {
		download = index[key];
	}];

	if (download == nil) {
		return @{
			SQRLDownloadLocalFileKey: [self.downloadStoreDirectory URLByAppendingPathComponent:[self.class fileNameForURL:URL]],
		};
	}

	return download;
}

- (void)setDownload:(NSDictionary *)download forURL:(NSURL *)URL {
	NSArray *requiredKeys = @[ SQRLDownloadETagKey, SQRLDownloadLocalFileKey ];
	NSParameterAssert([[NSSet setWithArray:requiredKeys] isSubsetOfSet:[NSSet setWithArray:download.allKeys]]);

	NSString *key = [self.class keyForURL:URL];

	NSError *writeError = nil;
	__unused BOOL write = [self coordinateWritingIndex:&writeError byAccessor:^(NSDictionary *index) {
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
