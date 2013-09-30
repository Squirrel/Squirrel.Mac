//
//  SQRLDownloadController.m
//  Squirrel
//
//  Created by Keith Duncan on 26/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDownloadController.h"

#import <CommonCrypto/CommonCrypto.h>

#import "SQRLFileManager.h"
#import "SQRLResumableDownload.h"

@implementation SQRLDownloadController

+ (instancetype)defaultDownloadController {
	return [[self alloc] init];
}

- (NSURL *)downloadStoreDirectory {
	return SQRLFileManager.fileManagerForCurrentApplication.URLForDownloadDirectory;
}

- (BOOL)removeAllResumableDownloads:(NSError **)errorRef {
	return [NSFileManager.defaultManager removeItemAtURL:self.downloadStoreDirectory error:errorRef];
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
	char const *alphabet = "0123456789ABCDEF"; // <http://tools.ietf.org/html/rfc4648#section-8>
	NSMutableString *base16 = [NSMutableString stringWithCapacity:data.length * 2];
	for (NSUInteger idx = 0; idx < data.length; idx++) {
		uint8_t byte = *((uint8_t *)data.bytes + idx);
		[base16 appendFormat:@"%c%c", alphabet[(byte & /* 0b11110000 */ 240) >> 4], alphabet[(byte & /* 0b00001111 */ 15)]];
	}
	return base16;
}

- (SQRLResumableDownload *)downloadForURL:(NSURL *)URL {
	NSParameterAssert(URL != nil);
	
	__block NSError *downloadError = nil;
	__block SQRLResumableDownload *download = nil;

	NSString *key = [self.class keyForURL:URL];

	[self coordinateReadingIndex:&downloadError byAccessor:^(NSDictionary *index) {
		download = index[key];
	}];

	if (download == nil) {
		NSURL *localURL = [self.downloadStoreDirectory URLByAppendingPathComponent:[self.class fileNameForURL:URL]];
		return [[SQRLResumableDownload alloc] initWithResponse:nil fileURL:localURL];
	}

	return download;
}

- (void)setDownload:(SQRLResumableDownload *)download forURL:(NSURL *)URL {
	NSParameterAssert(download.response != nil);
	NSParameterAssert(URL != nil);

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
