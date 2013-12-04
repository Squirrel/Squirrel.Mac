//
//  SQRLDownloadedUpdateSpec.m
//  Squirrel
//
//  Created by Keith Duncan on 04/12/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

SpecBegin(SQRLDownloadedUpdate)

it(@"should serialise to JSON", ^{
	NSError *error = nil;
	SQRLUpdate *update = [SQRLUpdate modelWithDictionary:@{
		@keypath(SQRLUpdate.new, updateURL) : [NSURL URLWithString:@"http://fake.domain/path"],
	} error:&error];
	expect(update).notTo.beNil();

	NSURL *testApplicationURL = [self createTestApplicationUpdate];
	NSBundle *testApplicationBundle = [NSBundle bundleWithURL:testApplicationURL];
	expect(testApplicationBundle).notTo.beNil();

	SQRLDownloadedUpdate *downloadedUpdate = [[SQRLDownloadedUpdate alloc] initWithUpdate:update bundle:testApplicationBundle];
	expect(downloadedUpdate).notTo.beNil();

	NSDictionary *JSONDictionary = [MTLJSONAdapter JSONDictionaryFromModel:downloadedUpdate];
	expect(JSONDictionary).notTo.beNil();

	NSData *JSONData = [NSJSONSerialization dataWithJSONObject:JSONDictionary options:0 error:&error];
	expect(JSONData).notTo.beNil();
	expect(error).to.beNil();

	JSONDictionary = [NSJSONSerialization JSONObjectWithData:JSONData options:0 error:&error];
	expect(JSONDictionary).notTo.beNil();

	SQRLDownloadedUpdate *downloadedUpdate2 = [MTLJSONAdapter modelOfClass:SQRLDownloadedUpdate.class fromJSONDictionary:JSONDictionary error:&error];
	expect(downloadedUpdate2).to.equal(downloadedUpdate);
	expect(error).to.beNil();
});

SpecEnd
