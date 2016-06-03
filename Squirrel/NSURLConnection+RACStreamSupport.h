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

/**
 Lazily loads data for the given request in the background and save the content on the disk in a file created at the provided URL.
 Returns a signal which will begin loading the request upon each subscription,
 then send a `RACTuple` of the received `NSURLResponse` and destination file
 `NSURL`. The NSURLConnection is scheduled on the main RunLoop. If any errors occur, the
 returned signal will error out.

 @param request The URL request to load. This must not be nil.
 @param destination The file URL to the filesystem destination of the downloaded data.

 */
+ (RACSignal *)rac_startAsynchronousRequest:(NSURLRequest *)request into:(NSURL*)destination;
@end
