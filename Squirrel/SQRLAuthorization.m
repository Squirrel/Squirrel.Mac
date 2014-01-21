//
//  SQRLAuthorization.m
//  Squirrel
//
//  Created by Keith Duncan on 06/01/2014.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import "SQRLAuthorization.h"

@implementation SQRLAuthorization

- (instancetype)initWithAuthorization:(AuthorizationRef)authorization {
	NSParameterAssert(authorization != NULL);

	self = [self init];
	if (self == nil) return nil;

	_authorization = authorization;

	return self;
}

- (void)dealloc {
	if (_authorization != NULL) AuthorizationFree(_authorization, kAuthorizationFlagDestroyRights);
}

@end
