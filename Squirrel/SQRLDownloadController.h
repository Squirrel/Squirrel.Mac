//
//  SQRLDownloadController.h
//  Squirrel
//
//  Created by Keith Duncan on 26/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

@class SQRLResumableDownload;

// Stores metadata for download resumption, and manages the disk locations for
// where they're stored.
@interface SQRLDownloadController : NSObject

// Default download controller, stores downloads in the ~/Library/Caches
// directory
+ (instancetype)defaultDownloadController;

// Clean the resumable download state, removes downloaded data and tracking
// state.
- (void)removeAllResumableDownloads;

// Retrieve a previously started download, or initialise a new download, callers
// don't need to know whether a download has been previously started or not.
- (SQRLResumableDownload *)downloadForURL:(NSURL *)URL;

// Store metadata for a download so that it can be resumed later.
- (void)setDownload:(SQRLResumableDownload *)download forURL:(NSURL *)URL;

@end
