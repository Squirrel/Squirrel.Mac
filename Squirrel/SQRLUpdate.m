//
//  SQRLUpdate.m
//  Squirrel
//
//  Created by Keith Duncan on 18/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLUpdate.h"
#import <ReactiveObjC/ReactiveObjC.h>

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
		if (error != NULL) {
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: NSLocalizedString(@"Validation failed", nil),
				NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"SQRLUpdate must be initialized with a valid updateURL.", nil)
			};

			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSKeyValueValidationError userInfo:userInfo];
		}

		return nil;
	}

	return self;
}

#pragma mark Validation

- (BOOL)validateString:(NSString *)proposedString forKey:(NSString *)key error:(NSError **)error {
	if (![proposedString isKindOfClass:NSString.class]) {
		if (error != NULL) {
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: NSLocalizedString(@"Validation failed", nil),
				NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:NSLocalizedString(@"An invalid %@ was given to SQRLUpdate: %@", nil), key, proposedString]
			};

			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSKeyValueValidationError userInfo:userInfo];
		}
		
		return NO;
	}

	return YES;
}

#pragma mark MTLJSONSerializing

+ (NSDictionary *)JSONKeyPathsByPropertyKey {
	return @{
		@keypath(SQRLUpdate.new, releaseNotes): @"notes",
		@keypath(SQRLUpdate.new, releaseName): @"name",
		@keypath(SQRLUpdate.new, releaseDate): @"pub_date",
		@keypath(SQRLUpdate.new, updateURL): @"url",
	};
}

+ (NSValueTransformer *)updateURLJSONTransformer {
	return [NSValueTransformer valueTransformerForName:MTLURLValueTransformerName];
}

+ (NSValueTransformer *)releaseDateJSONTransformer {
	// ISO 8601 Time Zone with ':'
	NSString * const ISO8601DateFormat = @"yyyy'-'MM'-'dd'T'HH':'mm':'ssZZZZZ";

	return [MTLValueTransformer transformerUsingForwardBlock:^ NSDate * (NSString *dateString, BOOL *success, NSError **error) {
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

		return nil;
	} reverseBlock:^ NSString * (NSDate *date, BOOL *success, NSError **error) {
		if (![date isKindOfClass:NSDate.class]) return nil;

		NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
		formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
		formatter.dateFormat = ISO8601DateFormat;
		return [formatter stringFromDate:date];
	}];
}

#pragma mark NSKeyValueCoding

- (BOOL)validateReleaseName:(NSString **)stringPtr error:(NSError **)error {
	if (![self validateString:*stringPtr forKey:@keypath(self.releaseName) error:error]) {
		*stringPtr = nil;
	}

	return YES;
}

- (BOOL)validateReleaseNotes:(NSString **)stringPtr error:(NSError **)error {
	if (![self validateString:*stringPtr forKey:@keypath(self.releaseNotes) error:error]) {
		*stringPtr = nil;
	}

	return YES;
}

- (BOOL)validateUpdateURL:(NSURL **)updateURLPtr error:(NSError **)error {
	NSURL *updateURL = *updateURLPtr;
	if (![updateURL isKindOfClass:NSURL.class]) {
		if (error != NULL) {
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: NSLocalizedString(@"Validation failed", nil),
				NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:NSLocalizedString(@"An invalid updateURL was given to SQRLUpdate: %@", nil), updateURL]
			};
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSKeyValueValidationError userInfo:userInfo];
		}
		
		return NO;
	}

	BOOL valid = (updateURL.scheme != nil);
	valid &= ([updateURL.scheme isEqualToString:@"file"] || updateURL.host != nil);
	valid &= (updateURL.path != nil);
	if (!valid) {
		if (error != NULL) {
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: NSLocalizedString(@"Validation failed", nil),
				NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:NSLocalizedString(@"Update URLs must have a scheme, a host and a path: %@", nil), updateURL]
			};
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSKeyValueValidationError userInfo:userInfo];
		}

		return NO;
	}

	return YES;
}

#pragma mark NSCopying

- (id)copyWithZone:(NSZone *)zone {
	return self;
}

@end
