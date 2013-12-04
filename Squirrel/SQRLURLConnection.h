//
//  SQRLURLConnection.h
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
@interface SQRLURLConnection : NSObject

// This is the designated initialiser. The body of the response is streamed to
// disk. If the response includes an ETag the download can be resumed
// automatically by subsequent download operations initialised with a request of
// equal URL.
//
// request - Must not be nil, the request is issued with NSURLConnection.
- (instancetype)initWithRequest:(NSURLRequest *)request __attribute__((nonnull (1)));

// Starts retrieving the resource, cancels when the subscription is disposed.
//
// Returns a signal when sends a tuple of `NSURLResponse` and `NSData`, then
// completes or errors.
- (RACSignal *)retrieve;

// Starts downloading the resource, cancels when the the subscription is
// disposed.
//
// downloadManager - Must be non nil, determines where the downloads will be
//                   stored and resumed from. For a previously started download
//                   to be resumed, an equivalent download manager should be
//                   provided.
//
// Returns a signal which sends a tuple of `NSURLResponse` and a file
// scheme `NSURL` where the resource has been stored on disk, then completes, or
// errors.
- (RACSignal *)download:(SQRLDownloadManager *)downloadManager __attribute__((nonnull (1)));

@end
