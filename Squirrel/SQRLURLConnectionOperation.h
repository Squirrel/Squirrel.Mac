//
//  SQRLURLConnectionOperation.h
//  Squirrel
//
//  Created by Keith Duncan on 25/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

@class RACSignal;

// Bridges `NSURLConnection` to RAC.
@interface SQRLURLConnectionOperation : NSObject

// Designated initialiser.
//
// request - Must be non nil.
//
// Returns a signal which sends a tuple of `NSURLResponse`, `NSData` then
// completes, or errors.
+ (RACSignal *)sqrl_sendAsynchronousRequest:(NSURLRequest *)request;

@end
