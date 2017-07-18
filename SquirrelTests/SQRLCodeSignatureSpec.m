//
//  SQRLCodeSignatureSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-06.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Nimble/Nimble.h>
#import <Quick/Quick.h>
#import <ReactiveCocoa/ReactiveCocoa.h>
#import <Squirrel/Squirrel.h>

#import "SQRLCodeSignature.h"

#import "QuickSpec+SQRLFixtures.h"

QuickSpecBegin(SQRLCodeSignatureSpec)

__block NSBundle *bundle;
__block void (^corruptURL)(NSURL *URL);

beforeEach(^{
	bundle = self.testApplicationBundle;

	corruptURL = ^(NSURL *URL) {
		expect(@([@"this bundle is corrupted, yo" writeToURL:bundle.executableURL atomically:YES encoding:NSUTF8StringEncoding error:NULL])).to(beTruthy());
	};
});

it(@"should verify a valid bundle", ^{
	NSError *error = nil;
	BOOL success = [[self.testApplicationSignature verifyBundleAtURL:bundle.bundleURL] waitUntilCompleted:&error];
	expect(@(success)).to(beTruthy());
	expect(error).to(beNil());
});

it(@"should fail to verify with different code signing requirements", ^{
	NSError *error = nil;
	SQRLCodeSignature *signature = [SQRLCodeSignature currentApplicationSignature:&error];
	expect(signature).notTo(beNil());
	expect(error).to(beNil());

	BOOL success = [[signature verifyBundleAtURL:bundle.bundleURL] waitUntilCompleted:&error];
	expect(@(success)).to(beFalsy());
	expect(error).notTo(beNil());
});

describe(@"code signature changes", ^{
	__block NSURL *codeSignatureURL;

	beforeEach(^{
		codeSignatureURL = [bundle.bundleURL URLByAppendingPathComponent:@"Contents/_CodeSignature"];
	});

	it(@"should fail to verify a bundle with a missing code signature", ^{
		expect(@([NSFileManager.defaultManager removeItemAtURL:codeSignatureURL error:NULL])).to(beTruthy());

		NSError *error = nil;
		BOOL success = [[self.testApplicationSignature verifyBundleAtURL:bundle.bundleURL] waitUntilCompleted:&error];
		expect(@(success)).to(beFalsy());

		expect(error).notTo(beNil());
		expect(error.domain).to(equal(SQRLCodeSignatureErrorDomain));
		expect(@(error.code)).to(equal(@(SQRLCodeSignatureErrorDidNotPass)));
	});

	it(@"should fail to verify a bundle with a corrupt code signature", ^{
		corruptURL(codeSignatureURL);

		NSError *error = nil;
		BOOL success = [[self.testApplicationSignature verifyBundleAtURL:bundle.bundleURL] waitUntilCompleted:&error];
		expect(@(success)).to(beFalsy());

		expect(error).notTo(beNil());
		expect(error.domain).to(equal(SQRLCodeSignatureErrorDomain));
		expect(@(error.code)).to(equal(@(SQRLCodeSignatureErrorDidNotPass)));
	});
});

describe(@"main executable changes", ^{
	it(@"should fail to verify a bundle with a missing executable", ^{
		expect(@([NSFileManager.defaultManager removeItemAtURL:bundle.executableURL error:NULL])).to(beTruthy());

		NSError *error = nil;
		BOOL success = [[self.testApplicationSignature verifyBundleAtURL:bundle.bundleURL] waitUntilCompleted:&error];
		expect(@(success)).to(beFalsy());

		expect(error).notTo(beNil());
		expect(error.domain).to(equal(SQRLCodeSignatureErrorDomain));
		expect(@(error.code)).to(equal(@(SQRLCodeSignatureErrorDidNotPass)));
	});

	it(@"should fail to verify a bundle with a corrupt executable", ^{
		corruptURL(bundle.executableURL);

		NSError *error = nil;
		BOOL success = [[self.testApplicationSignature verifyBundleAtURL:bundle.bundleURL] waitUntilCompleted:&error];
		expect(@(success)).to(beFalsy());

		expect(error).notTo(beNil());
		expect(error.domain).to(equal(SQRLCodeSignatureErrorDomain));
		expect(@(error.code)).to(equal(@(SQRLCodeSignatureErrorDidNotPass)));
	});
});

