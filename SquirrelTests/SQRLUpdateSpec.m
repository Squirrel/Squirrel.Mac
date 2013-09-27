//
//  SQRLUpdateSpec.m
//  Squirrel
//
//  Created by Keith Duncan on 18/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLUpdate+Private.h"

SpecBegin(SQRLUpdate);

it(@"should return nil when initialised without a url", ^{
	NSError *error = nil;
	SQRLUpdate *update = [SQRLUpdate updateWithJSON:@{} error:&error];
	expect(update).to.beNil();
	expect(error).notTo.beNil();
});

it(@"should return nil when initialised with a url not in URL syntax", ^{
	NSError *error = nil;
	SQRLUpdate *update = [SQRLUpdate updateWithJSON:@{ @"url": @"test" } error:&error];
	expect(update).to.beNil();
	expect(error).notTo.beNil();
});

it(@"should return the initialised JSON for custom properties", ^{
	NSError *error = nil;
	SQRLUpdate *update = [SQRLUpdate updateWithJSON:@{ @"url": @"http://example.com/update", @"lulz": @"http://icanhas.cheezburger.com/" } error:&error];
	expect(update.JSON[@"lulz"]).notTo.beNil();
	expect(error).to.beNil();
});

it(@"should parse Central style dates", ^{
	NSError *error = nil;
	SQRLUpdate *update = [SQRLUpdate updateWithJSON:@{ @"url": @"http://example.com/update", SQRLUpdateJSONPublicationDateKey: @"Tue Sep 17 10:24:27 -0700 2013" } error:&error];
	expect(update.releaseDate).notTo.beNil();
	expect(error).to.beNil();
});

it(@"should parse ISO 8601 dates", ^{
	NSError *error = nil;
	SQRLUpdate *update = [SQRLUpdate updateWithJSON:@{ @"url": @"http://example.com/update", SQRLUpdateJSONPublicationDateKey: @"2013-09-18T13:17:07+01:00" } error:&error];
	expect(update.releaseDate).notTo.beNil();
	expect(error).to.beNil();
});

SpecEnd
