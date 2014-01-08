//
//  SQRLInstallerSpec.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-08-09.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLCodeSignature.h"
#import "SQRLDirectoryManager.h"
#import "SQRLInstaller.h"
#import "SQRLInstaller+Private.h"
#import "SQRLShipItLauncher.h"
#import "SQRLShipItState.h"

SpecBegin(SQRLInstaller)

mode_t (^modeOfURL)(NSURL *) = ^ mode_t (NSURL *fileURL) {
	NSFileSecurity *fileSecurity = nil;
	BOOL success = [fileURL getResourceValue:&fileSecurity forKey:NSURLFileSecurityKey error:NULL];
	expect(success).to.beTruthy();
	expect(fileSecurity).notTo.beNil();

	__block mode_t mode;
	expect(CFFileSecurityGetMode((__bridge CFFileSecurityRef)fileSecurity, &mode)).to.beTruthy();

	return mode & (S_IRWXU | S_IRWXG | S_IRWXO);
};

__block NSURL *updateURL;

beforeEach(^{
	updateURL = [self createTestApplicationUpdate];
});

it(@"should install an update", ^{
	SQRLShipItState *state = [[SQRLShipItState alloc] initWithTargetBundleURL:self.testApplicationURL updateBundleURL:updateURL bundleIdentifier:nil];
	expect([[state writeUsingURL:self.shipItDirectoryManager.shipItStateURL] waitUntilCompleted:NULL]).to.beTruthy();

	[self launchShipIt];

	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
});

it(@"should install an update and relaunch", ^{
	NSString *bundleIdentifier = @"com.github.Squirrel.TestApplication";
	NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier];
	expect(apps.count).to.equal(0);

	SQRLShipItState *state = [[SQRLShipItState alloc] initWithTargetBundleURL:self.testApplicationURL updateBundleURL:updateURL bundleIdentifier:nil];
	state.relaunchAfterInstallation = YES;
	expect([[state writeUsingURL:self.shipItDirectoryManager.shipItStateURL] waitUntilCompleted:NULL]).to.beTruthy();

	[self launchShipIt];

	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
	expect([NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier].count).will.equal(1);
});

it(@"should install an update from another volume", ^{
	NSURL *diskImageURL = [self createAndMountDiskImageNamed:@"TestApplication 2.1" fromDirectory:updateURL.URLByDeletingLastPathComponent];
	updateURL = [diskImageURL URLByAppendingPathComponent:updateURL.lastPathComponent];

	SQRLShipItState *state = [[SQRLShipItState alloc] initWithTargetBundleURL:self.testApplicationURL updateBundleURL:updateURL bundleIdentifier:nil];
	expect([[state writeUsingURL:self.shipItDirectoryManager.shipItStateURL] waitUntilCompleted:NULL]).to.beTruthy();

	[self launchShipIt];

	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);
});

it(@"should install an update to another volume", ^{
	NSURL *diskImageURL = [self createAndMountDiskImageNamed:@"TestApplication" fromDirectory:self.testApplicationURL.URLByDeletingLastPathComponent];
	NSURL *targetURL = [diskImageURL URLByAppendingPathComponent:self.testApplicationURL.lastPathComponent];

	SQRLShipItState *state = [[SQRLShipItState alloc] initWithTargetBundleURL:targetURL updateBundleURL:updateURL bundleIdentifier:nil];
	expect([[state writeUsingURL:self.shipItDirectoryManager.shipItStateURL] waitUntilCompleted:NULL]).to.beTruthy();

	[self launchShipIt];

	NSURL *plistURL = [targetURL URLByAppendingPathComponent:@"Contents/Info.plist"];
	expect([NSDictionary dictionaryWithContentsOfURL:plistURL][SQRLBundleShortVersionStringKey]).will.equal(SQRLTestApplicationUpdatedShortVersionString);
});

it(@"should install an update in process", ^{
	SQRLShipItState *state = [[SQRLShipItState alloc] initWithTargetBundleURL:self.testApplicationURL updateBundleURL:updateURL bundleIdentifier:nil];
	state.installerState = SQRLInstaller.initialInstallerState;

	SQRLInstaller *installer = [[SQRLInstaller alloc] initWithDirectoryManager:SQRLDirectoryManager.currentApplicationManager];
	expect(installer).notTo.beNil();

	NSError *installError = nil;
	BOOL install = [[installer.installUpdateCommand execute:state] asynchronouslyWaitUntilCompleted:&installError];
	expect(install).to.beTruthy();
	expect(installError).to.beNil();
});

