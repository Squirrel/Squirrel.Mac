//
//  NSData+SQRLExtensions.m
//  Squirrel
//
//  Created by Keith Duncan on 21/01/2014.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import "NSData+SQRLExtensions.h"

#import <CommonCrypto/CommonCrypto.h>

@implementation NSData (SQRLExtensions)

- (NSData *)sqrl_SHA1Hash {
	unsigned char hash[CC_SHA1_DIGEST_LENGTH];
	CC_SHA1(self.bytes, (CC_LONG)self.length, hash);
	return [NSData dataWithBytes:hash length:sizeof(hash) / sizeof(*hash)];
}

- (NSString *)sqrl_base16String {
	NSMutableString *base16 = [NSMutableString stringWithCapacity:self.length * 2];
	uint8_t *bytes = (uint8_t *)self.bytes;
	for (NSUInteger idx = 0; idx < self.length; idx++) {
		uint8_t byte = *(bytes + idx);
		[base16 appendFormat:@"%02hhx", byte];
	}
	return base16;
}

@end
