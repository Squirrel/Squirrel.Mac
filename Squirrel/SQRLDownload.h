//
//  SQRLDownload.h
//  Squirrel
//
//  Created by Keith Duncan on 21/11/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Mantle/Mantle.h>

@class RACSignal;

// A download is a file which holds the response body for a request and can be
// resumed by a subsequent request if the initial transfer is interrupted.
//
// Don't create a download directly, instead retrieve one from
// `SQRLDownloadManager`.
@interface SQRLDownload : MTLModel

// The `request` the receiver was initialised with.
@property (readonly, copy, nonatomic) NSURLRequest *request;

// The `fileURL` the receiver was initialised with.
@property (readonly, copy, nonatomic) NSURL *fileURL;

// Calculate a request suitable for resuming the download.
//
// Returns a signal which sends an `NSURLRequest` then completes.
@property (readonly, nonatomic) RACSignal *resumableRequest;

@end
