//
//  SQRLDeepCodesignSpec.m
//  Squirrel
//
//  Created by Keith Duncan on 2013-09-05.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

SpecBegin(SQRLDeepCodesign)

__block NSString *codesignPath = nil;

beforeAll(^ {
	NSTask *findCodesignTask = [[NSTask alloc] init];
	findCodesignTask.launchPath = @"/bin/bash";
	findCodesignTask.arguments = @[ @"-x", @"-c", @"[ ! -z \"$(which xcrun)\" ] && codesign_path=$(xcrun --find codesign); [ ! -x \"${codesign_path}\" ] && codesign_path=$(which codesign); echo -n \"${codesign_path}\"" ];
	findCodesignTask.standardOutput = [NSPipe pipe];

	[findCodesignTask launch];

	// Assume that the default pipe buffer is large enough to hold the path
	[findCodesignTask waitUntilExit];
	expect(@(findCodesignTask.terminationStatus)).to.equal(@(0));

	NSData *findCodesignOutputData = ((NSPipe *)findCodesignTask.standardOutput).fileHandleForReading.readDataToEndOfFile;
	codesignPath = [[NSString alloc] initWithData:findCodesignOutputData encoding:NSUTF8StringEncoding];
	expect(codesignPath).notTo.beNil();

	expect([NSFileManager.defaultManager fileExistsAtPath:codesignPath]).to.beTruthy();
});

void (^resignTestApplicationPreserveEverythingButTheRequirements)(void) = ^{
	NSURL *testApplicationLocation = self.testApplicationURL;

	NSTask *resignCodesignTask = [[NSTask alloc] init];
	resignCodesignTask.launchPath = codesignPath;
	resignCodesignTask.arguments = @[
		@"--sign", @"-",
		@"--force",
		@"--verbose=4",
		@"--preserve-metadata=identifier,entitlements,resource-rules",
		testApplicationLocation.path,
	];

	[resignCodesignTask launch];
	[resignCodesignTask waitUntilExit];

	expect(@(resignCodesignTask.terminationStatus)).to.equal(@(0));
};

void (^deepCodesignTestApplication)(void) = ^{
	NSURL *testApplicationLocation = self.testApplicationURL;

	NSBundle *testsBundle = [NSBundle bundleForClass:self.class];
	NSURL *deepCodesignLocation = [testsBundle URLForResource:@"deep-codesign" withExtension:nil];
	expect([deepCodesignLocation resourceValuesForKeys:@[NSURLIsExecutableKey] error:NULL][NSURLIsExecutableKey]).to.beTruthy();

	NSTask *deepCodesignTask = [[NSTask alloc] init];
	deepCodesignTask.launchPath = deepCodesignLocation.path;
	deepCodesignTask.environment = @{
		@"CODE_SIGN_IDENTITY": @"-",
		@"CONFIGURATION_BUILD_DIR": testApplicationLocation.URLByDeletingLastPathComponent.path,
		@"FULL_PRODUCT_NAME": testApplicationLocation.lastPathComponent,
	};

	[deepCodesignTask launch];
	[deepCodesignTask waitUntilExit];

	expect(@(deepCodesignTask.terminationStatus)).to.equal(@(0));

	/*
		By signing test application's contents, which are covered by test
		application's ResourceRules it's signature becomes invalid. Usually,
		Xcode would sign the application after deep-codesign has run so the
		signature would include the _signed_ child resources which are covered
		by test application's ResourceRules

		test application is already signed, so we need to manually resign it

		deep-codesign preserves the requirements, we can't use it to resign the
		root target, the new signing identity wouldn't verify against the
		original designated requirement
	 */
	resignTestApplicationPreserveEverythingButTheRequirements();
};

it(@"should deep sign the test application", ^{
	deepCodesignTestApplication();
});

it(@"should deep verify after signing", ^{
	deepCodesignTestApplication();

	NSTask *deepVerifyTask = [[NSTask alloc] init];
	deepVerifyTask.launchPath = codesignPath;
	deepVerifyTask.arguments = @[ @"--deep-verify", @"--verbose=4", self.testApplicationURL.path ];

	[deepVerifyTask launch];
	[deepVerifyTask waitUntilExit];

	expect(@(deepVerifyTask.terminationStatus)).to.equal(@(0));
});

SpecEnd
