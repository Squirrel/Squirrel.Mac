//
//  SQRLDownloadController.h
//  Squirrel
//
//  Created by Keith Duncan on 26/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

// Stores metadata for download resumption, and manages the disk locations for
// where they're stored.
@interface SQRLDownloadController : NSObject

// Clean the resumable download state, removes downloaded data and tracking
// state.
+ (void)removeAllResumableDownloads;

// `NSString`, ETag of the latest response, subsequent responses should match
// this if they intend to append to the local file, otherwise the local file
// should be truncated.
//
// Absent from the download dictionary if there's no local download for the URL
// yet.
extern NSString * const SQRLDownloadETagKey;

// `NSURL`, location of local cache file.
//
// Present in new downloads, but no file will exist at the location yet.
extern NSString * const SQRLDownloadLocalFileKey;

// Retrieve a previously started download, or initialise a new download, callers
// don't need to know whether a download has been previously started or not.
+ (NSDictionary *)downloadForURL:(NSURL *)URL;

// Store metadata for a download so that it can be resumed later.
//
// Required keys
//  - SQRLDownloadETagKey
//  - SQRLDownloadLocalFileKey
//
// Downloads without an ETag header cannot be resumed and should not be written
// to the download store.
+ (void)setDownload:(NSDictionary *)download forURL:(NSURL *)URL;

@end
