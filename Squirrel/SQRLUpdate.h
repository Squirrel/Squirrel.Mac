//
//  SQRLUpdate.h
//  Squirrel
//
//  Created by Keith Duncan on 18/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <Mantle/Mantle.h>

// Update parsed from a response to the `SQRLUpdater.updateRequest`.
@interface SQRLUpdate : MTLModel <MTLJSONSerializing>

// The release notes for the update.
@property (readonly, copy, nonatomic) NSString *releaseNotes;

// The release name for the update.
@property (readonly, copy, nonatomic) NSString *releaseName;

// The release date for the update.
@property (readonly, copy, nonatomic) NSDate *releaseDate;

@end
