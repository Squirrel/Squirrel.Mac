//
//  NSURLConnection+RACSupport.h
//  ReactiveCocoa
//
//  Created by Justin Spahr-Summers on 2013-10-01.
//  Copyright (c) 2013 GitHub, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <ReactiveCocoa/ReactiveCocoa.h>

@class RACSignal;

@interface NSURLConnection (RACStreamSupport)
+ (RACSignal *)rac_startAsynchronousRequest:(NSURLRequest *)request into:(NSURL*)destination;
@end
