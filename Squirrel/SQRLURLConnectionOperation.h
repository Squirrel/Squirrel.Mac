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

// When the operation `isFinished` this can be invoked to get the operation
// result, retrieve the response and body data of the request.
//
// To use the `responseProvider:error:` add a dependency to the connection.
//
// The type signature of this block resembles
// `+[NSURLConnection sendSynchronousRequest:returningResponse:error:]` but the
// request is issued in a non blocking fashion, you can enqueue a large number
// of these operations without blocking a large number of threads.
//
// responseRef - Can be NULL.
// errorRef - Can be NULL.
//
// Returns the body data or nil if there was an error.
- (NSData *)responseProvider:(NSURLResponse **)responseRef error:(NSError **)errorRef;

@end
