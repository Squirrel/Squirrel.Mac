//
//  SQRLDownloadOperation.h
//  Squirrel
//
//  Created by Keith Duncan on 25/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

// Resumably download a remote resource.
//
// If the resource has previously been downloaded this operation may return the
// URL of an existing file, contingent on the server matching the ETag of the
// original response.
@interface SQRLDownloadOperation : NSOperation

// Initialiser.
//
// request - Must be non nil, body of the response is streamed to disk.
//           If the response includes an ETag the download can be resumed
//           automatically by subsequent download operations with the same URL.
- (instancetype)initWithRequest:(NSURLRequest *)request __attribute__((nonnull (1)));

// When the operation `isFinished` this will be non nil and return the result of
// the download.
//
// To use the `completionProvider` add a dependency to the download operation
// and invoke the `completionProvider` when it runs.
//
// Returns a block which can be invoked to get the response.
//  - responseRef, can be NULL.
//  - errorRef, can be NULL.
//  - Returns a file:// URL to the downloaded resource.
@property (readonly, copy, atomic) NSURL * (^completionProvider)(NSURLResponse **responseRef, NSError **errorRef);

@end
