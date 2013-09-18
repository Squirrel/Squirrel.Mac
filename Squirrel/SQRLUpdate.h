//
//  SQRLUpdate.h
//  Squirrel
//
//  Created by Keith Duncan on 18/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface SQRLUpdate : NSObject

- (id)initWithJSON:(id)JSON;

/*
	Underlying json the update was initialised with
	Custom properties that Squirrel doesn't parse can be retrieved from this
 */
@property (readonly, copy, nonatomic) id json;

/*
	Standard Squirrel properties
 */

@property (readonly, copy, nonatomic) NSString *releaseNotes;
@property (readonly, copy, nonatomic) NSString *releaseName;
@property (readonly, copy, nonatomic) NSDate *releaseDate;

@end
