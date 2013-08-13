//
//  NSError+SQRLVerbosityExtensions.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-05.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "NSError+SQRLVerbosityExtensions.h"

@implementation NSError (SQRLVerbosityExtensions)

- (NSString *)sqrl_verboseDescription {
	NSMutableDictionary *userInfo = [self.userInfo mutableCopy];
	NSMutableString *description = [NSMutableString stringWithFormat:@"%@ { domain: %@, code: %li", self.class, self.domain, (long)self.code];

	if (self.localizedDescription != nil) {
		[description appendFormat:@", description: \"%@\"", self.localizedDescription];
		[userInfo removeObjectForKey:NSLocalizedDescriptionKey];
	}

	if (self.localizedRecoverySuggestion != nil) {
		[description appendFormat:@", recoverySuggestion: \"%@\"", self.localizedRecoverySuggestion];
		[userInfo removeObjectForKey:NSLocalizedRecoverySuggestionErrorKey];
	}

	if (self.localizedFailureReason != nil && [self.localizedDescription rangeOfString:self.localizedFailureReason].location == NSNotFound) {
		[description appendFormat:@", failureReason: \"%@\"", self.localizedFailureReason];
		[userInfo removeObjectForKey:NSLocalizedFailureReasonErrorKey];
	}

	NSError *underlyingError = userInfo[NSUnderlyingErrorKey];
	if (underlyingError != nil) {
		[description appendFormat:@", underlying error: %@", underlyingError.sqrl_verboseDescription];
		[userInfo removeObjectForKey:NSUnderlyingErrorKey];
	}

	if (userInfo.count > 0) [description appendFormat:@", userInfo: %@", userInfo];
	[description appendString:@" }"];

	return description;
}

@end
