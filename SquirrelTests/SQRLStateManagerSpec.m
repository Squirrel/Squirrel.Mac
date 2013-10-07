//
//  SQRLStateManagerSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-10-07.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLStateManager+Private.h"

SpecBegin(SQRLStateManager)

NSString *applicationIdentifier = @"com.github.Squirrel.SquirrelTests.SQRLStateManagerSpec";

__block NSURL *stateURL;

__block NSURL *targetURL;
__block NSURL *updateURL;
__block NSURL *backupURL;
__block NSURL *appSupportURL;

beforeEach(^{
	stateURL = [SQRLStateManager stateURLWithIdentifier:applicationIdentifier];
	expect(stateURL).notTo.beNil();

	targetURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"target"];
	updateURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"update"];
	backupURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"backup"];
	appSupportURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"appSupport"];
});

afterEach(^{
	[NSFileManager.defaultManager removeItemAtURL:stateURL error:NULL];
});

it(@"should save and load settings", ^{
	SQRLStateManager *firstManager = [[SQRLStateManager alloc] initWithIdentifier:applicationIdentifier];
	expect(firstManager).notTo.beNil();

	firstManager.state = SQRLShipItStateClearingQuarantine;
	firstManager.installationStateAttempt = 2;
	firstManager.targetBundleURL = targetURL;
	firstManager.updateBundleURL = updateURL;
	firstManager.backupBundleURL = backupURL;
	firstManager.applicationSupportURL = appSupportURL;
	firstManager.requirementData = [NSData data];
	firstManager.waitForBundleIdentifier = applicationIdentifier;
	firstManager.relaunchAfterInstallation = YES;

	NSArray *keys = @[
		@keypath(firstManager.state),
		@keypath(firstManager.installationStateAttempt),
		@keypath(firstManager.targetBundleURL),
		@keypath(firstManager.updateBundleURL),
		@keypath(firstManager.backupBundleURL),
		@keypath(firstManager.applicationSupportURL),
		@keypath(firstManager.requirementData),
		@keypath(firstManager.waitForBundleIdentifier),
		@keypath(firstManager.relaunchAfterInstallation),
	];

	@autoreleasepool {
		SQRLStateManager *secondManager __attribute__((objc_precise_lifetime)) = [[SQRLStateManager alloc] initWithIdentifier:applicationIdentifier];
		expect(secondManager).notTo.beNil();

		// Only some properties should be synchronized so far.
		expect(secondManager.state).to.equal(firstManager.state);
		expect(secondManager.installationStateAttempt).to.equal(firstManager.installationStateAttempt);
		expect(secondManager.targetBundleURL).to.beNil();
		expect([secondManager dictionaryWithValuesForKeys:keys]).notTo.equal([firstManager dictionaryWithValuesForKeys:keys]);
	}

	expect([firstManager synchronize]).to.beTruthy();

	@autoreleasepool {
		SQRLStateManager *secondManager = [[SQRLStateManager alloc] initWithIdentifier:applicationIdentifier];
		expect(secondManager).notTo.beNil();
		expect([secondManager dictionaryWithValuesForKeys:keys]).to.equal([firstManager dictionaryWithValuesForKeys:keys]);
	}
});

SpecEnd