describe(@"helper executable changes", ^{
	__block NSURL *helperURL;

	beforeEach(^{
		helperURL = [bundle URLForAuxiliaryExecutable:@"unused-helper"];
		expect(helperURL).notTo(beNil());
	});

	it(@"should fail to verify a bundle with a missing helper", ^{
		expect(@([NSFileManager.defaultManager removeItemAtURL:helperURL error:NULL])).to(beTruthy());

		NSError *error = nil;
		BOOL success = [[self.testApplicationSignature verifyBundleAtURL:bundle.bundleURL] waitUntilCompleted:&error];
		expect(@(success)).to(beFalsy());

		expect(error).notTo(beNil());
		expect(error.domain).to(equal(SQRLCodeSignatureErrorDomain));
		expect(@(error.code)).to(equal(@(SQRLCodeSignatureErrorDidNotPass)));
	});

	it(@"should fail to verify a bundle with a corrupt helper", ^{
		corruptURL(helperURL);

		NSError *error = nil;
		BOOL success = [[self.testApplicationSignature verifyBundleAtURL:bundle.bundleURL] waitUntilCompleted:&error];
		expect(@(success)).to(beFalsy());

		expect(error).notTo(beNil());
		expect(error.domain).to(equal(SQRLCodeSignatureErrorDomain));
		expect(@(error.code)).to(equal(@(SQRLCodeSignatureErrorDidNotPass)));
	});
});

describe(@"resource changes", ^{
	__block NSURL *resourceURL;

	beforeEach(^{
		resourceURL = [bundle URLForResource:@"MainMenu" withExtension:@"nib"];
		expect(resourceURL).notTo(beNil());
	});

	it(@"should fail to verify a bundle with a missing resource", ^{
		expect(@([NSFileManager.defaultManager removeItemAtURL:resourceURL error:NULL])).to(beTruthy());

		NSError *error = nil;
		BOOL success = [[self.testApplicationSignature verifyBundleAtURL:bundle.bundleURL] waitUntilCompleted:&error];
		expect(@(success)).to(beFalsy());

		expect(error).notTo(beNil());
		expect(error.domain).to(equal(SQRLCodeSignatureErrorDomain));
		expect(@(error.code)).to(equal(@(SQRLCodeSignatureErrorDidNotPass)));
	});

	it(@"should fail to verify a bundle with a corrupt resource", ^{
		corruptURL(resourceURL);

		NSError *error = nil;
		BOOL success = [[self.testApplicationSignature verifyBundleAtURL:bundle.bundleURL] waitUntilCompleted:&error];
		expect(@(success)).to(beFalsy());

		expect(error).notTo(beNil());
		expect(error.domain).to(equal(SQRLCodeSignatureErrorDomain));
		expect(@(error.code)).to(equal(@(SQRLCodeSignatureErrorDidNotPass)));
	});
});

describe(@"framework changes", ^{
	__block NSURL *frameworkURL;

	beforeEach(^{
		frameworkURL = [bundle.bundleURL URLByAppendingPathComponent:@"Contents/Frameworks/Squirrel.framework"];
	});

	it(@"should fail to verify a bundle with a missing framework", ^{
		expect(@([NSFileManager.defaultManager removeItemAtURL:frameworkURL error:NULL])).to(beTruthy());

		NSError *error = nil;
		BOOL success = [[self.testApplicationSignature verifyBundleAtURL:bundle.bundleURL] waitUntilCompleted:&error];
		expect(@(success)).to(beFalsy());

		expect(error).notTo(beNil());
		expect(error.domain).to(equal(SQRLCodeSignatureErrorDomain));
		expect(@(error.code)).to(equal(@(SQRLCodeSignatureErrorDidNotPass)));
	});

	it(@"should fail to verify a bundle with a corrupt framework", ^{
		corruptURL([frameworkURL URLByAppendingPathComponent:@"Contents/Versions/A/Squirrel"]);

		NSError *error = nil;
		BOOL success = [[self.testApplicationSignature verifyBundleAtURL:bundle.bundleURL] waitUntilCompleted:&error];
		expect(@(success)).to(beFalsy());

		expect(error).notTo(beNil());
		expect(error.domain).to(equal(SQRLCodeSignatureErrorDomain));
		expect(@(error.code)).to(equal(@(SQRLCodeSignatureErrorDidNotPass)));
	});
});

QuickSpecEnd
