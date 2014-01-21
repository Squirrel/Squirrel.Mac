//
//  NSData+SQRLExtensions.h
//  Squirrel
//
//  Created by Keith Duncan on 21/01/2014.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface NSData (SQRLExtensions)

// Returns an NSData for the SHA1 hash of the receiver.
- (NSData *)sqrl_SHA1Hash;

// Returns the base16 encoding of the receiver.
- (NSString *)sqrl_base16String;

@end
