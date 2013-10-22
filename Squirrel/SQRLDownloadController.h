//
//  SQRLDownloadController.h
//  Squirrel
//
//  Created by Keith Duncan on 26/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

@class SQRLResumableDownload;
@class RACSignal;

// Stores metadata for download resumption, and manages the disk locations for
// where they're stored.
@interface SQRLDownloadController : NSObject

// Default download controller, stores downloads in the ~/Library/Caches
// directory.
+ (instancetype)defaultDownloadController;

// Clean the resumable download state, removes downloaded data and tracking
// state.
//
// Returns a signal which sends RACUnit.defaultUnit then completes, or errors.
- (RACSignal *)removeAllResumableDownloads:(NSError **)errorRef;

// Retrieve a previously started download, or initialise a new download, callers
// don't need to know whether a download has been previously started or not.
//
// When a previous download cannot be found, a new download is returned. Callers
// should write downloaded data to the fileURL. If a new download cannot be
// started, the error parameter (if non `NULL`) will be populated.
//
// request  - Must not be nil, pass the request whose response body will be
//            saved to disk.
// errorRef - May be `NULL`, populated if there is an error preparing a new
//            resumable download.
- (SQRLResumableDownload *)downloadForRequest:(NSURLRequest *)request error:(NSError **)errorRef;

// Store metadata for a download so that it can be resumed later.
//
// download - Must have a response, this is asserted.
// request  - Must not be nil.
- (void)setDownload:(SQRLResumableDownload *)download forRequest:(NSURLRequest *)request;

@end
