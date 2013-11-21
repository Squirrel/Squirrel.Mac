//
//  SQRLDownload.h
//  Squirrel
//
//  Created by Keith Duncan on 21/11/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Mantle/Mantle.h>

@class RACSignal;

@interface SQRLDownload : MTLModel

// Designated initialiser.
//
// request - Must not be nil. The request this download is for.
// fileURL - Must not be nil. The file location to save received data to.
//
// Returns an initialised download suitable for saving response data.
- (instancetype)initWithRequest:(NSURLRequest *)request fileURL:(NSURL *)fileURL;

// The `request` the receiver was initialised with.
@property (readonly, copy, nonatomic) NSURLRequest *request;

// The `fileURL` the receiver was initialised with.
@property (readonly, copy, nonatomic) NSURL *fileURL;

// Calculate a request suitable for resuming the download.
//
// Returns a signal which sends an `NSURLRequest` then completes.
@property (readonly, nonatomic) RACSignal *resumableRequest;

@end
