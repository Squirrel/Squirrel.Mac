//
//  SQRLDownload.m
//  Squirrel
//
//  Created by Keith Duncan on 21/11/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDownload.h"
#import "SQRLDownload+Private.h"

#import <ReactiveCocoa/ReactiveCocoa.h>

@implementation SQRLDownload

- (instancetype)initWithRequest:(NSURLRequest *)request fileURL:(NSURL *)fileURL {
	return [self initWithDictionary:@{
		@keypath(self.request): request,
		@keypath(self.fileURL): fileURL,
	} error:NULL];
}

- (RACSignal *)resumableRequest {
	return [[RACSignal
		return:self.request]
		setNameWithFormat:@"%@ %s", self, sel_getName(_cmd)];
}

@end
