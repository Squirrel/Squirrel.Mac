//
//  SQRLCodeSignatureVerificationSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-06.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLCodeSignatureVerification.h"

SpecBegin(SQRLCodeSignatureVerification)

__block NSBundle *bundle;
__block void (^corruptURL)(NSURL *URL);

beforeEach(^{
	bundle = self.testApplicationBundle;

	corruptURL = ^(NSURL *URL) {
		expect([@"foobar" writeToURL:bundle.executableURL atomically:YES encoding:NSUTF8StringEncoding error:NULL]).to.beTruthy();
	};
});

it(@"should verify a valid bundle", ^{
	NSError *error = nil;
	BOOL success = [SQRLCodeSignatureVerification verifyCodeSignatureOfBundle:bundle.bundleURL error:&error];
	expect(success).to.beTruthy();
	expect(error).to.beNil();
});

describe(@"code signature changes", ^{
	__block NSURL *codeSignatureURL;

	beforeEach(^{
		codeSignatureURL = [bundle.bundleURL URLByAppendingPathComponent:@"Contents/_CodeSignature"];
	});

	it(@"should fail to verify a bundle with a missing code signature", ^{
		expect([NSFileManager.defaultManager removeItemAtURL:codeSignatureURL error:NULL]).to.beTruthy();

		NSError *error = nil;
		BOOL success = [SQRLCodeSignatureVerification verifyCodeSignatureOfBundle:bundle.bundleURL error:&error];
		expect(success).to.beFalsy();

		expect(error).notTo.beNil();
		expect(error.domain).to.equal(SQRLCodeSignatureVerificationErrorDomain);
		expect(error.code).to.equal(SQRLCodeSignatureVerificationErrorDidNotPass);
	});

	it(@"should fail to verify a bundle with a corrupt code signature", ^{
		corruptURL(codeSignatureURL);

		NSError *error = nil;
		BOOL success = [SQRLCodeSignatureVerification verifyCodeSignatureOfBundle:bundle.bundleURL error:&error];
		expect(success).to.beFalsy();

		expect(error).notTo.beNil();
		expect(error.domain).to.equal(SQRLCodeSignatureVerificationErrorDomain);
		expect(error.code).to.equal(SQRLCodeSignatureVerificationErrorDidNotPass);
	});
});

describe(@"main executable changes", ^{
	it(@"should fail to verify a bundle with a missing executable", ^{
		expect([NSFileManager.defaultManager removeItemAtURL:bundle.executableURL error:NULL]).to.beTruthy();

		NSError *error = nil;
		BOOL success = [SQRLCodeSignatureVerification verifyCodeSignatureOfBundle:bundle.bundleURL error:&error];
		expect(success).to.beFalsy();

		expect(error).notTo.beNil();
		expect(error.domain).to.equal(SQRLCodeSignatureVerificationErrorDomain);
		expect(error.code).to.equal(SQRLCodeSignatureVerificationErrorCouldNotCreateStaticCode);
	});

	it(@"should fail to verify a bundle with a corrupt executable", ^{
		corruptURL(bundle.executableURL);

		NSError *error = nil;
		BOOL success = [SQRLCodeSignatureVerification verifyCodeSignatureOfBundle:bundle.bundleURL error:&error];
		expect(success).to.beFalsy();

		expect(error).notTo.beNil();
		expect(error.domain).to.equal(SQRLCodeSignatureVerificationErrorDomain);
		expect(error.code).to.equal(SQRLCodeSignatureVerificationErrorDidNotPass);
	});
});

