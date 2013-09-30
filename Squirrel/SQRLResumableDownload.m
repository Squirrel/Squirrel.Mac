//
//  SQRLResumableDownload.m
//  Squirrel
//
//  Created by Keith Duncan on 30/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLResumableDownload.h"

static NSString * const SQRLResumableDownloadResponseKey = @"response";
static NSString * const SQRLResumableDownloadFileURLKey = @"fileURL";

@implementation SQRLResumableDownload

- (instancetype)initWithResponse:(NSHTTPURLResponse *)response fileURL:(NSURL *)fileURL {
	NSParameterAssert(fileURL != nil);

	self = [self init];
	if (self == nil) return nil;

	_response = [response copy];
	_fileURL = [fileURL copy];

	return self;
}

- (instancetype)initWithCoder:(NSCoder *)decoder {
	NSParameterAssert(decoder.allowsKeyedCoding);

	self = [self init];
	if (self == nil) return nil;

	_response = [[decoder decodeObjectForKey:SQRLResumableDownloadResponseKey] copy];
	_fileURL = [[decoder decodeObjectForKey:SQRLResumableDownloadFileURLKey] copy];

	return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
	NSParameterAssert(coder.allowsKeyedCoding);

	[coder encodeObject:self.response forKey:SQRLResumableDownloadResponseKey];
	[coder encodeObject:self.fileURL forKey:SQRLResumableDownloadFileURLKey];
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

- (NSUInteger)hash {
	return self.fileURL.hash;
}

@end
