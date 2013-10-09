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

#pragma mark Lifecycle

- (id)initWithDictionary:(NSDictionary *)dictionary error:(NSError **)error {
	self = [super initWithDictionary:dictionary error:error];
	if (self == nil) return nil;

	if (self.updateURL == nil) {
		NSLog(@"Missing updateURL for %@", self);
		return nil;
	}

	return self;
}

#pragma mark MTLJSONSerializing

+ (NSDictionary *)JSONKeyPathsByPropertyKey {
	return @{
		@"releaseNotes": @"notes",
		@"releaseName": @"name",
		@"releaseDate": @"pub_date",

		// Declared in SQRLUpdate+Private.h
		@"updateURL": @"url",
	};
}

+ (NSValueTransformer *)updateURLJSONTransformer {
	return [NSValueTransformer valueTransformerForName:MTLURLValueTransformerName];
}

+ (NSValueTransformer *)releaseDateJSONTransformer {
	// ISO 8601 Time Zone with ':'
	NSString * const ISO8601DateFormat = @"yyyy'-'MM'-'DD'T'HH':'mm':'ssZZZZZ";

	return [MTLValueTransformer reversibleTransformerWithForwardBlock:^ NSDate * (NSString *dateString) {
		if (![dateString isKindOfClass:NSString.class]) return nil;

		NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
		formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];

		NSArray *dateFormats = @[
			ISO8601DateFormat,
			@"EEE MMM dd HH:mm:ss Z yyyy", // Central backwards compatibility
		];

		for (NSString *currentDateFormat in dateFormats) {
			formatter.dateFormat = currentDateFormat;
			NSDate *date = [formatter dateFromString:dateString];
			if (date != nil) return date;
		}

		// If neither match, try removing the ':' in the time zone
		static NSRegularExpression *timeZoneSuffix = nil;
		static dispatch_once_t timeZoneSuffixPredicate = 0;
		dispatch_once(&timeZoneSuffixPredicate, ^ {
			timeZoneSuffix = [NSRegularExpression regularExpressionWithPattern:@"([-+])([0-9]{2}):([0-9]{2})$" options:0 error:NULL];
		});

		dateString = [timeZoneSuffix stringByReplacingMatchesInString:dateString options:0 range:NSMakeRange(0, dateString.length) withTemplate:@"$1$2$3"];

		formatter.dateFormat = @"yyyy'-'MM'-'DD'T'HH':'mm':'ssZZZ"; // RFC 822 Time Zone no ':', 10.7 support
		return [formatter dateFromString:dateString];
	} reverseBlock:^ NSString * (NSDate *date) {
		if (![date isKindOfClass:NSDate.class]) return nil;

		NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
		formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
		formatter.dateFormat = ISO8601DateFormat;
		return [formatter stringFromDate:date];
	}];
}

#pragma mark NSKeyValueCoding

- (BOOL)validateUpdateURL:(NSURL **)updateURLPtr error:(NSError **)error {
	NSURL *updateURL = *updateURLPtr;
	if (![updateURL isKindOfClass:NSURL.class]) return NO;

	if (updateURL.scheme == nil || updateURL.host == nil || updateURL.path == nil) {
		return NO;
	}

	return YES;
}

#pragma mark NSCopying

- (id)copyWithZone:(NSZone *)zone {
	return self;
}

@end
