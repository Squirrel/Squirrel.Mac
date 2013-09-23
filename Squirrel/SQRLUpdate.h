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
// JSON	- Must not be nil, expected to conform to the schema defined below.
//		@"url"		- A string, required, in URL syntax for the update that should
//					  be installed for this update.
//		@"notes"	- A string, optional, the release notes for the update, your
//					  application may choose to display these to the user.
//		@"name"		- A string, optional, the name of the update,could be a
//					  version number or something more whimsical.
//		@"pub_date" - A string, optional, in ISO 8601 syntax with the components
//					  yyyy'-'MM'-'DD'T'HH':'mm':'ssZZZZZ when the release became
//					  available.
- (id)initWithJSON:(id)JSON;

// Underlying JSON the update was initialised with.
// Custom properties that Squirrel doesn't parse can be retrieved from this.
@property (readonly, copy, nonatomic) id json;

#pragma mark Standard Squirrel properties

// Optional, from the "notes" key in `JSON`
@property (readonly, copy, nonatomic) NSString *releaseNotes;

// Optional, from the "name" key in `JSON`
@property (readonly, copy, nonatomic) NSString *releaseName;

// Optional, from the "pub_date" key in `JSON`
@property (readonly, copy, nonatomic) NSDate *releaseDate;

@end
