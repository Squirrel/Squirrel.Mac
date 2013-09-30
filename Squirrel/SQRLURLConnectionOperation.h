//
//  SQRLURLConnectionOperation.h
//  Squirrel
//
//  Created by Keith Duncan on 25/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

// Combines an `NSURLConnection` with the `NSOperation` dependency model.
@interface SQRLURLConnectionOperation : NSOperation

// Initialiser.
//
// request - Must be non nil.
- (instancetype)initWithRequest:(NSURLRequest *)request __attribute__((nonnull (1)));

// When the operation `isFinished` this will be non nil and can be used to
// retrieve the response and body data of the request.
//
// To use the `responseProvider` add a dependency to the connection operation
// and invoke the `completionProvider` when it runs.
//
// The type signature of this block resembles
// `+[NSURLConnection sendSynchronousRequest:returningResponse:error:]` but the
// request is issued in a non blocking fashion, you can enqueue a large number
// of these operations without blocking a large number of threads.
//
// Returns a block which can be invoked to get the response.
//  - responseRef, can be NULL.
//  - errorRef, can be NULL.
//  - Returns the response body data.
@property (readonly, copy, atomic) NSData * (^responseProvider)(NSURLResponse **responseRef, NSError **errorRef);

@end
