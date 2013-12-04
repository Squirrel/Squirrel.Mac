//
//  SQRLDownloadController.h
//  Squirrel
//
//  Created by Keith Duncan on 26/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

@class SQRLDownload;
@class SQRLResumableDownload;
@class RACSignal;
@class SQRLDirectoryManager;

// Stores metadata for download resumption, and manages the disk locations for
// where they're stored.
@interface SQRLDownloadManager : NSObject

// Default download manager, initializes a download manager with the current
// application directory manager. Stores downloads in
// `directoryManager.downloadDirectoryURL`.
+ (instancetype)defaultDownloadManager;

// Designated initialiser.
//
// directoryManager - Must not be nil.
//
// Returns a download manager which can resume previously started downloads for
// the initialised directory manager's application.
- (instancetype)initWithDirectoryManager:(SQRLDirectoryManager *)directoryManager;

// Clean the resumable download state, removes downloaded data and tracking
// state.
//
// Returns a signal which errors or completes when all file operations have been
// attempted.
- (RACSignal *)removeAllResumableDownloads;

// Retrieve a previously started download, or initialise a new download.
//
// Previously started downloads may have been removed and require
// reinitialising.
//
// request - Must not be nil, pass the request you are performing and require a
//           disk location to save the response body to.
//
// Returns a signal which sends an `SQRLDownload` object then completes, or
// errors.
- (RACSignal *)downloadForRequest:(NSURLRequest *)request;

// Store metadata for a download so that it can be resumed later.
//
// download - The download being stored for future resumption, must not be nil.
// request  - The request for which the download can be resumed.
//
// Returns a signal which completes or errors.
- (RACSignal *)setDownload:(SQRLResumableDownload *)download forRequest:(NSURLRequest *)request;

@end
