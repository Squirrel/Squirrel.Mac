//
//  SQRLDownloadOperation.h
//  Squirrel
//
//  Created by Keith Duncan on 25/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

@class SQRLResumableDownloadManager;

// Resumably download a remote resource.
//
// If the resource has previously been downloaded this operation may return the
// URL of an existing file, contingent on the server matching the ETag of the
// original response.
@interface SQRLDownloadOperation : NSOperation

// Initialiser.
//
// request            - Must be non nil, body of the response is streamed to
//                      disk. If the response includes an ETag the download can
//                      be resumed automatically by subsequent download
//                      operations with the same URL.
// downloadController - Must be non nil, determines where the downloads will be
//                      stored and resumed from. For a previously started
//                      download to be resumed, an equivalent download
//                      controller should be provided.
- (instancetype)initWithRequest:(NSURLRequest *)request downloadManager:(SQRLResumableDownloadManager *)downloadManager __attribute__((nonnull (1, 2)));

// When the operation `isFinished` this can be invoked to get the operation
// result, retrieve the response and the location that the download has been
// written to.
//
// To use the `completionProvider` add a dependency to the download operation
// and invoke the `completionProvider:error:` when it runs.
//
// Returns a file URL to the download location.
//  - responseRef, can be NULL.
//  - errorRef, can be NULL.
//  - Returns a file:// URL to the downloaded resource.
- (NSURL *)completionProvider:(NSURLResponse **)responseRef error:(NSError **)errorRef;

@end
