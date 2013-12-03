//
//  SQRLResumableDownload.m
//  Squirrel
//
//  Created by Keith Duncan on 30/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLResumableDownload.h"

#import <ReactiveCocoa/ReactiveCocoa.h>

@implementation SQRLResumableDownload

- (instancetype)initWithRequest:(NSURLRequest *)request response:(NSHTTPURLResponse *)response fileURL:(NSURL *)fileURL {
	NSParameterAssert(response != nil);
	NSParameterAssert(fileURL != nil);

	return [self initWithDictionary:@{
		@keypath(self.request): request,
		@keypath(self.response): response,
		@keypath(self.fileURL): fileURL,
	} error:NULL];
}

- (BOOL)isEqual:(id)object {
	if (![object isKindOfClass:self.class]) return NO;

	SQRLResumableDownload *other = (SQRLResumableDownload *)object;
	if (!(self.response == nil && other.response == nil) && ![self responseEqual:other.response]) return NO;
	if (![other.fileURL isEqual:self.fileURL]) return NO;

	return YES;
}

- (BOOL)responseEqual:(NSHTTPURLResponse *)response {
	if (![response.URL isEqual:self.response.URL]) return NO;
	if (response.statusCode != self.response.statusCode) return NO;
	if (![response.allHeaderFields isEqual:self.response.allHeaderFields]) return NO;
	return YES;
}

- (RACSignal *)resumableRequest {
	return [[[super
		resumableRequest]
		map:^ NSURLRequest * (NSURLRequest *request) {
			NSHTTPURLResponse *response = self.response;
			NSString *ETag = [self.class ETagFromResponse:response];
			if (ETag == nil) return request;

			NSNumber *alreadyDownloadedSize = nil;
			NSError *alreadyDownloadedSizeError = nil;
			BOOL getAlreadyDownloadedSize = [self.fileURL getResourceValue:&alreadyDownloadedSize forKey:NSURLFileSizeKey error:&alreadyDownloadedSizeError];
			if (!getAlreadyDownloadedSize) return request;

			NSMutableURLRequest *newRequest = [request mutableCopy];
			[newRequest setValue:ETag forHTTPHeaderField:@"If-Range"];
			[newRequest setValue:[NSString stringWithFormat:@"%llu-", alreadyDownloadedSize.unsignedLongLongValue] forHTTPHeaderField:@"Range"];
			return newRequest;
		}]
		setNameWithFormat:@"%@ %s", self, sel_getName(_cmd)];
}

+ (NSString *)ETagFromResponse:(NSHTTPURLResponse *)response {
	return [[[response.allHeaderFields.rac_signal
		filter:^ BOOL (RACTuple *keyValuePair) {
			return [keyValuePair.first caseInsensitiveCompare:@"ETag"] == NSOrderedSame;
		}]
		reduceEach:^(NSString *key, NSString *value) {
			return value;
		}]
		first];
}

@end
