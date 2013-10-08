//
//  SQRLDownloadedUpdate.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-09-25.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDownloadedUpdate.h"

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

	self = [super initWithDictionary:update.dictionaryValue error:NULL];
	if (self == nil) return nil;

	_bundleURL = bundle.bundleURL;

	return self;
}

#pragma mark MTLJSONSerializing

+ (NSDictionary *)JSONKeyPathsByPropertyKey {
	return [super.JSONKeyPathsByPropertyKey mtl_dictionaryByAddingEntriesFromDictionary:@{
		@"bundleURL": NSNull.null
	}];
}

@end
