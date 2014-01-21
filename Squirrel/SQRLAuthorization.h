//
//  SQRLAuthorization.h
//  Squirrel
//
//  Created by Keith Duncan on 06/01/2014.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

#import <Security/Security.h>

// Wraps an AuthorizationRef.
@interface SQRLAuthorization : NSObject

// Designated initializer.
//
// authorization - Must not be NULL, the returned object assumes ownership of
//                 the passed authorization.
//
// Returns an object which ties the `authorization` argument to the returned
// object's lifetime.
- (instancetype)initWithAuthorization:(AuthorizationRef)authorization;

@property (readonly, nonatomic, assign) AuthorizationRef authorization;

@end
