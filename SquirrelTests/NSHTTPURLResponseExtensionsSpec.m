//
//  NSHTTPURLResponseExtensionsSpec.m
//  Squirrel
//
//  Created by Keith Duncan on 04/12/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "NSHTTPURLResponse+SQRLExtensions.h"

SpecBegin(NSHTTPURLResponseExtensions)

it(@"should perform case insensitive key look up", ^{
	NSDictionary *headers = @{
		@"ETag": @"foo",
	};
	NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"http://localhost"] statusCode:200 HTTPVersion:(__bridge NSString *)kCFHTTPVersion1_1 headerFields:headers];

	expect([response sqrl_valueForHTTPHeaderField:@"etag"]).to.equal(@"foo");
	expect([response sqrl_valueForHTTPHeaderField:@"ETAG"]).to.equal(@"foo");
});

SpecEnd
