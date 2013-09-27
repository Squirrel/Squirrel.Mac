//
//  SQRLUpdate.h
//  Squirrel
//
//  Created by Keith Duncan on 18/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

// The domain for errors originating within SQRLUpdate.
extern NSString * const SQRLUpdateErrorDomain;

// SQRLUpdateErrorInvalidJSON - JSON didn't conform to expected schema
enum : NSInteger {
	SQRLUpdateErrorInvalidJSON = -1,
};

// Update parsed from a response to the `SQRLUpdater.updateRequest`.
@interface SQRLUpdate : NSObject

// Initialises an update from an `updateRequest` response body.
//
// Deserialises JSON from the response and invokes `+updateWithJSON:error:`.
//
// responseProvider - Must not be nil.
// errorRef         - May be NULL.
+ (instancetype)updateWithResponseProvider:(NSData * (^)(NSError **))responseProvider error:(NSError **)errorRef __attribute__((nonnull (1)));

// Initialises an update from already deserialised JSON.
//
// JSON     - Must not be nil, schema defined in README.
// errorRef - May be NULL.
+ (instancetype)updateWithJSON:(NSDictionary *)JSON error:(NSError **)errorRef __attribute__((nonnull (1)));

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

#pragma mark Local properties

// CFBundleVersion from the downloaded update's Info.plist
@property (readonly, nonatomic) NSString *bundleVersion;

@end
