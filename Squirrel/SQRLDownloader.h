//
//  SQRLDownloadOperation.h
//  Squirrel
//
//  Created by Keith Duncan on 25/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

@class SQRLDownloadManager;
@class RACSignal;

// Resumably download a remote resource.
//
// If the resource has previously been downloaded this operation may return the
// URL of an existing file, contingent on the server matching the ETag of the
// original response.
@interface SQRLDownloader : NSObject

// This is the designated initialiser. The body of the response is streamed to
// disk. If the response includes an ETag the download can be resumed
// automatically by subsequent download operations initialised with a request of
// equal URL.
//
// request         - Must be non nil, the request is issued with
//                   NSURLConnection.
// downloadManager - Must be non nil, determines where the downloads will be
//                   stored and resumed from. For a previously started download
//                   to be resumed, an equivalent download manager should be
//                   provided.
- (instancetype)initWithRequest:(NSURLRequest *)request downloadManager:(SQRLDownloadManager *)downloadManager __attribute__((nonnull (1, 2)));

// Starts downloading the resource, cancels when the the subscription is
// disposed.
//
// Returns a signal which sends a tuple of `NSURLResponse` and a file
// scheme `NSURL` where the resource has been stored on disk, then completes, or
// errors.
- (RACSignal *)download;

@end
