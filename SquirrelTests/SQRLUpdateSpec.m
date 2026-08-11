//
//  SQRLUpdateSpec.m
//  Squirrel
//
//  Created by Keith Duncan on 18/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Nimble/Nimble.h>
#import <Quick/Quick.h>
#import <ReactiveObjC/ReactiveObjC.h>
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

it(@"should parse the package digest and size, ignoring values it cannot use", ^{
	NSString *digest = @"E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855";
	SQRLUpdate *update = [MTLJSONAdapter modelOfClass:SQRLUpdate.class fromJSONDictionary:@{ @"url": @"http://example.com/update", @"sha256": digest, @"size": @1234 } error:NULL];
	expect(update.packageDigest).to(equal(digest.lowercaseString));
	expect(update.packageSize).to(equal(@1234));

	for (NSDictionary *odd in @[ @{}, @{ @"sha256": @"abcdef", @"size": @0 }, @{ @"sha256": @42, @"size": @"big" }, @{ @"sha256": [@"sha256:" stringByAppendingString:digest], @"size": @-1 } ]) {
		NSMutableDictionary *JSON = [odd mutableCopy];
		JSON[@"url"] = @"http://example.com/update";

		update = [MTLJSONAdapter modelOfClass:SQRLUpdate.class fromJSONDictionary:JSON error:NULL];
		expect(update).notTo(beNil());
		expect(update.packageDigest).to(beNil());
		expect(update.packageSize).to(beNil());
	}
});

it(@"should parse Central style dates", ^{
	SQRLUpdate *update = [MTLJSONAdapter modelOfClass:SQRLUpdate.class fromJSONDictionary:@{ @"url": @"http://example.com/update", @"pub_date": @"Tue Sep 17 10:24:27 -0700 2013" } error:NULL];
	expect(update.releaseDate).to(equal([NSDate dateWithTimeIntervalSince1970:1379438667]));
});

it(@"should parse ISO 8601 dates", ^{
	SQRLUpdate *update = [MTLJSONAdapter modelOfClass:SQRLUpdate.class fromJSONDictionary:@{ @"url": @"http://example.com/update", @"pub_date": @"2013-09-18T13:17:07+01:00" } error:NULL];
	expect(update.releaseDate).to(equal([NSDate dateWithTimeIntervalSince1970:1379506627]));
});

it(@"should parse ISO 8601 dates with a colon-free time zone offset", ^{
	SQRLUpdate *update = [MTLJSONAdapter modelOfClass:SQRLUpdate.class fromJSONDictionary:@{ @"url": @"http://example.com/update", @"pub_date": @"2013-09-18T13:17:07-0700" } error:NULL];
	expect(update.releaseDate).to(equal([NSDate dateWithTimeIntervalSince1970:1379535427]));
});

it(@"should parse ISO 8601 dates with a Z time zone designator", ^{
	SQRLUpdate *update = [MTLJSONAdapter modelOfClass:SQRLUpdate.class fromJSONDictionary:@{ @"url": @"http://example.com/update", @"pub_date": @"2013-09-18T12:17:07Z" } error:NULL];
	expect(update.releaseDate).to(equal([NSDate dateWithTimeIntervalSince1970:1379506627]));
});

QuickSpecEnd
