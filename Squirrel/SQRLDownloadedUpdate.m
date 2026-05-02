//
//  SQRLDownloadedUpdate.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-09-25.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDownloadedUpdate.h"
#import <ReactiveObjC/ReactiveObjC.h>

@interface SQRLDownloadedUpdate ()

// The URL to the `bundle` the receiver was initialized with.
@property (nonatomic, copy, readonly) NSURL *bundleURL;

@end

@implementation SQRLDownloadedUpdate

#pragma mark Properties

- (NSBundle *)bundle {
	return [NSBundle bundleWithURL:self.bundleURL];
}

#pragma mark Lifecycle

- (id)initWithUpdate:(SQRLUpdate *)update bundle:(NSBundle *)bundle {
	NSParameterAssert(update != nil);
	NSParameterAssert(bundle != nil);
	NSParameterAssert(bundle.bundleURL != nil);

	return [self initWithDictionary:@{
		@keypath(self.update): update,
		@keypath(self.bundleURL): bundle.bundleURL
	} error:NULL];
}

#pragma mark MTLJSONSerializing

+ (NSDictionary *)JSONKeyPathsByPropertyKey {
	return @{
		@keypath(SQRLDownloadedUpdate.new, bundleURL): NSNull.null
	};
}

@end
