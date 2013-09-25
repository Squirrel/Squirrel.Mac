//
//  SQRLDownloadedUpdate.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-09-25.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDownloadedUpdate.h"

@implementation SQRLDownloadedUpdate

- (id)initWithUpdate:(SQRLUpdate *)update bundle:(NSBundle *)bundle {
	NSParameterAssert(update != nil);
	NSParameterAssert(bundle != nil);

	self = [super initWithJSON:update.JSON];
	if (self == nil) return nil;

	_bundle = bundle;

	return self;
}

@end
