//
//  SQRLUpdate.m
//  Squirrel
//
//  Created by Keith Duncan on 18/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLUpdate.h"
#import "SQRLUpdate+Private.h"

NSString * const SQRLUpdateJSONURLKey = @"url";
NSString * const SQRLUpdateJSONReleaseNotesKey = @"notes";
NSString * const SQRLUpdateJSONNameKey = @"name";
NSString * const SQRLUpdateJSONPublicationDateKey = @"pub_date";

@implementation SQRLUpdate

- (id)initWithJSON:(id)JSON {
	self = [self init];
	if (self == nil) return nil;

	_json = [JSON copy];

	NSString *urlString = JSON[SQRLUpdateJSONURLKey];
	if (![urlString isKindOfClass:NSString.class]) {
		NSLog(@"Ignoring update URL of an unsupported type: %@", urlString);
	} else {
		_updateURL = [NSURL URLWithString:urlString];
	}

	NSString *name = JSON[SQRLUpdateJSONNameKey];
	if (![name isKindOfClass:NSString.class]) {
		NSLog(@"Ignoring release name of an unsupported type: %@", name);
	}
	else {
		_releaseName = [name copy];
	}

	NSString *releaseDateString = JSON[SQRLUpdateJSONPublicationDateKey];
	if (![releaseDateString isKindOfClass:NSString.class]) {
		NSLog(@"Ignoring release date with an unsupported type: %@", releaseDateString);
	} else {
		NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
		formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];

		NSArray *dateFormats = @[
			@"yyyy'-'MM'-'DD'T'HH':'mm':'ssZZZZ",
			@"EEE MMM dd HH:mm:ss Z yyyy", // Central backwards compatibility
		];

		for (NSString *currentDateFormat in dateFormats) {
			formatter.dateFormat = currentDateFormat;
			_releaseDate = [[formatter dateFromString:releaseDateString] copy];
			if (_releaseDate != nil) break;
		}
		if (_releaseDate == nil) {
			NSLog(@"Could not parse publication date for update. %@", releaseDateString);
		}
	}

	NSString *releaseNotes = JSON[SQRLUpdateJSONReleaseNotesKey];
	if (![releaseNotes isKindOfClass:NSString.class]) {
		NSLog(@"Ignoring release notes of an unsupported type: %@", releaseNotes);
	} else {
		_releaseNotes = [releaseNotes copy];
	}

	return self;
}

@end
