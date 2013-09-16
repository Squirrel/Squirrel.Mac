//
//  SQRLDeepCodesignSpec.m
//  Squirrel
//
//  Created by Keith Duncan on 2013-09-05.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

SpecBegin(SQRLDeepCodesign)

NSTask * (^codesignTaskWithArguments)(NSArray *) = ^ (NSArray *arguments) {
	NSTask *task = [[NSTask alloc] init];
	task.launchPath = @"/usr/bin/xcrun";
	task.arguments = [@[ @"codesign" ] arrayByAddingObjectsFromArray:arguments];
	return task;
};

void (^resignTestApplicationPreserveEverythingButTheRequirements)(void) = ^{
	NSURL *testApplicationLocation = self.testApplicationURL;

	NSTask *resignCodesignTask = codesignTaskWithArguments(@[
		@"--sign", @"-",
		@"--force",
		@"--verbose=4",
		@"--preserve-metadata=identifier,entitlements,resource-rules",
		testApplicationLocation.path,
	]);

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
	NSMutableDictionary *environment = [NSMutableDictionary dictionaryWithDictionary:NSProcessInfo.processInfo.environment];
	[environment addEntriesFromDictionary:@{
		@"CODE_SIGN_IDENTITY": @"-",
		@"CONFIGURATION_BUILD_DIR": testApplicationLocation.URLByDeletingLastPathComponent.path,
		@"FULL_PRODUCT_NAME": testApplicationLocation.lastPathComponent,
	}];
	deepCodesignTask.environment = environment;

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

EXPExpect * (^expectDeepVerify)(void) = ^ EXPExpect * {
	NSTask *deepVerifyTask = codesignTaskWithArguments(@[
		@"--deep-verify",
		@"--verbose=4",
		self.testApplicationURL.path
	]);

	[deepVerifyTask launch];
	[deepVerifyTask waitUntilExit];

	return expect(@(deepVerifyTask.terminationStatus == 0));
};

it(@"should deep sign the test application", ^{
	deepCodesignTestApplication();
});

it(@"should deep verify after signing", ^{
	expectDeepVerify().to.beFalsy();
	deepCodesignTestApplication();
	expectDeepVerify().to.beTruthy();
});

SpecEnd
