//
//  SQRLUpdate.m
//  Squirrel
//
//  Created by Keith Duncan on 18/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLUpdate.h"
#import "SQRLUpdateDelta.h"
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
		@keypath(SQRLUpdate.new, packageDigest): @"sha256",
		@keypath(SQRLUpdate.new, packageSize): @"size",
		@keypath(SQRLUpdate.new, delta): @"delta",
	};
}

+ (NSValueTransformer *)updateURLJSONTransformer {
	return [NSValueTransformer valueTransformerForName:MTLURLValueTransformerName];
}

// `sha256` and `size` are advisory: a value of the wrong type or shape is
// logged and dropped rather than failing the update, so a feed that emits
// them oddly for some other consumer keeps updating (unverified, as before).
+ (NSValueTransformer *)packageDigestJSONTransformer {
	return [MTLValueTransformer transformerUsingForwardBlock:^ id (id digest, BOOL *success, NSError **error) {
		NSRegularExpression *hex64 = [NSRegularExpression regularExpressionWithPattern:@"\\A[0-9a-f]{64}\\z" options:NSRegularExpressionCaseInsensitive error:NULL];
		if ([digest isKindOfClass:NSString.class] && [hex64 numberOfMatchesInString:digest options:0 range:NSMakeRange(0, [digest length])] == 1) return [digest lowercaseString];

		NSLog(@"Ignoring update \"sha256\" that is not 64 hex digits: %@", digest);
		return nil;
	}];
}

+ (NSValueTransformer *)packageSizeJSONTransformer {
	return [MTLValueTransformer transformerUsingForwardBlock:^ id (id size, BOOL *success, NSError **error) {
		if ([size isKindOfClass:NSNumber.class] && [size longLongValue] > 0) return size;

		NSLog(@"Ignoring update \"size\" that is not a positive number: %@", size);
		return nil;
	}];
}

// A `delta` that does not parse is logged and dropped: offering one must
// never cost the update it rides on.
+ (NSValueTransformer *)deltaJSONTransformer {
	return [MTLValueTransformer transformerUsingForwardBlock:^ id (id JSON, BOOL *success, NSError **error) {
		NSError *deltaError = nil;
		SQRLUpdateDelta *delta = [JSON isKindOfClass:NSDictionary.class] ? [MTLJSONAdapter modelOfClass:SQRLUpdateDelta.class fromJSONDictionary:JSON error:&deltaError] : nil;
		if (delta == nil) NSLog(@"Ignoring update \"delta\" that cannot be used: %@ (%@)", JSON, deltaError.localizedRecoverySuggestion ?: deltaError);
		return delta;
	} reverseBlock:^ id (SQRLUpdateDelta *delta, BOOL *success, NSError **error) {
		return delta == nil ? nil : [MTLJSONAdapter JSONDictionaryFromModel:delta error:error];
	}];
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