describe(@"with backup restoration", ^{
	__block NSURL *targetURL;

	__block SQRLShipItState *state;

	beforeEach(^{
		targetURL = self.testApplicationURL;

		state = [[SQRLShipItState alloc] initWithTargetBundleURL:targetURL updateBundleURL:updateURL bundleIdentifier:nil];
		state.installerState = SQRLInstallerStateInstalling;
		state.installationStateAttempt = 4;

		NSURL *copiedTargetURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"TestApplication Target.app"];
		expect([NSFileManager.defaultManager moveItemAtURL:targetURL toURL:copiedTargetURL error:NULL]).to.beTruthy();

		NSURL *copiedUpdateURL = [self.temporaryDirectoryURL URLByAppendingPathComponent:@"TestApplication Update.app"];
		expect([NSFileManager.defaultManager moveItemAtURL:updateURL toURL:copiedUpdateURL error:NULL]).to.beTruthy();

		// Set up ShipIt's preferences like it paused in the middle of an
		// installation.
		NSString *applicationID = self.shipItDirectoryManager.applicationIdentifier;

		NSData *signatureData = [NSKeyedArchiver archivedDataWithRootObject:self.testApplicationSignature];
		expect(signatureData).notTo.beNil();

		CFPreferencesSetValue((__bridge CFStringRef)SQRLInstallerCodeSignatureKey, (__bridge CFDataRef)signatureData, (__bridge CFStringRef)applicationID, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
		CFPreferencesSetValue((__bridge CFStringRef)SQRLInstallerOwnedTargetBundleURLKey, (__bridge CFStringRef)copiedTargetURL.path, (__bridge CFStringRef)applicationID, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
		CFPreferencesSetValue((__bridge CFStringRef)SQRLInstallerOwnedUpdateBundleURLKey, (__bridge CFStringRef)copiedUpdateURL.path, (__bridge CFStringRef)applicationID, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);

		BOOL synchronized = CFPreferencesSynchronize((__bridge CFStringRef)applicationID, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
		expect(synchronized).to.beTruthy();
	});

	afterEach(^{
		__block NSError *error = nil;
		expect([[self.testApplicationSignature verifyBundleAtURL:targetURL] waitUntilCompleted:&error]).will.beTruthy();
		expect(error).to.beNil();

		expect(self.testApplicationBundleVersion).to.equal(SQRLTestApplicationOriginalShortVersionString);
	});

	it(@"should not install an update after too many attempts", ^{
		expect([[state writeUsingURL:self.shipItDirectoryManager.shipItStateURL] waitUntilCompleted:NULL]).to.beTruthy();

		[self launchShipIt];
	});

	it(@"should relaunch even after failing to install an update", ^{
		state.relaunchAfterInstallation = YES;
		expect([[state writeUsingURL:self.shipItDirectoryManager.shipItStateURL] waitUntilCompleted:NULL]).to.beTruthy();

		[self launchShipIt];

		expect([NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.github.Squirrel.TestApplication"].count).will.equal(1);
	});
});

it(@"should disallow writing the updated application except by the owner", ^{
	NSString *command = [NSString stringWithFormat:@"chmod -R 0777 '%@'", updateURL.path];
	expect(system(command.UTF8String)).to.equal(0);

	expect(modeOfURL(updateURL)).to.equal(0777);
	expect(modeOfURL([updateURL URLByAppendingPathComponent:@"Contents/MacOS/TestApplication"])).to.equal(0777);

	SQRLShipItState *state = [[SQRLShipItState alloc] initWithTargetBundleURL:self.testApplicationURL updateBundleURL:updateURL bundleIdentifier:nil];
	expect([[state writeUsingURL:self.shipItDirectoryManager.shipItStateURL] waitUntilCompleted:NULL]).to.beTruthy();

	[self launchShipIt];

	expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);

	expect(modeOfURL(self.testApplicationURL)).to.equal(0755);
	expect(modeOfURL([self.testApplicationURL URLByAppendingPathComponent:@"Contents/MacOS/TestApplication"])).to.equal(0755);
});

describe(@"signal handling", ^{
	__block NSURL *targetURL;

	beforeEach(^{
		// Copied so that we don't recreate the TestApplication bundle by
		// accessing the property.
		targetURL = self.testApplicationURL;

		SQRLShipItState *state = [[SQRLShipItState alloc] initWithTargetBundleURL:self.testApplicationURL updateBundleURL:updateURL bundleIdentifier:nil];
		expect([[state writeUsingURL:self.shipItDirectoryManager.shipItStateURL] waitUntilCompleted:NULL]).to.beTruthy();

		[self launchShipIt];

		// Wait until ShipIt has transitioned by at least one state.
		expect([[[SQRLShipItState readUsingURL:self.shipItDirectoryManager.shipItStateURL] asynchronousFirstOrDefault:nil success:NULL error:NULL] installerState]).willNot.equal(SQRLInstallerStateNothingToDo);

		// Apply a random delay before sending the termination signal, to
		// fuzz out race conditions.
		NSTimeInterval delay = arc4random_uniform(50) / 1000.0;
		[NSThread sleepForTimeInterval:delay];
	});

	afterEach(^{
		// Wait up to the launchd throttle interval, then verify that ShipIt
		// relaunched and finished installing the update.
		Expecta.asynchronousTestTimeout = 5;
		expect(self.testApplicationBundleVersion).will.equal(SQRLTestApplicationUpdatedShortVersionString);

		NSError *error = nil;
		BOOL success = [[self.testApplicationSignature verifyBundleAtURL:targetURL] waitUntilCompleted:&error];
		expect(success).to.beTruthy();
		expect(error).to.beNil();
	});

	it(@"should handle SIGHUP", ^{
		system("killall -HUP ShipIt");
	});

	it(@"should handle SIGTERM", ^{
		system("killall -TERM ShipIt");
	});

	it(@"should handle SIGINT", ^{
		system("killall -INT ShipIt");
	});

	it(@"should handle SIGQUIT", ^{
		system("killall -QUIT ShipIt");
	});

	it(@"should handle SIGKILL", ^{
		// SIGKILL is unique in that it'll always terminate ShipIt, so send it
		// a couple times to really test resumption.
		//
		// Two SIGKILL signals means that it'll be launched three times (which
		// matches the maximum number of attempts per state).
		for (int i = 0; i < 2; i++) {
			system("killall -KILL ShipIt");

			// Wait at least for the launchd throttle interval.
			NSTimeInterval delay = 2 + (arc4random_uniform(100) / 1000.0);
			[NSThread sleepForTimeInterval:delay];
		}
	});
});

SpecEnd
