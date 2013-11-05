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

- (instancetype)initWithResponse:(NSHTTPURLResponse *)response fileURL:(NSURL *)fileURL {
	NSParameterAssert(fileURL != nil);

	return [self initWithDictionary:@{
		@keypath(self, response): response ?: NSNull.null,
		@keypath(self, fileURL): fileURL,
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

@end
