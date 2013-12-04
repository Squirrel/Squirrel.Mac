//
//  NSHTTPURLResponse+SQRLExtensions.m
//  Squirrel
//
//  Created by Keith Duncan on 04/12/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "NSHTTPURLResponse+SQRLExtensions.h"

#import <ReactiveCocoa/ReactiveCocoa.h>

@implementation NSHTTPURLResponse (SQRLExtensions)

- (NSString *)sqrl_valueForHTTPHeaderField:(NSString *)field {
	return [[[self.allHeaderFields.rac_signal
		filter:^ BOOL (RACTuple *keyValuePair) {
			return [keyValuePair.first caseInsensitiveCompare:field] == NSOrderedSame;
		}]
		reduceEach:^(NSString *key, NSString *value) {
			return value;
		}]
		first];
}

@end