describe(@"helper executable changes", ^{
	__block NSURL *helperURL;

	beforeEach(^{
		helperURL = [bundle URLForAuxiliaryExecutable:@"github_cli"];
		expect(helperURL).notTo.beNil();
	});

	it(@"should fail to verify a bundle with a missing helper", ^{
		expect([NSFileManager.defaultManager removeItemAtURL:helperURL error:NULL]).to.beTruthy();

		NSError *error = nil;
		BOOL success = [SQRLCodeSignatureVerification verifyCodeSignatureOfBundle:bundle.bundleURL error:&error];
		expect(success).to.beFalsy();

		expect(error).notTo.beNil();
		expect(error.domain).to.equal(SQRLCodeSignatureVerificationErrorDomain);
		expect(error.code).to.equal(SQRLCodeSignatureVerificationErrorDidNotPass);
	});

	it(@"should fail to verify a bundle with a corrupt helper", ^{
		corruptURL(helperURL);

		NSError *error = nil;
		BOOL success = [SQRLCodeSignatureVerification verifyCodeSignatureOfBundle:bundle.bundleURL error:&error];
		expect(success).to.beFalsy();

		expect(error).notTo.beNil();
		expect(error.domain).to.equal(SQRLCodeSignatureVerificationErrorDomain);
		expect(error.code).to.equal(SQRLCodeSignatureVerificationErrorDidNotPass);
	});
});

describe(@"resource changes", ^{
	__block NSURL *resourceURL;

	beforeEach(^{
		resourceURL = [bundle URLForResource:@"GHAboutWindowController" withExtension:@"nib"];
		expect(resourceURL).notTo.beNil();
	});

	it(@"should fail to verify a bundle with a missing resource", ^{
		expect([NSFileManager.defaultManager removeItemAtURL:resourceURL error:NULL]).to.beTruthy();

		NSError *error = nil;
		BOOL success = [SQRLCodeSignatureVerification verifyCodeSignatureOfBundle:bundle.bundleURL error:&error];
		expect(success).to.beFalsy();

		expect(error).notTo.beNil();
		expect(error.domain).to.equal(SQRLCodeSignatureVerificationErrorDomain);
		expect(error.code).to.equal(SQRLCodeSignatureVerificationErrorDidNotPass);
	});

	it(@"should fail to verify a bundle with a corrupt resource", ^{
		corruptURL(resourceURL);

		NSError *error = nil;
		BOOL success = [SQRLCodeSignatureVerification verifyCodeSignatureOfBundle:bundle.bundleURL error:&error];
		expect(success).to.beFalsy();

		expect(error).notTo.beNil();
		expect(error.domain).to.equal(SQRLCodeSignatureVerificationErrorDomain);
		expect(error.code).to.equal(SQRLCodeSignatureVerificationErrorDidNotPass);
	});
});

describe(@"framework changes", ^{
	__block NSURL *frameworkURL;

	beforeEach(^{
		frameworkURL = [bundle.bundleURL URLByAppendingPathComponent:@"Contents/Frameworks/Mantle.framework"];
	});

	it(@"should fail to verify a bundle with a missing framework", ^{
		expect([NSFileManager.defaultManager removeItemAtURL:frameworkURL error:NULL]).to.beTruthy();

		NSError *error = nil;
		BOOL success = [SQRLCodeSignatureVerification verifyCodeSignatureOfBundle:bundle.bundleURL error:&error];
		expect(success).to.beFalsy();

		expect(error).notTo.beNil();
		expect(error.domain).to.equal(SQRLCodeSignatureVerificationErrorDomain);
		expect(error.code).to.equal(SQRLCodeSignatureVerificationErrorDidNotPass);
	});

	it(@"should fail to verify a bundle with a corrupt framework", ^{
		corruptURL([frameworkURL URLByAppendingPathComponent:@"Contents/Versions/A/Mantle"]);

		NSError *error = nil;
		BOOL success = [SQRLCodeSignatureVerification verifyCodeSignatureOfBundle:bundle.bundleURL error:&error];
		expect(success).to.beFalsy();

		expect(error).notTo.beNil();
		expect(error.domain).to.equal(SQRLCodeSignatureVerificationErrorDomain);
		expect(error.code).to.equal(SQRLCodeSignatureVerificationErrorDidNotPass);
	});
});

SpecEnd
