//
//  SQRLDownloadedUpdate.h
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-09-25.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLUpdate.h"

// A SQRLUpdate that has been successfully downloaded to disk.
@interface SQRLDownloadedUpdate : SQRLUpdate

// The application bundle representing the downloaded and unarchived update.
@property (nonatomic, strong, readonly) NSBundle *bundle;

// Initializes the receiver with update metadata and the downloaded and
// unarchived bundle.
//
// update - The update information sent by the server. This must not be nil.
// bundle - The application bundle representing the update. This must not be nil.
- (id)initWithUpdate:(SQRLUpdate *)update bundle:(NSBundle *)bundle;

@end
