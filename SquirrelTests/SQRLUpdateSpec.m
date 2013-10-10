//
//  SQRLUpdateSpec.m
//  Squirrel
//
//  Created by Keith Duncan on 18/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

SpecBegin(SQRLUpdate);

it(@"should return nil when initialised without a url", ^{
	NSError *error = nil;
	SQRLUpdate *update = [[SQRLUpdate alloc] initWithDictionary:@{} error:&error];
	expect(update).to.beNil();
	expect(error.domain).to.equal(NSCocoaErrorDomain);
	expect(error.code).to.equal(NSKeyValueValidationError);
});

it(@"should return nil when initialised with a url not in URL syntax", ^{
	NSError *error = nil;
	SQRLUpdate *update = [[SQRLUpdate alloc] initWithDictionary:@{ @"updateURL": @"test" } error:&error];
	expect(update).to.beNil();
	expect(error.domain).to.equal(NSCocoaErrorDomain);
	expect(error.code).to.equal(NSKeyValueValidationError);
});

it(@"should parse Central style dates", ^{
	SQRLUpdate *update = [MTLJSONAdapter modelOfClass:SQRLUpdate.class fromJSONDictionary:@{ @"url": @"http://example.com/update", @"pub_date": @"Tue Sep 17 10:24:27 -0700 2013" } error:NULL];
	expect(update.releaseDate).notTo.beNil();
});

it(@"should parse ISO 8601 dates", ^{
	SQRLUpdate *update = [MTLJSONAdapter modelOfClass:SQRLUpdate.class fromJSONDictionary:@{ @"url": @"http://example.com/update", @"pub_date": @"2013-09-18T13:17:07+01:00" } error:NULL];
	expect(update.releaseDate).notTo.beNil();
});

SpecEnd
