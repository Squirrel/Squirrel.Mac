//
//  SQRLUpdate+Private.h
//  Squirrel
//
//  Created by Keith Duncan on 18/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Squirrel/SQRLUpdate.h>

extern NSString * const SQRLUpdateJSONURLKey;
extern NSString * const SQRLUpdateJSONReleaseNotesKey;
extern NSString * const SQRLUpdateJSONNameKey;
extern NSString * const SQRLUpdateJSONPublicationDateKey;

@interface SQRLUpdate (Private)

// Location of the update package to download for installation
@property (readonly, copy, nonatomic) NSURL *updateURL;

@end

@interface SQRLUpdate ()

// Location of the downloaded update package ready for installation, file://
// scheme URL
@property (copy, nonatomic) NSURL *downloadedUpdateURL;

@end
