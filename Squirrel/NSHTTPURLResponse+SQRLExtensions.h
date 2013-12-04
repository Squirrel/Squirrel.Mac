//
//  NSHTTPURLResponse+SQRLExtensions.h
//  Squirrel
//
//  Created by Keith Duncan on 04/12/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface NSHTTPURLResponse (SQRLExtensions)

// Case insensitively look up a header field value.
//
// Returns the value of the header if present or nil otherwise.
- (NSString *)sqrl_valueForHTTPHeaderField:(NSString *)field;

@end
