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

NSString * const SQRLUpdateErrorDomain = @"SQRLUpdateErrorDomain";

@interface SQRLUpdate ()
@property (readwrite, copy, nonatomic) NSDictionary *JSON;
@property (readwrite, copy, nonatomic) NSString *releaseNotes;
@property (readwrite, copy, nonatomic) NSString *releaseName;
@property (readwrite, copy, nonatomic) NSDate *releaseDate;

@property (readwrite, copy, nonatomic) NSURL *updateURL;
@end

@implementation SQRLUpdate

+ (NSError *)invalidJSONErrorWithDescription:(NSString *)description {
	NSDictionary *errorInfo = @{
		NSLocalizedDescriptionKey: description,
	};
	return [NSError errorWithDomain:SQRLUpdateErrorDomain code:SQRLUpdateErrorInvalidJSON userInfo:errorInfo];
}

+ (instancetype)updateWithResponseProvider:(NSData * (^)(NSError **))responseProvider error:(NSError **)errorRef {
	NSParameterAssert(responseProvider != nil);

	NSData *bodyData = responseProvider(errorRef);
	if (bodyData == nil) return nil;

	NSDictionary *JSON = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:errorRef];
	if (JSON == nil) return nil;

	if (![JSON isKindOfClass:NSDictionary.class]) {
		if (errorRef != NULL) *errorRef = [self invalidJSONErrorWithDescription:NSLocalizedString(@"Root JSON object must be a Dictionary", nil)];
		return nil;
	}

	return [self updateWithJSON:JSON error:errorRef];
}

+ (instancetype)updateWithJSON:(NSDictionary *)JSON error:(NSError **)errorRef {
	SQRLUpdate *update = [[self alloc] init];

	update.JSON = JSON;

	NSString *urlString = JSON[SQRLUpdateJSONURLKey];
	if (urlString == nil || ![urlString isKindOfClass:NSString.class]) {
		if (errorRef != NULL) *errorRef = [self invalidJSONErrorWithDescription:NSLocalizedString(@"'url' must be present and of type String", nil)];
		return nil;
	} else {
		NSURL *updateURL = [NSURL URLWithString:urlString];

		if (updateURL.scheme == nil || updateURL.host == nil || updateURL.path == nil) {
			if (errorRef != NULL) *errorRef = [self invalidJSONErrorWithDescription:NSLocalizedString(@"'url' must be a URL", nil)];
			return nil;
		} else {
			update.updateURL = updateURL;
		}
	}

	NSString *name = JSON[SQRLUpdateJSONNameKey];
	if (![name isKindOfClass:NSString.class]) {
		NSLog(@"Ignoring release name of an unsupported type: %@", name);
	} else {
		update.releaseName = name;
	}

	NSString *releaseDateString = JSON[SQRLUpdateJSONPublicationDateKey];
	if (![releaseDateString isKindOfClass:NSString.class]) {
		NSLog(@"Ignoring release date with an unsupported type: %@", releaseDateString);
	} else {
		NSDate *releaseDate = [self dateFromString:releaseDateString];

		if (releaseDate == nil) {
			NSLog(@"Could not parse publication date for update. %@", releaseDateString);
		} else {
			update.releaseDate = releaseDate;
		}
	}

	NSString *releaseNotes = JSON[SQRLUpdateJSONReleaseNotesKey];
	if (![releaseNotes isKindOfClass:NSString.class]) {
		NSLog(@"Ignoring release notes of an unsupported type: %@", releaseNotes);
	} else {
		update.releaseNotes = releaseNotes;
	}

	return update;
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

- (NSString *)bundleVersion {
	NSDictionary *infoPlist = CFBridgingRelease(CFBundleCopyInfoDictionaryForURL((__bridge CFURLRef)self.downloadedUpdateURL));
	return infoPlist[(__bridge NSString *)kCFBundleVersionKey];
}

@end
