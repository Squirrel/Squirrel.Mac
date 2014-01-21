//
//  SQRLResumableDownload.m
//  Squirrel
//
//  Created by Keith Duncan on 30/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLResumableDownload.h"

#import <ReactiveCocoa/ReactiveCocoa.h>

#import "NSHTTPURLResponse+SQRLExtensions.h"

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

- (BOOL)isEqual:(SQRLResumableDownload *)object {
	if (![object isKindOfClass:self.class]) return NO;

	if (!(self.response == nil && object.response == nil) && ![self responseEqual:object.response]) return NO;
	if (![object.fileURL isEqual:self.fileURL]) return NO;

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
			NSString *ETag = [response sqrl_valueForHTTPHeaderField:@"ETag"];
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

@end
