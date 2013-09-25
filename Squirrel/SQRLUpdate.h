//
//  SQRLUpdate.h
//  Squirrel
//
//  Created by Keith Duncan on 18/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

// Update parsed from a response to the `SQRLUpdater.updateRequest`.
@interface SQRLUpdate : NSObject

// Initialises an update from an `updateRequest` response body.
//
// JSON - Must not be nil, schema defined in README.
- (instancetype)initWithJSON:(NSDictionary *)JSON __attribute__((nonnull (1)));

// Underlying JSON the update was initialised with.
// Custom properties that Squirrel doesn't parse can be retrieved from this.
@property (readonly, copy, nonatomic) NSDictionary *JSON;

#pragma mark Standard Squirrel properties

// Release notes for the update
@property (readonly, copy, nonatomic) NSString *releaseNotes;

// Release name for the update
@property (readonly, copy, nonatomic) NSString *releaseName;

// Release date for the update
@property (readonly, copy, nonatomic) NSDate *releaseDate;

@end
