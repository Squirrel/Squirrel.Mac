//
//  SQRLUpdateSpec.m
//  Squirrel
//
//  Created by Keith Duncan on 18/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Nimble/Nimble.h>
#import <Quick/Quick.h>
#import <ReactiveCocoa/ReactiveCocoa.h>
#import <Squirrel/Squirrel.h>

QuickSpecBegin(SQRLUpdateSpec)

it(@"should return nil when initialised without a url", ^{
	NSError *error = nil;
	SQRLUpdate *update = [[SQRLUpdate alloc] initWithDictionary:@{} error:&error];
	expect(update).to(beNil());
	expect(error.domain).to(equal(NSCocoaErrorDomain));
	expect(@(error.code)).to(equal(@(NSKeyValueValidationError)));
});

it(@"should return nil when initialised with a url not in URL syntax", ^{
	NSError *error = nil;
	SQRLUpdate *update = [[SQRLUpdate alloc] initWithDictionary:@{ @"updateURL": [NSURL URLWithString:@"test"] } error:&error];
	expect(update).to(beNil());
	expect(error.domain).to(equal(NSCocoaErrorDomain));
	expect(@(error.code)).to(equal(@(NSKeyValueValidationError)));
});

it(@"should validate release name and notes", ^{
	NSURL *updateURL = [NSURL URLWithString:@"http://example.com/update"];
	SQRLUpdate *update = [[SQRLUpdate alloc] initWithDictionary:@{
		@"updateURL": updateURL,
		@"releaseName": @5,
		@"releaseNotes": [[NSObject alloc] init]
	} error:NULL];

	expect(update).notTo(beNil());
	expect(update.updateURL).to(equal(updateURL));
	expect(update.releaseName).to(beNil());
	expect(update.releaseNotes).to(beNil());
});

it(@"should parse Central style dates", ^{
	SQRLUpdate *update = [MTLJSONAdapter modelOfClass:SQRLUpdate.class fromJSONDictionary:@{ @"url": @"http://example.com/update", @"pub_date": @"Tue Sep 17 10:24:27 -0700 2013" } error:NULL];
	expect(update.releaseDate).to(equal([NSDate dateWithTimeIntervalSince1970:1379438667]));
});

it(@"should parse ISO 8601 dates", ^{
	SQRLUpdate *update = [MTLJSONAdapter modelOfClass:SQRLUpdate.class fromJSONDictionary:@{ @"url": @"http://example.com/update", @"pub_date": @"2013-09-18T13:17:07+01:00" } error:NULL];
	expect(update.releaseDate).to(equal([NSDate dateWithTimeIntervalSince1970:1379506627]));
});

QuickSpecEnd
