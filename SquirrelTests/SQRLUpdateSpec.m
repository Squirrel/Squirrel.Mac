//
//  SQRLUpdateSpec.m
//  Squirrel
//
//  Created by Keith Duncan on 18/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLUpdate.h"
#import "SQRLUpdate+Private.h"

SpecBegin(SQRLUpdate);

it(@"should return the initialised JSON for custom properties", ^{
	SQRLUpdate *update = [[SQRLUpdate alloc] initWithJSON:@{ @"lulz": @"http://icanhas.cheezburger.com/" }];
	expect(update.json[@"lulz"]).notTo.beNil();
});

it(@"should parse Central style dates", ^{
	SQRLUpdate *update = [[SQRLUpdate alloc] initWithJSON:@{ SQRLUpdateJSONPublicationDateKey: @"Tue Sep 17 10:24:27 -0700 2013" }];
	expect(update.releaseDate).notTo.beNil();
});

it(@"should parse ISO 8601 dates", ^{
	SQRLUpdate *update = [[SQRLUpdate alloc] initWithJSON:@{ SQRLUpdateJSONPublicationDateKey: @"2013-09-18T13:17:07+01:00" }];
	expect(update.releaseDate).notTo.beNil();
});

SpecEnd
