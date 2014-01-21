//
//  SQRLDownload+Private.h
//  Squirrel
//
//  Created by Keith Duncan on 21/01/2014.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import "SQRLDownload.h"

@interface SQRLDownload ()

// Designated initialiser.
//
// request - Must not be nil. The request this download is for.
// fileURL - Must not be nil. The file location to save received data to.
//
// Returns an initialised download suitable for saving response data.
- (instancetype)initWithRequest:(NSURLRequest *)request fileURL:(NSURL *)fileURL;

@end
