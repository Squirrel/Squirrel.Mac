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

- (instancetype)initWithJSON:(NSDictionary *)JSON {
	NSParameterAssert(JSON != nil);

	self = [self init];
	if (self == nil) return nil;

	_JSON = [JSON copy];

	NSString *urlString = JSON[SQRLUpdateJSONURLKey];
	if (urlString == nil || ![urlString isKindOfClass:NSString.class]) {
		NSLog(@"Ignoring update URL of an unsupported type: %@", urlString);
		return nil;
	} else {
		_updateURL = [NSURL URLWithString:urlString];

		if (_updateURL.scheme == nil || _updateURL.host == nil || _updateURL.path == nil) {
			NSLog(@"Ignoring update URL of an unsupported syntax: %@", urlString);
			return nil;
		}
	}

	NSString *name = JSON[SQRLUpdateJSONNameKey];
	if (![name isKindOfClass:NSString.class]) {
		NSLog(@"Ignoring release name of an unsupported type: %@", name);
	} else {
		_releaseName = [name copy];
	}

	NSString *releaseDateString = JSON[SQRLUpdateJSONPublicationDateKey];
	if (![releaseDateString isKindOfClass:NSString.class]) {
		NSLog(@"Ignoring release date with an unsupported type: %@", releaseDateString);
	} else {
		_releaseDate = [[SQRLUpdate dateFromString:releaseDateString] copy];

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

+ (NSDate *)dateFromString:(NSString *)string {
	NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
	formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];

	NSArray *dateFormats = @[
		@"yyyy'-'MM'-'DD'T'HH':'mm':'ssZZZZZ", // ISO 8601 Time Zone with ':'
		@"EEE MMM dd HH:mm:ss Z yyyy", // Central backwards compatibility
	];

	for (NSString *currentDateFormat in dateFormats) {
		formatter.dateFormat = currentDateFormat;
		NSDate *date = [formatter dateFromString:string];
		if (date != nil) return date;
	}

	// If neither match, try removing the ':' in the time zone
	static NSRegularExpression *timeZoneSuffix = nil;
	static dispatch_once_t timeZoneSuffixPredicate = 0;
	dispatch_once(&timeZoneSuffixPredicate, ^ {
		timeZoneSuffix = [NSRegularExpression regularExpressionWithPattern:@"([-+])([0-9]{2}):([0-9]{2})$" options:0 error:NULL];
	});

	string = [timeZoneSuffix stringByReplacingMatchesInString:string options:0 range:NSMakeRange(0, string.length) withTemplate:@"$1$2$3"];

	formatter.dateFormat = @"yyyy'-'MM'-'DD'T'HH':'mm':'ssZZZ"; // RFC 822 Time Zone no ':', 10.7 support
	return [formatter dateFromString:string];
}

@end
