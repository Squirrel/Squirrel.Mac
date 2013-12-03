//
//  SQRLResumableDownload.h
//  Squirrel
//
//  Created by Keith Duncan on 30/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "SQRLDownload.h"

// A download which has already been started and already has partial data.
@interface SQRLResumableDownload : SQRLDownload

// Designated initialiser.
//
// request  - See `SQRLDownload`.
// response - HTTP response whose body is being downloaded to `fileURL`.
//            Must not be nil.
// fileURL  - See `SQRLDownload`.
- (instancetype)initWithRequest:(NSURLRequest *)request response:(NSHTTPURLResponse *)response fileURL:(NSURL *)fileURL;

// The `response` the receiver was initialised with.
@property (readonly, copy, nonatomic) NSHTTPURLResponse *response;

@end
